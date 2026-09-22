import XCTest
@testable import OpenUsage

@MainActor
final class MuseProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_710_400)

    func testDescriptorsPutQuotaMetersBeforeTrendAndSpend() {
        let descriptors = makeProvider().widgetDescriptors

        XCTAssertEqual(descriptors.map(\.id), [
            "muse.session", "muse.weekly", "muse.trend",
            "muse.today", "muse.yesterday", "muse.last30"
        ])
        XCTAssertTrue(descriptors[0].pinnable)
        XCTAssertTrue(descriptors[1].pinnable)
        XCTAssertFalse(descriptors[2].pinnable)
        XCTAssertEqual(descriptors[0].limitResources.map(\.key), ["session"])
        XCTAssertEqual(descriptors[1].limitResources.map(\.key), ["weekly"])
    }

    func testRefreshPrependsDashboardQuotasToExistingLocalUsage() async {
        let provider = makeProvider(
            dashboardText: "Current usage 8%\nResets at 2:52 AM\nWeekly limit 29%\nResets Sep 13 at 8:00 PM",
            localScan: localScan()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(Array(snapshot.lines.prefix(2)).map(\.label), ["Session", "Weekly"])
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Usage Trend" })
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Today" })
        XCTAssertNil(snapshot.warning)
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testDashboardFailureKeepsLocalUsageAndAddsNeutralWarning() async {
        let provider = makeProvider(localScan: localScan(), dashboardError: .timeout)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.label == "Usage Trend" })
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Today" })
        XCTAssertFalse(snapshot.lines.contains { $0.label == "Session" || $0.label == "Weekly" })
        XCTAssertEqual(snapshot.warning, "Muse quota is unavailable. Sign in through Meta Muse Bar and refresh.")
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))
    }

    func testPartialDashboardKeepsValidQuotaAndWarns() async {
        let provider = makeProvider(
            dashboardText: "Current usage 8%\nResets at 2:52 AM\nWeekly limit unavailable",
            localScan: localScan()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Session")
        XCTAssertFalse(snapshot.lines.contains { $0.label == "Weekly" })
        XCTAssertEqual(snapshot.warning, "Muse quota is unavailable. Sign in through Meta Muse Bar and refresh.")
    }

    func testDirectDashboardFetchIsLimitedByCentralQuotaSourceInterval() async {
        let clock = MuseTestClock(now)
        let calls = MuseCallCounter()
        let provider = makeProvider(clock: clock, dashboardCalls: calls)

        let first = await provider.refresh()
        clock.set(now.addingTimeInterval(5 * 60))
        let cached = await provider.refresh()

        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(first.refreshedAt, now)
        XCTAssertEqual(cached.refreshedAt, now)

        clock.set(now.addingTimeInterval(QuotaSourceRefreshPolicy.interval))
        let refreshed = await provider.refresh()

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(refreshed.refreshedAt, now.addingTimeInterval(QuotaSourceRefreshPolicy.interval))
    }

    func testDirectDashboardFailureIsNotRetriedInsideQuotaSourceInterval() async {
        let clock = MuseTestClock(now)
        let calls = MuseCallCounter()
        let provider = makeProvider(
            dashboardError: .invalidPage,
            clock: clock,
            dashboardCalls: calls
        )

        _ = await provider.refresh()
        clock.set(now.addingTimeInterval(5 * 60))
        let throttled = await provider.refresh()

        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(throttled.warning, MuseProvider.quotaUnavailableWarning)

        clock.set(now.addingTimeInterval(QuotaSourceRefreshPolicy.interval))
        _ = await provider.refresh()
        XCTAssertEqual(calls.value, 2)
    }

    func testHubQuotasBypassDashboardAndPreserveLocalSpend() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"providers\":{\"muse\":{\"status\":\"ok\",\"fetched_at\":\"\(ISO8601DateFormatter().string(from: now))\",\"session_percent\":0,\"weekly_percent\":37}}}".utf8)))
        let provider = makeProvider(localScan: localScan(), hubHTTP: http)
        let snapshot = await provider.refresh()
        XCTAssertEqual(Array(snapshot.lines.prefix(2)).map(\.label), ["Session", "Weekly"])
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Today" })
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testHubFailureDoesNotFallBackToDashboardOrLoseSpend() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let provider = makeProvider(localScan: localScan(), hubHTTP: http)
        let snapshot = await provider.refresh()
        XCTAssertFalse(snapshot.lines.contains { $0.label == "Session" || $0.label == "Weekly" })
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Today" })
        XCTAssertEqual(snapshot.warning, SharedLimitsHubError.http(503).localizedDescription)
    }

    func testDefaultLayoutEnablesPinsAndKeepsQuotaAndTrendAlwaysVisible() {
        let alwaysVisible = ["muse.session", "muse.weekly", "muse.trend"]
        let spend = ["muse.today", "muse.yesterday", "muse.last30"]

        for id in alwaysVisible + spend {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled")
        }
        for id in alwaysVisible {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should be always visible")
        }
        for id in spend {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should be on demand")
        }
        XCTAssertEqual(
            DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("muse.") },
            ["muse.session", "muse.weekly"]
        )
    }

    private func makeProvider(
        dashboardText: String? = nil,
        localScan: LogUsageScan? = nil,
        dashboardError: MuseDashboardUsageError? = nil,
        hubHTTP: FakeHTTPClient? = nil,
        clock: MuseTestClock? = nil,
        dashboardCalls: MuseCallCounter? = nil
    ) -> MuseProvider {
        let currentDate: @Sendable () -> Date = { [now] in clock?.now ?? now }
        let home = URL(fileURLWithPath: "/tmp/openusage-tests")
        let sessionPath = home.appendingPathComponent(".config/muse/meta_session.json").path
        let sessionJSON = """
        {"cookies":[{"name":"session","value":"safe-fixture","domain":".meta.ai","path":"/",\
        "expires":\(now.timeIntervalSince1970 + 3600),"httpOnly":true,"secure":true,"sameSite":"Lax"}],"origins":[]}
        """
        return MuseProvider(
            authStore: MuseAuthStore(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            usageScanner: MuseUsageScanner(
                environment: FakeEnvironment(), homeDirectory: { home },
                incrementalScanner: IncrementalJSONLScanner<MuseUsageScanner.Entry>()
            ),
            dashboardSessionStore: MuseDashboardSessionStore(
                files: FakeFiles([sessionPath: sessionJSON]), environment: FakeEnvironment(),
                now: currentDate, homeDirectory: { home }
            ),
            dashboardUsage: { _ in
                dashboardCalls?.increment()
                if hubHTTP != nil { XCTFail("Configured hub must bypass the dashboard") }
                if let dashboardError { throw dashboardError }
                return dashboardText ?? "Current usage 8%\nWeekly limit 29%"
            },
            hubConfiguration: {
                hubHTTP.map { _ in SharedLimitsHubConfiguration(snapshotURL: URL(string: "https://hub.example/snapshot.json")!, providers: ["muse"]) }
            },
            hubClient: SharedLimitsHubClient(http: hubHTTP ?? FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))),
            localUsage: { _, _ in localScan },
            now: currentDate,
            pricing: { ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:])) }
        )
    }

    private func localScan() -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(
            day: DailyUsageAccumulator.dayKey(from: now),
            tokens: 1_000,
            cost: 0.25,
            model: "muse-spark-1.3"
        )
        return accumulator.build()
    }
}

private final class MuseTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        self.date = date
    }
}

private final class MuseCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}
