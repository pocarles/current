import XCTest
@testable import TrafficCore

final class LiveGraphTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    func testHourReductionIsBoundedAndPreservesPeaksAndMixedGaps() {
        var graph = LiveGraph()
        for index in 0..<7200 {
            let start = origin.addingTimeInterval(Double(index))
            graph.append(Observation(start: start, end: start.addingTimeInterval(1),
                peakDown: index == 5402 ? 99_999 : 1, peakUp: index == 5404 ? 77_777 : 2,
                coverage: index == 5405 ? .sleep : .observed))
        }
        XCTAssertLessThanOrEqual(graph.points.count, 361)
        XCTAssertEqual(graph.points.map(\.peakDown).max(), 99_999)
        XCTAssertEqual(graph.points.map(\.peakUp).max(), 77_777)
        let mixed = graph.points.first { $0.peakDown == 99_999 }!
        XCTAssertTrue(mixed.hasMeasurements); XCTAssertTrue(mixed.hasGap)
        XCTAssertTrue(graph.points.allSatisfy { $0.end > origin.addingTimeInterval(3600) })
    }
    func testWindowClipsHourBoundsAndKeepsMissingDistinctFromZero() {
        let end = origin.addingTimeInterval(3600)
        let points = LiveGraph.window([
            GraphPoint(start: origin.addingTimeInterval(-20), end: origin.addingTimeInterval(10), peakDown: 123, hasMeasurements: true, hasGap: false),
            GraphPoint(start: origin.addingTimeInterval(20), end: origin.addingTimeInterval(30), hasMeasurements: true, hasGap: false),
            GraphPoint(start: end, end: end.addingTimeInterval(10), peakDown: 9999, hasMeasurements: true, hasGap: false)
        ], ending: end)
        XCTAssertEqual(points.first?.start, origin); XCTAssertEqual(points.last?.end, end)
        XCTAssertEqual(points.map(\.peakDown).max(), 123)
        XCTAssertTrue(points.contains { !$0.hasMeasurements && $0.hasGap })
        XCTAssertTrue(points.contains { $0.hasMeasurements && !$0.hasGap && $0.peakDown == 0 })
        for pair in zip(points, points.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start) }
    }
    func testStoredHourRetainsPeaksGapsAndExcludesFutureData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-graph-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url), end = origin.addingTimeInterval(3600)
        try await store.record([
            Observation(start: origin.addingTimeInterval(-60), end: origin, peakDown: 8888),
            Observation(start: origin, end: origin.addingTimeInterval(60), peakDown: 20),
            Observation(start: origin.addingTimeInterval(60), end: origin.addingTimeInterval(90), peakDown: 999),
            Observation(start: origin.addingTimeInterval(90), end: origin.addingTimeInterval(120), coverage: .sleep),
            Observation(start: end.addingTimeInterval(60), end: end.addingTimeInterval(120), peakDown: 9999)
        ], now: end.addingTimeInterval(120))
        let points = try await store.recentGraph(ending: end)
        XCTAssertLessThanOrEqual(points.count, 123)
        XCTAssertEqual(points.first?.start, origin); XCTAssertEqual(points.last?.end, end)
        XCTAssertEqual(points.map(\.peakDown).max(), 999)
        XCTAssertTrue(points.contains { $0.hasMeasurements && $0.hasGap && $0.peakDown == 999 })
        XCTAssertTrue(points.contains { !$0.hasMeasurements && $0.hasGap })
    }
    func testDelayedAndClockRollbackSamplesCannotJoinAcrossGaps() {
        var graph = LiveGraph()
        graph.append(Observation(start: origin, end: origin.addingTimeInterval(1), peakDown: 100))
        graph.append(Observation(start: origin.addingTimeInterval(1), end: origin.addingTimeInterval(3601), coverage: .unobserved))
        XCTAssertLessThanOrEqual(graph.points.count, 361)
        XCTAssertTrue(graph.points.allSatisfy(\.hasGap))
        graph.append(Observation(start: origin.addingTimeInterval(100), end: origin.addingTimeInterval(101), peakDown: 5))
        XCTAssertEqual(graph.points.count, 1); XCTAssertEqual(graph.points[0].peakDown, 5)
    }
}
