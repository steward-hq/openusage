import XCTest
@testable import OpenUsage

final class SharedLimitsHubTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-09T02:08:53Z")!

    private func payload(_ fields: String, fetchedAt: String = "2026-09-09T02:08:53Z", status: String = "ok") -> Data {
        Data("{\"providers\":{\"muse\":{\"status\":\"\(status)\",\"fetched_at\":\"\(fetchedAt)\",\(fields)}}}".utf8)
    }

    func testMissingAndInvalidValuesNeverBecomeZero() throws {
        for fields in [#""session_percent":null,"weekly_percent":37"#,
                       #""session_percent":true,"weekly_percent":37"#,
                       #""session_percent":-1,"weekly_percent":37"#,
                       #""session_percent":"unavailable","weekly_percent":37"#] {
            let quota = try SharedLimitsHubClient.decode(payload(fields), providerID: "muse", now: now)
            XCTAssertNil(quota.sessionPercent)
            XCTAssertEqual(quota.weeklyPercent, 37)
            XCTAssertEqual(quota.lines.map(\.label), ["Weekly"])
        }
        let zero = try SharedLimitsHubClient.decode(payload(#""session_percent":0,"weekly_percent":0"#), providerID: "muse", now: now)
        XCTAssertEqual(zero.sessionPercent, 0)
        XCTAssertEqual(zero.lines.count, 2)
    }

    func testLiveMuseZeroSessionAndWeeklyUsageDecode() throws {
        let quota = try SharedLimitsHubClient.decode(
            payload(#""session_percent":0,"weekly_percent":38,"session_reset":null,"weekly_reset":"Sep 14 at 12:00 AM""#),
            providerID: "muse", now: now, resetTimeZone: "UTC"
        )
        XCTAssertEqual(quota.sessionPercent, 0)
        XCTAssertEqual(quota.weeklyPercent, 38)
        XCTAssertEqual(quota.lines.map(\.label), ["Session", "Weekly"])
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

    func testConfigurationMigratesOnlyKnownLegacyHubEndpoints() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(".openusage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = folder.appendingPathComponent("limits-hub.json")

        for endpoint in [
            "https://devbox-moshe.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-nir.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-joon.tailbfbe9a.ts.net:4401/snapshot.json",
            "https://devbox-michael.tailbfbe9a.ts.net:4410/snapshot.json"
        ] {
            try Data(#"{"snapshotURL":"\#(endpoint)","providers":["muse"]}"#.utf8).write(to: file)
            let config = try XCTUnwrap(SharedLimitsHubConfiguration.load(providerID: "muse", home: home))
            XCTAssertEqual(config.snapshotURL.port, 4477)
        }

        for endpoint in [
            "https://custom.example:4401/snapshot.json",
            "https://devbox-moshe.tailbfbe9a.ts.net:4401/custom.json"
        ] {
            try Data(#"{"snapshotURL":"\#(endpoint)","providers":["muse"]}"#.utf8).write(to: file)
            let config = try XCTUnwrap(SharedLimitsHubConfiguration.load(providerID: "muse", home: home))
            XCTAssertEqual(config.snapshotURL.absoluteString, endpoint)
        }
    }
}
