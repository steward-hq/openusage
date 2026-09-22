import Foundation

/// One cadence for expensive or automation-sensitive quota sources. Direct dashboard scrapes use
/// it as their minimum fetch interval; shared snapshots use it as their maximum accepted age.
/// Keep the value here so changing the quota-source cadence cannot leave those paths inconsistent.
enum QuotaSourceRefreshPolicy {
    static let interval: TimeInterval = 30 * 60
    static let intervalMinutes = Int(interval / 60)
}
