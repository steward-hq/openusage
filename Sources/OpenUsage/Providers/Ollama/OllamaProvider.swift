import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Usage", url: "https://ollama.com/settings"),
            ProviderLink(label: "API Keys", url: "https://ollama.com/settings/keys")
        ]
    )

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let now: @Sendable () -> Date
    private let hubConfiguration: @Sendable () throws -> SharedLimitsHubConfiguration?
    private let hubClient: SharedLimitsHubClient

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        hubConfiguration: @escaping @Sendable () throws -> SharedLimitsHubConfiguration? = {
            try SharedLimitsHubConfiguration.load(providerID: "ollama")
        },
        hubClient: SharedLimitsHubClient = SharedLimitsHubClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.hubConfiguration = hubConfiguration
        self.hubClient = hubClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "ollama.monthly", provider: provider, title: "Monthly",
                     metricLabel: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            // Ollama reports recent spend as a single rolling four-week total, not a daily history, so
            // this is one unbounded dollar row rather than the Today/Yesterday/Last 30 Days tiles the
            // local-scanner providers ship.
            //
            // Deliberately not `isUsagePeriod`: that marks a row where $0.00 means nothing was used, and
            // this row counts charges *beyond* the plan. A subscriber can run Ollama hard all month and
            // still sit at $0.00, so the "No usage in this period" hover would be plainly wrong.
            .values(id: "ollama.last4Weeks", provider: provider, title: "Last 4 Weeks",
                    metricLabel: "Last 4 Weeks", selection: .kind(.dollars),
                    valueWord: "spent")
        ]
    }

    /// Ollama is opt-in on the direct ollama.com path: without a hub listing the key alone can't
    /// prove an account link (see below), so it never enables itself and the user turns it on in
    /// Customize. A hub listing *is* an account footprint — the hub collector only publishes
    /// providers whose browser session it holds — so a configured hub is the one credential that
    /// auto-enables Ollama.
    ///
    /// This is the one provider whose local credential cannot answer the question the probe is asking.
    /// Ollama writes `~/.ollama/id_ed25519` the first time it runs, long before — and whether or not —
    /// `ollama signin` ever links it to an ollama.com account, and only the network knows whether that
    /// link exists. Probing the key would therefore auto-enable Ollama for everyone who runs local
    /// models, handing them a provider card whose entire content is a Cloud sign-in warning for a
    /// product they don't use. Reporting no credentials is the honest answer to "is Ollama Cloud set up
    /// here?", and it costs a Cloud subscriber one visit to Customize.
    func hasLocalCredentials() async -> Bool {
        do {
            if try await loadOffMainActor(hubConfiguration) != nil { return true }
        } catch { return true } // Configured but broken: keep the provider visible to explain the error.
        return false
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh so the hub freshness check and snapshot timestamp agree.
        let refreshedAt = now()

        // Hub-configured: the meters come exclusively from the hub (no ollama.com fallback — the hub
        // is the fresher, account-wide source the user opted into). The spend row still comes from
        // ollama.com below, because recent activity spend is not a quota the hub publishes.
        do {
            if let config = try await loadOffMainActor(hubConfiguration) {
                do {
                    let quota = try await hubClient.fetch(providerID: "ollama", configuration: config, now: refreshedAt)
                    let meters = quota.lines(withPeriods: false)
                    var lines = meters
                    if let spend = await spendLine() { lines.append(spend) }
                    MetricLine.appendNoDataIfNeeded(&lines)
                    return ProviderSnapshot.make(
                        provider: provider,
                        plan: quota.plan,
                        lines: lines,
                        refreshedAt: quota.fetchedAt,
                        warning: meters.isEmpty
                            ? SharedLimitsHubError.noData.localizedDescription : nil
                    )
                } catch let error as SharedLimitsHubError {
                    AppLog.warn(LogTag.plugin("ollama"), "shared hub quota unavailable: \(error.localizedDescription)")
                    // Keep whatever the direct API can still offer (the spend row) with the hub
                    // warning; when even that has nothing to show, the hub error is the whole story.
                    if let snapshot = await hubFailureSnapshot(error) { return snapshot }
                    return ProviderSnapshot.error(provider: provider, error: error)
                }
            }
        } catch {
            // The config file exists but is broken: fail loudly rather than silently routing to
            // ollama.com, which would hide the misconfiguration.
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let key: OllamaSigningKey?
        do {
            key = try await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let key else {
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingKey)
        }

        // The usage endpoint is required; the account endpoint is best-effort (plan name only), so a
        // failure there must not blank out the meters.
        let usage = await load { try await usageClient.fetchUsage(key: key) }
        let account = await loadAccount { try await usageClient.fetchAccount(key: key) }

        var accountBody: Data?
        var warning: String?
        switch account {
        case .success(let body):
            accountBody = body
        case .failure(let error):
            // Best-effort does not mean invisible: without this, a persistently failing plan lookup just
            // looks like an account that has no plan. Log it and carry an amber notice so the missing
            // badge is explained, while the meters below still refresh normally.
            AppLog.warn(.refresh, "ollama plan lookup failed (\(error.errorCategory.rawValue)); meters unaffected")
            warning = "Couldn't read your Ollama plan. Usage below is still up to date."
        }

        switch usage {
        case .success(let body):
            do {
                let mapped = try OllamaUsageMapper.map(usageBody: body, accountBody: accountBody)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines,
                                             refreshedAt: now(), warning: warning)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            // The key parsed and signed fine, so a 401/403 means ollama.com doesn't know it: the user has
            // Ollama installed but has never run `ollama signin` (or has signed out since).
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.notSignedIn)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// The signing key, or `nil` when absent — the hub paths treat a missing key as "no spend row",
    /// not an error, because the hub is the source of truth for the meters either way.
    private func loadSigningKey() async throws -> OllamaSigningKey? {
        try await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
    }

    /// The Last 4 Weeks row from the signed usage endpoint — best-effort on the hub path (activity
    /// spend is not a quota, so the hub doesn't publish it). No key, an unreadable key, or a failing
    /// call yields `nil` — the spend row simply doesn't appear, because the hub remains the source
    /// of truth for the meters either way.
    private func spendLine() async -> MetricLine? {
        let key: OllamaSigningKey?
        do {
            key = try await loadSigningKey()
        } catch {
            AppLog.warn(LogTag.plugin("ollama"), "signing key unreadable; spend row skipped: \(error.localizedDescription)")
            return nil
        }
        guard let key else {
            AppLog.info(LogTag.plugin("ollama"), "no signing key; spend row skipped on the hub path")
            return nil
        }
        let usage = await load { try await usageClient.fetchUsage(key: key) }
        guard case .success(let body) = usage,
              let lines = try? OllamaUsageMapper.usageLines(body),
              let activity = lines.first(where: { line in
                  if case .values(let label, _, _, _, _, _) = line { return label == "Last 4 Weeks" }
                  return false
              })
        else {
            AppLog.warn(.refresh, "ollama activity spend lookup failed on the hub path; meters unaffected")
            return nil
        }
        return activity
    }

    /// A hub failure with a usable signing key still shows the spend row plus the hub warning. No
    /// key, or a failing spend call, means nothing to show — `nil` so the caller reports the hub
    /// error itself.
    private func hubFailureSnapshot(_ error: SharedLimitsHubError) async -> ProviderSnapshot? {
        guard let activity = await spendLine() else { return nil }
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: [activity],
            refreshedAt: now(),
            warning: error.localizedDescription
        )
    }

    /// Run the required usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the best-effort account call. It never throws into the snapshot — a transport error or a
    /// non-2xx just means "no plan name this refresh" — but it returns *why* so the caller can log the
    /// failure and warn, rather than letting it disappear.
    private func loadAccount(_ call: () async throws -> HTTPResponse) async -> Result<Data, OllamaUsageError> {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failure(.connectionFailed)
        }
    }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(OllamaUsageError)
}
