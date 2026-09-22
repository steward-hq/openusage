import Foundation

/// Opt-in routing shared by providers. Keeping the endpoint outside the app lets another provider
/// reuse this transport without adding a personal server address to its implementation.
struct SharedLimitsHubConfiguration: Codable, Sendable {
    var snapshotURL: URL
    var providers: [String]
    /// Zone used by the hub's browser when it emits year-less or time-only reset labels.
    var resetTimeZone: String?

    static func load(providerID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self? {
        let file = home.appendingPathComponent(".openusage/limits-hub.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard config.providers.contains(providerID) else { return nil }
            guard config.snapshotURL.scheme == "https", config.snapshotURL.host != nil,
                  config.snapshotURL.user == nil, config.snapshotURL.password == nil,
                  config.resetTimeZone.map({ TimeZone(identifier: $0) != nil }) ?? true
            else { throw SharedLimitsHubError.configuration }
            return Self(
                snapshotURL: migratedSnapshotURL(config.snapshotURL),
                providers: config.providers,
                resetTimeZone: config.resetTimeZone
            )
        } catch { throw SharedLimitsHubError.configuration }
    }

    /// The personal AI Limits hubs moved to one dedicated port. Keep existing Mac config working
    /// without rewriting unrelated endpoints that happen to use either former development port.
    private static func migratedSnapshotURL(_ url: URL) -> URL {
        let legacyEndpoints: Set<String> = [
            "https://devbox-moshe.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-nir.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-joon.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-michael.tailbfbe9a.ts.net:4410/snapshot.json"
        ]
        guard legacyEndpoints.contains(url.absoluteString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.port = 4477
        return components.url ?? url
    }
}

enum SharedLimitsHubError: Error, LocalizedError, Equatable {
    case configuration, connection, invalidResponse, missingProvider, noData, stale
    case http(Int)
    case providerStatus(String)

    var errorDescription: String? {
        switch self {
        case .configuration: "Check the shared hub settings in ~/.openusage/limits-hub.json."
        case .connection: "Shared hub is unreachable. Check your connection and Tailscale."
        case .invalidResponse: "Shared hub returned invalid usage data."
        case .missingProvider: "Shared hub has not published this provider yet."
        case .noData: "Some quota data is unavailable on the shared hub."
        case .stale:
            "Shared hub quota data is over \(QuotaSourceRefreshPolicy.intervalMinutes) minutes old. "
                + "Check the hub collector."
        case .http(let code): "Shared hub request failed (HTTP \(code))."
        case .providerStatus(let status): "Quota unavailable on the shared hub (\(status)). Check the hub collector."
        }
    }
}

/// Common session/weekly quota shape; other providers can add their own mapper for different fields.
struct SharedLimitsHubQuota: Sendable {
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var fetchedAt: Date

    var lines: [MetricLine] {
        var lines: [MetricLine] = []
        if let used = sessionPercent {
            lines.append(.progress(label: "Session", used: used, limit: 100, format: .percent,
                                   resetsAt: sessionReset, periodDurationMs: MetricPeriod.sessionMs))
        }
        if let used = weeklyPercent {
            lines.append(.progress(label: "Weekly", used: used, limit: 100, format: .percent,
                                   resetsAt: weeklyReset, periodDurationMs: MetricPeriod.weekMs))
        }
        return lines
    }
}

struct SharedLimitsHubClient: Sendable {
    var http: any HTTPClient = URLSessionHTTPClient()

    func fetch(providerID: String, configuration: SharedLimitsHubConfiguration, now: Date) async throws -> SharedLimitsHubQuota {
        var components = URLComponents(url: configuration.snapshotURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "t" } + [
            URLQueryItem(name: "t", value: String(Int(now.timeIntervalSince1970 * 1000)))
        ]
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET", url: components.url!,
                headers: ["Cache-Control": "no-cache", "Pragma": "no-cache"], timeout: 15
            ))
        } catch { throw SharedLimitsHubError.connection }
        guard (200...299).contains(response.statusCode) else { throw SharedLimitsHubError.http(response.statusCode) }
        return try Self.decode(response.body, providerID: providerID, now: now, resetTimeZone: configuration.resetTimeZone)
    }

    static func decode(_ data: Data, providerID: String, now: Date, resetTimeZone: String? = nil) throws -> SharedLimitsHubQuota {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SharedLimitsHubError.invalidResponse
        }
        guard let providers = root["providers"] as? [String: Any],
              let provider = providers[providerID] as? [String: Any] else { throw SharedLimitsHubError.missingProvider }
        guard let status = provider["status"] as? String else { throw SharedLimitsHubError.invalidResponse }
        guard status == "ok" else {
            // Only known status codes become user copy, never arbitrary server text.
            let known = ["needs-session", "auth-expired", "no-credentials", "loading", "error"]
            throw SharedLimitsHubError.providerStatus(known.contains(status) ? status : "unavailable")
        }
        guard let fetchedAt = isoDate(provider["fetched_at"] as? String ?? root["updated_at"] as? String),
              fetchedAt.timeIntervalSince(now) < 300 else { throw SharedLimitsHubError.invalidResponse }
        guard now.timeIntervalSince(fetchedAt) <= QuotaSourceRefreshPolicy.interval else {
            throw SharedLimitsHubError.stale
        }
        func percent(_ key: String) -> Double? {
            guard let value = ProviderParse.number(provider[key]), (0...100).contains(value) else { return nil }
            return value
        }
        return SharedLimitsHubQuota(
            sessionPercent: percent("session_percent"), weeklyPercent: percent("weekly_percent"),
            sessionReset: resetDate(provider["session_reset"] as? String, at: fetchedAt, timeZone: resetTimeZone),
            weeklyReset: resetDate(provider["weekly_reset"] as? String, at: fetchedAt, timeZone: resetTimeZone),
            fetchedAt: fetchedAt
        )
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func resetDate(_ text: String?, at fetchedAt: Date, timeZone: String?) -> Date? {
        guard let text else { return nil }
        if let date = isoDate(text) { return date }
        // A browser's wall-clock label cannot safely be interpreted in the Mac's time zone.
        guard let timeZone, let zone = TimeZone(identifier: timeZone) else { return nil }
        let clean = text.replacingOccurrences(of: "\u{202f}", with: " ").replacingOccurrences(of: "\u{00a0}", with: " ")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        for (format, hasDay) in [("h:mm a", false), ("MMM d 'at' h:mm a", true)] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: clean) else { continue }
            let components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            var result = calendar.dateComponents([.year, .month, .day], from: fetchedAt)
            result.hour = components.hour
            result.minute = components.minute
            if hasDay { result.month = components.month; result.day = components.day }
            guard let candidate = calendar.date(from: result) else { return nil }
            return candidate >= fetchedAt ? candidate : calendar.date(byAdding: hasDay ? .year : .day, value: 1, to: candidate)
        }
        return nil
    }
}
