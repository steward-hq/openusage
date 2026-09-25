import XCTest
@testable import OpenUsage

/// End-to-end provider behavior: detection via the Go auth key or local usage, Go meters from the
/// usage API, and local spend tiles + trend, plus auth/empty paths.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    private func usageJSON(rolling: Int = 12, weekly: Int = 8, monthly: Int = 35) -> Data {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["status": "ok", "percent": rolling, "resetsAt": "2026-07-12T17:00:00.000Z"],
                "weekly": ["status": "ok", "percent": weekly, "resetsAt": "2026-07-13T00:00:00.000Z"],
                "monthly": ["status": "ok", "percent": monthly, "resetsAt": "2026-08-04T11:18:32.000Z"]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func okClient() -> OpenCodeUsageClient {
        OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: usageJSON()
        )))
    }

    private func provider(
        files: TextFileAccessing,
        scanner: OpenCodeUsageScanner,
        client: OpenCodeUsageClient? = nil,
        hubConfiguration: (@Sendable () throws -> SharedLimitsHubConfiguration?)? = nil
    ) -> OpenCodeProvider {
        let now = self.now
        return OpenCodeProvider(
            authStore: authStore(files: files),
            usageClient: client ?? okClient(),
            usageScanner: scanner,
            hubConfiguration: hubConfiguration ?? { nil },
            now: { now }
        )
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsageButNotForEmptyDatabase() async {
        func probe(db: String) async -> Bool {
            await provider(
                files: FakeFiles(),
                scanner: OpenCodeUsageScanner(
                    sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                    databasePaths: { ["/oc/opencode.db"] }
                )
            ).hasLocalCredentials()
        }

        let withUsage = await probe(db: "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]")
        XCTAssertTrue(withUsage)
        let empty = await probe(db: "[]")
        XCTAssertFalse(empty)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let db = "[" + [
            openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            client: OpenCodeUsageClient(http: http)
        ).refresh()

        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, OpenCodeUsageClient.usageURL)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer sk-test")

        guard case let .progress(_, used, limit, format, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 12)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshShowsAPIMetersWithGoKeyButNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshKeepsGoMetersWhenDatabasesUnreadable() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshErrorsWhenDatabasesUnreadableWithoutGoKey() async {
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        let snapshot = await provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        let provider = provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testSpendTilesAreNotMarkedEstimated() async {
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testUnauthorizedKeyFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 401,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testEntitlementErrorWithoutLocalUsageIsNoGoSubscription() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
    }

    func testEntitlementErrorWithZenUsageShowsTilesWithoutGoMeters() async {
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
            )))
        ).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testGeneric403FailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403, headers: [:], body: Data("<html>denied</html>".utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .http4xx)
    }

    func testConnectionFailureFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: ThrowingHTTPClient())
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    // MARK: - Shared hub path

    /// `hubConfiguration: { nil }` on every direct-path test keeps them hermetic: the default closure
    /// reads the real `~/.openusage/limits-hub.json`, which would silently reroute these tests
    /// through the hub on a machine whose config lists opencode.
    private var hubConfig: SharedLimitsHubConfiguration {
        SharedLimitsHubConfiguration(
            snapshotURL: URL(string: "https://hub.example/snapshot.json")!, providers: ["opencode"]
        )
    }

    private func hubPayload(
        session: Int? = 12,
        weekly: Int? = 8,
        monthly: Int? = 35,
        sessionReset: String? = "2026-07-12T17:00:00Z",
        monthlyReset: String? = "2026-08-04T11:18:32Z"
    ) -> Data {
        var fields: [String] = []
        if let session { fields.append("\"session_percent\":\(session)") }
        if let weekly { fields.append("\"weekly_percent\":\(weekly)") }
        if let monthly { fields.append("\"monthly_percent\":\(monthly)") }
        if let sessionReset { fields.append("\"session_reset\":\"\(sessionReset)\"") }
        if let monthlyReset { fields.append("\"monthly_reset\":\"\(monthlyReset)\"") }
        let body = "{\"providers\":{\"opencode\":{\"status\":\"ok\",\"fetched_at\":\"\(OpenUsageISO8601.string(from: now))\",\(fields.joined(separator: ","))}}}"
        return Data(body.utf8)
    }

    func testHubMetersReplaceTheGoAPIAndKeepLocalTiles() async {
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let go = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageClient: OpenCodeUsageClient(http: go),
            usageScanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            hubConfiguration: { [hubConfig = self.hubConfig] in hubConfig },
            hubClient: SharedLimitsHubClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: hubPayload())
            )),
            now: { [now = self.now] in now }
        )

        let snapshot = await provider.refresh()

        // The Go API was never called — the meters came from the hub.
        XCTAssertTrue(go.requests.isEmpty)
        XCTAssertEqual(Array(snapshot.lines.map(\.label).prefix(3)), ["Session", "Weekly", "Monthly"])
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
    }

    func testHubMetersWorkWithoutALocalGoKey() async {
        // Hub-configured but no auth.json and no database: the hub is the credential, so the meters
        // still appear (with honest "No data" nowhere else to draw from).
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageClient: OpenCodeUsageClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON())
            )),
            usageScanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            hubConfiguration: { [hubConfig = self.hubConfig] in hubConfig },
            hubClient: SharedLimitsHubClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: hubPayload())
            )),
            now: { [now = self.now] in now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
    }

    func testHubFailureWarnsWithoutCallingTheGoAPI() async {
        let go = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageClient: OpenCodeUsageClient(http: go),
            usageScanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            hubConfiguration: { [hubConfig = self.hubConfig] in hubConfig },
            hubClient: SharedLimitsHubClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 503, headers: [:], body: Data())
            )),
            now: { [now = self.now] in now }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(go.requests.isEmpty)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertEqual(snapshot.warning, SharedLimitsHubError.http(503).localizedDescription)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testHubListingIsACredentialThatEnablesTheProvider() async {
        let scanner = OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        let hubProvider = provider(files: FakeFiles(), scanner: scanner) { [hubConfig = self.hubConfig] in hubConfig }
        let directProvider = provider(files: FakeFiles(), scanner: scanner)
        let brokenProvider = provider(files: FakeFiles(), scanner: scanner) { throw SharedLimitsHubError.configuration }

        let withHub = await hubProvider.hasLocalCredentials()
        let withoutHub = await directProvider.hasLocalCredentials()
        let withBrokenConfig = await brokenProvider.hasLocalCredentials()

        XCTAssertTrue(withHub)
        XCTAssertFalse(withoutHub)
        XCTAssertTrue(withBrokenConfig)
    }
}

private final class ThrowingHTTPClient: HTTPClient, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

// openCodeRow and OpenCodeFakeSQLite live in OpenCodeUsageScannerTests.swift (shared fixtures).
