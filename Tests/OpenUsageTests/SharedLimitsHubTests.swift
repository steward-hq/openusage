import XCTest
@testable import OpenUsage

final class SharedLimitsHubTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-09T02:08:53Z")!

    private func payload(_ fields: String, fetchedAt: String = "2026-09-09T02:08:53Z", status: String = "ok", providerID: String = "muse") -> Data {
        Data("{\"providers\":{\"\(providerID)\":{\"status\":\"\(status)\",\"fetched_at\":\"\(fetchedAt)\",\(fields)}}}".utf8)
    }

    func testMissingAndInvalidValuesNeverBecomeZero() throws {
        for fields in [#""session_percent":null,"weekly_percent":37"#,
                       #""session_percent":true,"weekly_percent":37"#,
                       #""session_percent":-1,"weekly_percent":37"#,
                       #""session_percent":"unavailable","weekly_percent":37"#] {
            let quota = try SharedLimitsHubClient.decode(payload(fields), providerID: "muse", now: now)
            XCTAssertNil(quota.sessionPercent)
            XCTAssertEqual(quota.weeklyPercent, 37)
            XCTAssertEqual(quota.lines().map(\.label), ["Weekly"])
        }
        let zero = try SharedLimitsHubClient.decode(payload(#""session_percent":0,"weekly_percent":0"#), providerID: "muse", now: now)
        XCTAssertEqual(zero.sessionPercent, 0)
        XCTAssertEqual(zero.lines().count, 2)
    }

    func testMonthlyPercentAndResetDecode() throws {
        let data = payload(#""session_percent":1,"weekly_percent":37,"monthly_percent":62,"monthly_reset":"2026-10-01T00:00:00Z""#, providerID: "opencode")
        let quota = try SharedLimitsHubClient.decode(data, providerID: "opencode", now: now)
        XCTAssertEqual(quota.monthlyPercent, 62)
        XCTAssertEqual(quota.monthlyReset, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(quota.lines().map(\.label), ["Session", "Weekly", "Monthly"])

        // Absent and invalid monthly values stay absent rather than becoming zero.
        let absent = try SharedLimitsHubClient.decode(payload(#""weekly_percent":37"#, providerID: "opencode"), providerID: "opencode", now: now)
        XCTAssertNil(absent.monthlyPercent)
        XCTAssertNil(absent.monthlyReset)
        XCTAssertEqual(absent.lines().map(\.label), ["Weekly"])
        let invalid = try SharedLimitsHubClient.decode(
            payload(#""weekly_percent":37,"monthly_percent":true"#, providerID: "opencode"), providerID: "opencode", now: now
        )
        XCTAssertNil(invalid.monthlyPercent)

        // Synthetic publishes `request_percent` and `request_reset` as fallback for its 5-hour rolling request limit.
        let synthetic = try SharedLimitsHubClient.decode(
            payload(#""weekly_percent":42,"request_percent":0,"request_reset":"2026-10-01T00:00:00Z","plan_type":"max""#, providerID: "synthetic"),
            providerID: "synthetic",
            now: now
        )
        XCTAssertEqual(synthetic.weeklyPercent, 42)
        XCTAssertEqual(synthetic.sessionPercent, 0)
        XCTAssertEqual(synthetic.sessionReset, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(synthetic.plan, "Max")
        XCTAssertEqual(synthetic.lines().map(\.label), ["Session", "Weekly"])
    }

    func testLinesWithoutPeriodsOmitCadenceLabels() throws {
        let data = payload(#""session_percent":35,"weekly_percent":32"#, providerID: "ollama")
        let quota = try SharedLimitsHubClient.decode(data, providerID: "ollama", now: now)
        for line in quota.lines(withPeriods: false) {
            guard case .progress(_, let used, _, _, _, let periodMs, _) = line else {
                return XCTFail("expected a meter, got \(line)")
            }
            XCTAssertNil(periodMs)
            XCTAssertEqual(used, line.label == "Session" ? 35 : 32)
        }
        // The default keeps the cadence labels for providers that publish reset dates.
        for line in quota.lines() {
            guard case .progress(_, _, _, _, _, let periodMs, _) = line else {
                return XCTFail("expected a meter, got \(line)")
            }
            XCTAssertNotNil(periodMs)
        }
    }

    func testLiveMuseZeroSessionAndWeeklyUsageDecode() throws {
        let quota = try SharedLimitsHubClient.decode(
            payload(#""session_percent":0,"weekly_percent":38,"session_reset":null,"weekly_reset":"Sep 14 at 12:00 AM""#),
            providerID: "muse", now: now, resetTimeZone: "UTC"
        )
        XCTAssertEqual(quota.sessionPercent, 0)
        XCTAssertEqual(quota.weeklyPercent, 38)
        XCTAssertEqual(quota.lines().map(\.label), ["Session", "Weekly"])
    }

    func testRejectsStaleAndErrorPayloads() {
        for (data, expected) in [
            (payload(#""weekly_percent":37"#, fetchedAt: "2026-09-09T01:00:00Z"), SharedLimitsHubError.stale),
            (payload(#""weekly_percent":37"#, status: "needs-session"), .providerStatus("needs-session")),
            (Data(#"{"status":"loading"}"#.utf8), .missingProvider),
            (Data("<html>error</html>".utf8), .invalidResponse)
        ] {
            XCTAssertThrowsError(try SharedLimitsHubClient.decode(data, providerID: "muse", now: now)) {
                XCTAssertEqual($0 as? SharedLimitsHubError, expected)
            }
        }
    }

    func testCentralQuotaSourceIntervalControlsHubStaleness() throws {
        let formatter = ISO8601DateFormatter()
        let boundary = formatter.string(from: now.addingTimeInterval(-QuotaSourceRefreshPolicy.interval))
        XCTAssertNoThrow(
            try SharedLimitsHubClient.decode(
                payload(#""weekly_percent":37"#, fetchedAt: boundary), providerID: "muse", now: now
            )
        )

        let tooOld = formatter.string(
            from: now.addingTimeInterval(-QuotaSourceRefreshPolicy.interval - 1)
        )
        XCTAssertThrowsError(
            try SharedLimitsHubClient.decode(
                payload(#""weekly_percent":37"#, fetchedAt: tooOld), providerID: "muse", now: now
            )
        ) {
            XCTAssertEqual($0 as? SharedLimitsHubError, .stale)
        }
    }

    func testHubResetTimesUseCollectorTimeZone() throws {
        let data = payload(#""session_percent":1,"weekly_percent":37,"session_reset":"2:41 AM","weekly_reset":"Sep 14 at 12:00 AM""#)
        let quota = try SharedLimitsHubClient.decode(data, providerID: "muse", now: now, resetTimeZone: "UTC")
        XCTAssertEqual(quota.sessionReset, ISO8601DateFormatter().date(from: "2026-09-09T02:41:00Z"))
        XCTAssertEqual(quota.weeklyReset, ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z"))
        let unspecified = try SharedLimitsHubClient.decode(data, providerID: "muse", now: now)
        XCTAssertNil(unspecified.sessionReset)
    }

    func testRequestAndHTTPFailure() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: payload(#""session_percent":1,"weekly_percent":37"#)))
        let config = SharedLimitsHubConfiguration(snapshotURL: URL(string: "https://hub.example/snapshot.json")!, providers: ["muse"])
        let client = SharedLimitsHubClient(http: http)
        let quota = try await client.fetch(providerID: "muse", configuration: config, now: now)
        XCTAssertEqual(quota.sessionPercent, 1)
        XCTAssertEqual(http.requests[0].headers["Cache-Control"], "no-cache")
        XCTAssertTrue(http.requests[0].url.absoluteString.contains("?t="))
        XCTAssertNil(http.requests[0].headers["Cookie"])
        http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        do {
            _ = try await client.fetch(providerID: "muse", configuration: config, now: now)
            XCTFail("Expected HTTP failure")
        } catch { XCTAssertEqual(error as? SharedLimitsHubError, .http(503)) }
    }

    func testConfigurationIsOptInAndInvalidSettingsFailVisibly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(".openusage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(try SharedLimitsHubConfiguration.load(providerID: "muse", home: home))
        let file = folder.appendingPathComponent("limits-hub.json")
        try Data(#"{"snapshotURL":"https://hub.example/snapshot.json","providers":["muse"],"resetTimeZone":"UTC"}"#.utf8).write(to: file)
        XCTAssertNotNil(try SharedLimitsHubConfiguration.load(providerID: "muse", home: home))
        XCTAssertNil(try SharedLimitsHubConfiguration.load(providerID: "claude", home: home))
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try SharedLimitsHubConfiguration.load(providerID: "muse", home: home))
    }
}
