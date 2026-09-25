import Foundation

/// Typed failures for the Synthetic provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum SyntheticUsageError: Error, LocalizedError, Equatable {
    /// The provider is enabled but the shared limits hub isn't configured for it — no other
    /// credential exists to fall back to.
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Synthetic isn't listed in your shared limits hub. Add \"synthetic\" to ~/.openusage/limits-hub.json and refresh."
        }
    }
}

/// Reads Synthetic's session and weekly quotas from the configured shared limits hub. Hub-only by
/// design: Synthetic has no local logs, keychain, or auth file on this Mac — the hub collector is
/// the sole source — so the provider stays off for anyone who isn't hub-configured, and an enabled
/// but unlisted install gets an actionable "not configured" error instead of a made-up one.
///
/// No quick links: the provider ships none rather than guessing at a dashboard URL.
@MainActor
final class SyntheticProvider: ProviderRuntime {
    let provider = Provider(
        id: "synthetic",
        displayName: "Synthetic",
        icon: .providerMark("synthetic")
    )

    private let hubConfiguration: @Sendable () throws -> SharedLimitsHubConfiguration?
    private let hubClient: SharedLimitsHubClient
    private let now: @Sendable () -> Date

    init(
        hubConfiguration: @escaping @Sendable () throws -> SharedLimitsHubConfiguration? = {
            try SharedLimitsHubConfiguration.load(providerID: "synthetic")
        },
        hubClient: SharedLimitsHubClient = SharedLimitsHubClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.hubConfiguration = hubConfiguration
        self.hubClient = hubClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "synthetic.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "synthetic.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    /// The hub listing is the only credential: a listing means the hub collector holds this
    /// account's session. Broken configuration still counts, so the enabled provider can explain
    /// the problem instead of disappearing.
    func hasLocalCredentials() async -> Bool {
        do {
            return try await loadOffMainActor(hubConfiguration) != nil
        } catch {
            return true
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()

        let config: SharedLimitsHubConfiguration?
        do {
            config = try await loadOffMainActor(hubConfiguration)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let config else {
            return ProviderSnapshot.error(provider: provider, error: SyntheticUsageError.notConfigured)
        }

        do {
            let quota = try await hubClient.fetch(providerID: "synthetic", configuration: config, now: refreshedAt)
            var lines = quota.lines()
            let warning = lines.isEmpty ? SharedLimitsHubError.noData.localizedDescription : nil
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: quota.fetchedAt,
                warning: warning
            )
        } catch let error as SharedLimitsHubError {
            AppLog.warn(LogTag.plugin("synthetic"), "shared hub quota unavailable: \(error.localizedDescription)")
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: refreshedAt,
                warning: error.localizedDescription
            )
        } catch {
            AppLog.warn(LogTag.plugin("synthetic"), "shared hub quota unavailable (unexpected)")
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: refreshedAt,
                warning: SharedLimitsHubError.invalidResponse.localizedDescription
            )
        }
    }
}