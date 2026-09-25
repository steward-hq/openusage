import XCTest
@testable import OpenUsage

@MainActor
final class SyntheticProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-09-09T02:08:53Z")!

    private var config: SharedLimitsHubConfiguration {
        SharedLimitsHubConfiguration(
            snapshotURL: URL(string: "https://hub.example/snapshot.json")!, providers: ["synthetic"]
        )
    }

    private func hubPayload(
        _ fields: String,
        fetchedAt: String = "2026-09-09T02:08:53Z",
        status: String = "ok"
    ) -> Data {
        Data("{\"providers\":{\"synthetic\":{\"status\":\"\(status)\",\"fetched_at\":\"\(fetchedAt)\",\(fields)}}}".utf8)
    }

    private func provider(
        configured: Bool = true,
        http: FakeHTTPClient? = nil
    ) -> SyntheticProvider {
        let client = http ?? FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: hubPayload(
                #""session_percent":35,"weekly_percent":32,"session_reset":"2026-09-09T05:00:00Z""#
            )
        ))
        let config = configured ? self.config : nil
        return SyntheticProvider(
            hubConfiguration: { config },
            hubClient: SharedLimitsHubClient(http: client),
            now: { [now = self.now] in now }
        )
    }

    func testRefreshMapsHubQuotasToBothMeters() async {
        let snapshot = await provider().refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        guard case .progress(_, let sessionUsed, _, _, let sessionReset, let periodMs, _)? =
                snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 35)
        XCTAssertNotNil(sessionReset)
        XCTAssertEqual(periodMs, MetricPeriod.sessionMs)
        guard case .progress(_, let weeklyUsed, _, _, _, let weeklyPeriod, _)? =
                snapshot.line(label: "Weekly") else {
            return XCTFail("expected a Weekly meter")
        }
        XCTAssertEqual(weeklyUsed, 32)
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)
    }

    func testRefreshMapsRequestPercentFallbackToSession() async {
        let provider = provider(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: hubPayload(
                #""weekly_percent":42,"request_percent":5,"request_reset":"2026-09-09T07:08:53Z""#
            )
        )))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        guard case .progress(_, let sessionUsed, _, _, let sessionReset, let sessionPeriod, _)? =
                snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 5)
        XCTAssertNotNil(sessionReset)
        XCTAssertEqual(sessionPeriod, MetricPeriod.sessionMs)
        guard case .progress(_, let weeklyUsed, _, _, _, let weeklyPeriod, _)? =
                snapshot.line(label: "Weekly") else {
            return XCTFail("expected a Weekly meter")
        }
        XCTAssertEqual(weeklyUsed, 42)
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)
    }

    func testPartialQuotaKeepsValidMetersWithoutWarning() async {
        let provider = provider(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: hubPayload(#""weekly_percent":32"#)
        )))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Weekly"])
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testEmptyQuotaShowsNoDataWithWarning() async {
        let provider = provider(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: hubPayload("")
        )))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines, [.noUsageData])
        XCTAssertEqual(snapshot.warning, SharedLimitsHubError.noData.localizedDescription)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testHubFailureShowsNoDataWithTheWarning() async {
        let provider = provider(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 503, headers: [:], body: Data()
        )))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines, [.noUsageData])
        XCTAssertEqual(snapshot.warning, SharedLimitsHubError.http(503).localizedDescription)
    }

    func testEnabledWithoutAHubListingSurfacesNotConfigured() async {
        let snapshot = await provider(configured: false).refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
        guard case .badge(_, let text, _, _)? = snapshot.lines.first else {
            return XCTFail("expected an error badge")
        }
        XCTAssertEqual(text, SyntheticUsageError.notConfigured.localizedDescription)
    }

    func testBrokenConfigSurfacesTheConfigurationError() async {
        let provider = SyntheticProvider(
            hubConfiguration: { throw SharedLimitsHubError.configuration },
            now: { [now = self.now] in now }
        )

        let snapshot = await provider.refresh()

        // `SharedLimitsHubError` is not `CategorizedError`, so the bucket is `.other`.
        XCTAssertEqual(snapshot.errorCategory, .other)
    }

    func testHubListingIsTheOnlyLocalCredential() async {
        let configured = await provider().hasLocalCredentials()
        let unconfigured = await provider(configured: false).hasLocalCredentials()
        let brokenProvider = SyntheticProvider(
            hubConfiguration: { throw SharedLimitsHubError.configuration },
            now: { [now = self.now] in now }
        )
        let broken = await brokenProvider.hasLocalCredentials()

        XCTAssertTrue(configured)
        XCTAssertFalse(unconfigured)
        XCTAssertTrue(broken)
    }

    func testDescriptorsExposeBothMetersAsLimits() {
        let descriptors = SyntheticProvider().widgetDescriptors

        XCTAssertEqual(descriptors.map(\.id), ["synthetic.session", "synthetic.weekly"])
        XCTAssertEqual(descriptors.map(\.metricLabel), ["Session", "Weekly"])
        XCTAssertEqual(descriptors.flatMap(\.limitResources).map(\.key), ["session", "weekly"])
        XCTAssertTrue(descriptors[0].pinnable)
        XCTAssertTrue(descriptors[1].pinnable)
    }

    func testDefaultLayoutEnablesPinsAndKeepsBothMetersAlwaysVisible() {
        for id in ["synthetic.session", "synthetic.weekly"] {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled")
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should be always visible")
        }
        XCTAssertEqual(
            DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("synthetic.") },
            ["synthetic.session", "synthetic.weekly"]
        )
    }
}