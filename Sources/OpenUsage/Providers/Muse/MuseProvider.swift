import Foundation

/// Combines account-wide Muse quotas from the configured shared hub (or local dashboard) with CLI session
/// logs already on this Mac. Dashboard lookup is best-effort: local trend/spend stays available and
/// carries a neutral warning whenever the unofficial dashboard source cannot be read.
///
/// No quick links: the provider ships none rather than guessing at Status / Dashboard URLs.
@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(
        id: "muse",
        displayName: "Muse Code",
        icon: .providerMark("muse")
    )

    let authStore: MuseAuthStore
    let usageScanner: MuseUsageScanner
    let dashboardSessionStore: MuseDashboardSessionStore
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    private let dashboardUsage: @MainActor ([MuseDashboardCookie]) async throws -> String
    private let hubConfiguration: @Sendable () throws -> SharedLimitsHubConfiguration?
    private let hubClient: SharedLimitsHubClient
    private let localUsage: @Sendable (Date, ModelPricing) async -> LogUsageScan?
    /// Direct dashboard reads are much more automation-sensitive than the app's normal refresh loop.
    /// Keep the last successful mapping in memory so the five-minute loop never scrapes Meta more
    /// often than `QuotaSourceRefreshPolicy.interval`. A new app process still performs one fresh read.
    private var cachedDashboardQuota: (lines: [MetricLine], fetchedAt: Date)?
    /// Attempts are throttled too: after Meta rejects a scrape, do not turn the app's five-minute
    /// provider loop into repeated browser traffic while the temporary block is trying to clear.
    private var lastDashboardFetchAt: Date?

    /// Names the local source on hover. Dollars are estimated from Meta's published Muse Spark
    /// rates (not measured), so the estimate marker applies — unlike OpenCode's carried costs.
    private let sourceNote = "From your Muse logs (estimated)"

    /// Edge-triggers the auth-read-failure log so persistently unreadable storage warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    static let quotaUnavailableWarning = "Muse quota is unavailable. Sign in through Meta Muse Bar and refresh."

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageScanner: MuseUsageScanner = MuseUsageScanner(),
        dashboardSessionStore: MuseDashboardSessionStore = MuseDashboardSessionStore(),
        dashboardUsageClient: MuseDashboardUsageClient = MuseDashboardUsageClient(),
        dashboardUsage: (@MainActor ([MuseDashboardCookie]) async throws -> String)? = nil,
        hubConfiguration: @escaping @Sendable () throws -> SharedLimitsHubConfiguration? = {
            try SharedLimitsHubConfiguration.load(providerID: "muse")
        },
        hubClient: SharedLimitsHubClient = SharedLimitsHubClient(),
        localUsage: (@Sendable (Date, ModelPricing) async -> LogUsageScan?)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.hubConfiguration = hubConfiguration
        self.hubClient = hubClient
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.dashboardSessionStore = dashboardSessionStore
        self.dashboardUsage = dashboardUsage ?? { [dashboardUsageClient] cookies in
            try await dashboardUsageClient.fetchUsage(cookies: cookies)
        }
        self.localUsage = localUsage ?? { [usageScanner] now, pricing in
            await usageScanner.scan(now: now, pricing: pricing)
        }
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "muse.session", provider: provider, title: "Session",
                     sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "muse.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        do {
            if try await loadOffMainActor(hubConfiguration) != nil { return true }
        } catch { return true } // Configured but broken: keep the provider visible to explain the error.
        // Same sources as `refresh()`: the dashboard session, an exported `META_API_KEY`, the local
        // `auth.json`, or any Muse session log. Broken/expired state is still a local Muse footprint,
        // so the enabled provider can explain the problem instead of disappearing.
        do {
            _ = try await loadOffMainActor { [dashboardSessionStore] in
                try dashboardSessionStore.cookies()
            }
            return true
        } catch MuseDashboardSessionError.absent {
            // Continue through the CLI sources below.
        } catch {
            return true
        }
        do {
            if try await loadOffMainActor({ [authStore] in try authStore.credential() }) != nil {
                return true
            }
        } catch {
            return true
        }
        return await usageScanner.hasLocalUsage()
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        var quotaLines: [MetricLine] = []
        var quotaWarning: String?
        var dashboardSessionExists = false
        var quotaFetchedAt: Date?
        do {
            if let config = try await loadOffMainActor(hubConfiguration) {
                dashboardSessionExists = true
                let quota = try await hubClient.fetch(providerID: "muse", configuration: config, now: refreshedAt)
                quotaLines = quota.lines
                quotaFetchedAt = quota.fetchedAt
                if quotaLines.count != 2 { quotaWarning = SharedLimitsHubError.noData.localizedDescription }
            } else {
                let cookies = try await loadOffMainActor { [dashboardSessionStore] in
                    try dashboardSessionStore.cookies()
                }
                dashboardSessionExists = true
                let quota = try await dashboardQuota(cookies: cookies, now: refreshedAt)
                quotaLines = quota.lines
                quotaFetchedAt = quota.fetchedAt
                if quotaLines.count != 2 { quotaWarning = Self.quotaUnavailableWarning }
            }
        } catch let error as SharedLimitsHubError {
            dashboardSessionExists = true
            quotaWarning = error.localizedDescription
            AppLog.warn(LogTag.plugin("muse"), "shared hub quota unavailable: \(error.localizedDescription)")
        } catch let error as MuseDashboardSessionError {
            dashboardSessionExists = error != .absent
            quotaWarning = Self.quotaUnavailableWarning
            AppLog.warn(LogTag.plugin("muse"), "dashboard quota unavailable (\(error.diagnosticCode))")
        } catch let error as MuseDashboardUsageError {
            quotaWarning = Self.quotaUnavailableWarning
            AppLog.warn(LogTag.plugin("muse"), "dashboard quota unavailable (\(error.diagnosticCode))")
        } catch {
            quotaWarning = Self.quotaUnavailableWarning
            AppLog.warn(LogTag.plugin("muse"), "dashboard quota unavailable (unexpected)")
        }

        var credential: MuseCredential?
        var authReadError: MuseUsageError?
        do {
            credential = try await loadOffMainActor { [authStore] in try authStore.credential() }
            loggedAuthReadFailure = false
        } catch let error as MuseUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("muse"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        let scan = await localUsage(refreshedAt, await pricing())

        var lines = quotaLines
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                estimated: true,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        if lines.isEmpty {
            if credential != nil {
                // Logged in but nothing in the window: honest "No data", not an error.
                MetricLine.appendNoDataIfNeeded(&lines)
            } else if dashboardSessionExists {
                MetricLine.appendNoDataIfNeeded(&lines)
            } else {
                return ProviderSnapshot.error(
                    provider: provider, error: authReadError ?? MuseUsageError.notLoggedIn
                )
            }
        }

        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: quotaFetchedAt ?? refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.series,
                    modelUsage: $0.modelUsage,
                    unknownModelsByDay: $0.unknownModelsByDay
                )
            },
            warning: quotaWarning
        )
    }

    private func dashboardQuota(
        cookies: [MuseDashboardCookie], now: Date
    ) async throws -> (lines: [MetricLine], fetchedAt: Date) {
        if let lastDashboardFetchAt,
           now.timeIntervalSince(lastDashboardFetchAt) < QuotaSourceRefreshPolicy.interval {
            if let cachedDashboardQuota { return cachedDashboardQuota }
            throw MuseDashboardUsageError.cooldown
        }
        lastDashboardFetchAt = now
        let pageText = try await dashboardUsage(cookies)
        let quota = (lines: try MuseUsageMapper.lines(from: pageText, now: now), fetchedAt: now)
        cachedDashboardQuota = quota
        return quota
    }
}

private extension MuseDashboardSessionError {
    var diagnosticCode: String {
        switch self {
        case .absent: "session-absent"
        case .expired: "session-expired"
        case .unreadable: "session-unreadable"
        }
    }
}

private extension MuseDashboardUsageError {
    var diagnosticCode: String {
        switch self {
        case .invalidCookie: "invalid-cookie"
        case .invalidPage: "invalid-page"
        case .timeout: "timeout"
        case .cooldown: "cooldown"
        }
    }
}
