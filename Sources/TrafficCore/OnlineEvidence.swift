import Foundation

/// Recorded awake time supported by fresh successful checks. This is not an
/// OS connection-start timestamp or proof of continuity between checks.
public struct OnlineEvidence: Sendable, Equatable {
    public var since: Date
    public var seconds: Double
    public var hasGaps: Bool
    public init(since: Date, seconds: Double = 0, hasGaps: Bool = false) {
        self.since = since; self.seconds = seconds; self.hasGaps = hasGaps
    }
}

public enum ConnectivityUpdate: Sendable {
    case unchanged
    case replace(OnlineEvidence?)
}
