import Foundation

/// The small, app-owned cookie shape passed from Playwright storage state to WebKit. Keeping the
/// decoded value separate from `HTTPCookie` makes the disk reader Sendable and easy to test without
/// importing any browser framework. Values are intentionally never described or logged.
struct MuseDashboardCookie: Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var isHTTPOnly: Bool
    var isSecure: Bool
    var sameSite: String?
}

enum MuseDashboardSessionError: Error, LocalizedError, Equatable {
    case absent
    case expired
    case unreadable

    var errorDescription: String? {
        switch self {
        case .absent:
            return "Meta dashboard session not found."
        case .expired:
            return "Meta dashboard session has expired."
        case .unreadable:
            return "Meta dashboard session could not be read."
        }
    }
}

/// Reads the Playwright storage-state file created by Meta Muse Bar. Only cookies applicable to
/// `dev.meta.ai` cross this boundary; origins/local storage and every unrelated cookie are ignored.
struct MuseDashboardSessionStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var now: @Sendable () -> Date
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        now: @escaping @Sendable () -> Date = Date.init,
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.now = now
        self.homeDirectory = homeDirectory
    }

    func cookies() throws -> [MuseDashboardCookie] {
        let path = MusePaths.dashboardSessionPath(environment: environment, homeDirectory: homeDirectory())
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(path) else {
                throw MuseDashboardSessionError.absent
            }
            text = stored
        } catch let error as MuseDashboardSessionError {
            throw error
        } catch {
            throw MuseDashboardSessionError.unreadable
        }

        let state: StorageState
        do {
            state = try JSONDecoder().decode(StorageState.self, from: Data(text.utf8))
        } catch {
            throw MuseDashboardSessionError.unreadable
        }

        let candidates = state.cookies.filter { Self.isForUsageDashboard(domain: $0.domain) }
        guard !candidates.isEmpty else { throw MuseDashboardSessionError.unreadable }

        let currentTime = now()
        let valid = candidates.compactMap { cookie -> MuseDashboardCookie? in
            let expiry = cookie.expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            if let expiry, expiry <= currentTime { return nil }
            guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return nil }
            return MuseDashboardCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path.nilIfEmpty ?? "/",
                expires: expiry,
                isHTTPOnly: cookie.httpOnly ?? false,
                isSecure: cookie.secure ?? false,
                sameSite: cookie.sameSite
            )
        }
        guard !valid.isEmpty else { throw MuseDashboardSessionError.expired }
        return valid
    }

    private static func isForUsageDashboard(domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "meta.ai" || normalized == "dev.meta.ai"
    }

    private struct StorageState: Decodable {
        var cookies: [StoredCookie]
    }

    private struct StoredCookie: Decodable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Double?
        var httpOnly: Bool?
        var secure: Bool?
        var sameSite: String?
    }
}
