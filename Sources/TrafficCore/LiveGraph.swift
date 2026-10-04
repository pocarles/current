import Foundation

public struct GraphPoint: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var peakDown: Double
    public var peakUp: Double
    public var hasMeasurements: Bool
    public var hasGap: Bool
    public init(start: Date, end: Date, peakDown: Double = 0, peakUp: Double = 0,
                hasMeasurements: Bool = false, hasGap: Bool = true) {
        self.start = start; self.end = end; self.peakDown = peakDown; self.peakUp = peakUp
        self.hasMeasurements = hasMeasurements; self.hasGap = hasGap
    }
}

/// At most 361 ten-second points. Peaks survive reduction; mixed coverage is
/// explicitly a gap, never a continuous line through unknown time.
public struct LiveGraph: Sendable {
    public static let span: Double = 3600
    public static let grain: Double = 10
    public private(set) var points: [GraphPoint] = []
    public init() {}
    public mutating func append(_ observation: Observation) {
        guard observation.duration > 0 else { return }
        let lower = observation.end.addingTimeInterval(-Self.span)
        if let last = points.last, observation.start < last.end {
            // A wall-clock rollback cannot splice old and new timelines.
            points = []
        }
        points.removeAll { $0.end <= lower }
        var cursor = max(observation.start, lower)
        while cursor < observation.end {
            let bucket = floor(cursor.timeIntervalSince1970 / Self.grain) * Self.grain
            let end = min(observation.end, Date(timeIntervalSince1970: bucket + Self.grain))
            let measured = observation.coverage == .observed ||
                (observation.coverage == .partial && (observation.received > 0 || observation.sent > 0))
            let gap = observation.coverage != .observed
            if let last = points.last, floor(last.start.timeIntervalSince1970 / Self.grain) * Self.grain == bucket {
                let index = points.count - 1
                points[index].hasGap = last.hasGap || gap || cursor.timeIntervalSince(last.end) > 0.001
                points[index].end = end
                points[index].hasMeasurements = last.hasMeasurements || measured
                points[index].peakDown = max(last.peakDown, measured ? observation.peakDown : 0)
                points[index].peakUp = max(last.peakUp, measured ? observation.peakUp : 0)
            } else {
                points.append(GraphPoint(start: cursor, end: end,
                    peakDown: measured ? observation.peakDown : 0, peakUp: measured ? observation.peakUp : 0,
                    hasMeasurements: measured, hasGap: gap))
            }
            cursor = end
        }
    }

    /// Fill genuinely missing history, clip both bounds, and retain the peak
    /// of a clipped bucket as an upper bound at the graph's coarse resolution.
    public static func window(_ input: [GraphPoint], ending end: Date) -> [GraphPoint] {
        window(input, start: end.addingTimeInterval(-span), ending: end)
    }
    public static func window(_ input: [GraphPoint], start: Date, ending end: Date) -> [GraphPoint] {
        var output: [GraphPoint] = [], cursor = start
        for var point in input.sorted(by: { $0.start < $1.start }) where point.end > start && point.start < end {
            point.start = max(start, point.start); point.end = min(end, point.end)
            guard point.end > cursor else { continue }
            if point.start > cursor {
                output.append(GraphPoint(start: cursor, end: point.start))
            }
            point.start = max(cursor, point.start)
            output.append(point); cursor = point.end
        }
        if cursor < end { output.append(GraphPoint(start: cursor, end: end)) }
        return output
    }
}
