import Foundation

public enum HistoryPeriod: String, CaseIterable, Sendable {
    case hour = "1h", hours24 = "24h", days7 = "7d", days30 = "30d", all = "All time"
    public var seconds: Double? {
        switch self { case .hour: 3600; case .hours24: 86400; case .days7: 7 * 86400; case .days30: 30 * 86400; case .all: nil }
    }
    public var title: String {
        switch self { case .hour: "Last hour"; case .hours24: "Last 24 hours"; case .days7: "Last 7 days"; case .days30: "Last 30 days"; case .all: "All recorded history" }
    }
    public func start(before end: Date) -> Date? { seconds.map { end.addingTimeInterval(-$0) } }
}

public struct PeriodChart: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var points: [GraphPoint]
    public var resolution: Double
    public init(start: Date, end: Date, points: [GraphPoint] = [], resolution: Double = 60) {
        self.start = start; self.end = end; self.points = points; self.resolution = resolution
    }
    public var peak: Double { points.filter(\.hasMeasurements).map { max($0.peakDown, $0.peakUp) }.max() ?? 0 }
}

public struct PeriodHistory: Sendable, Equatable {
    public var summary: HistorySummary
    public var end: Date
    public var savedThrough: Date?
    public var hasRecords: Bool
    public var boundaryEstimated: Bool
    public var peakIsUpperBound: Bool
    public init(summary: HistorySummary = HistorySummary(), end: Date, savedThrough: Date? = nil,
                hasRecords: Bool = false, boundaryEstimated: Bool = false, peakIsUpperBound: Bool = false) {
        self.summary = summary; self.end = end; self.savedThrough = savedThrough
        self.hasRecords = hasRecords; self.boundaryEstimated = boundaryEstimated; self.peakIsUpperBound = peakIsUpperBound
    }
}

/// A current successful-check streak, never restored from disk or inferred
/// from Wi-Fi. Unknown samples and stale checks invalidate it conservatively.
public struct ConnectionStreak: Sendable {
    private var began: Double?
    private var lastSuccess: Double?
    private var lastSample: Double?
    public private(set) var duration: Double?
    public init() {}
    public mutating func reset() { began = nil; lastSuccess = nil; lastSample = nil; duration = nil }
    public mutating func receive(_ outcome: ProbeOutcome, uptime: Double, freshness: Double) {
        guard case .success = outcome, uptime.isFinite else { reset(); return }
        if let success = lastSuccess, let sample = lastSample, uptime >= sample, uptime - sample <= 15,
           uptime >= success, uptime - success <= freshness, began != nil {
            lastSuccess = uptime
        } else {
            began = uptime; lastSuccess = uptime
        }
        lastSample = uptime; duration = max(0, uptime - began!)
    }
    public mutating func advance(uptime: Double, observed: Bool, freshness: Double) {
        guard observed, uptime.isFinite, let began, let success = lastSuccess, let sample = lastSample,
              uptime >= sample, uptime - sample <= 15, uptime >= success, uptime - success <= freshness else {
            reset(); return
        }
        lastSample = uptime; duration = max(0, uptime - began)
    }
}
