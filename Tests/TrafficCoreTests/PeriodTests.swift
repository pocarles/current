import XCTest
@testable import TrafficCore

final class PeriodTests: XCTestCase {
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("traffic-period-\(UUID().uuidString)").appendingPathComponent("history.sqlite") }

    func testRollingPeriodsUseSameIntervalForBytesPeaksAndCoverage() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location)
        let end = Date(timeIntervalSince1970: 1_800_057_600 + 12 * 3600)
        let specs = [(0.5, UInt64(100), 10.0), (3.0, 200, 20), (15.0, 300, 30), (200.0, 400, 40)]
        let observations = specs.map { age, bytes, peak in
            let start = end.addingTimeInterval(-age * 86400)
            return Observation(start: start, end: start.addingTimeInterval(60), received: bytes, sent: bytes * 2,
                               peakDown: peak, peakUp: peak / 2, offlineSeconds: 10, uncertainSeconds: 5)
        }
        let gapStart = end.addingTimeInterval(-3 * 86400 + 60)
        try await store.record(observations + [
            Observation(start: gapStart, end: gapStart.addingTimeInterval(60), coverage: .sleep),
            Observation(start: gapStart.addingTimeInterval(60), end: gapStart.addingTimeInterval(120), coverage: .appGap),
            Observation(start: gapStart.addingTimeInterval(120), end: gapStart.addingTimeInterval(180), coverage: .unobserved)
        ], now: end)
        for (period, bytes, peak, count) in [(HistoryPeriod.hours24, UInt64(100), 10.0, 1), (.days7, 300, 20, 2), (.days30, 600, 30, 3), (.all, 1000, 40, 4)] {
            let result = try await store.aggregate(from: period.start(before: end), to: end)
            XCTAssertEqual(result.summary.received, bytes); XCTAssertEqual(result.summary.sent, bytes * 2)
            XCTAssertEqual(result.summary.peakDown, peak); XCTAssertEqual(result.summary.peakUp, peak / 2)
            XCTAssertEqual(result.summary.observed, Double(count * 60), accuracy: 0.001)
            XCTAssertEqual(result.summary.offline, Double(count * 10), accuracy: 0.001)
            XCTAssertEqual(result.summary.uncertain, Double(count * 5), accuracy: 0.001)
            XCTAssertEqual(result.summary.sleep, period == .hours24 ? 0 : 60)
            XCTAssertEqual(result.summary.appGap, period == .hours24 ? 0 : 60)
            XCTAssertEqual(result.summary.unobserved, period == .hours24 ? 0 : 60)
            XCTAssertFalse(result.boundaryEstimated); XCTAssertFalse(result.peakIsUpperBound)
        }
        XCTAssertEqual(HistoryPeriod.hours24.start(before: end)?.timeIntervalSince(end), -86400)
        XCTAssertNil(HistoryPeriod.all.start(before: end))
    }

    func testPartialBoundaryEstimatesBytesAndBoundsPeakInsteadOfInventingItsTime() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location), minute = Date(timeIntervalSince1970: 1_800_057_600)
        try await store.record([
            Observation(start: minute, end: minute.addingTimeInterval(60), received: 600, sent: 1200, peakDown: 1000),
            Observation(start: minute.addingTimeInterval(60), end: minute.addingTimeInterval(120), received: 60, peakDown: 10)
        ], now: minute.addingTimeInterval(120))
        let result = try await store.aggregate(from: minute.addingTimeInterval(30), to: minute.addingTimeInterval(120))
        XCTAssertEqual(result.summary.received, 360); XCTAssertEqual(result.summary.sent, 600)
        XCTAssertEqual(result.summary.observed, 90)
        XCTAssertTrue(result.boundaryEstimated); XCTAssertTrue(result.peakIsUpperBound)
        XCTAssertEqual(result.summary.peakDown, 1000)
        // A higher peak in a full in-range bucket makes the combined peak exact.
        try await store.record([Observation(start: minute.addingTimeInterval(120), end: minute.addingTimeInterval(180), peakUp: 2000)], now: minute.addingTimeInterval(180))
        let exact = try await store.aggregate(from: minute.addingTimeInterval(30), to: minute.addingTimeInterval(180))
        XCTAssertFalse(exact.peakIsUpperBound)
    }

    func testPartialCurrentBucketKeepsAllSavedBytesAndLargeWholeTotalsStayExact() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location), minute = Date(timeIntervalSince1970: 1_800_057_600)
        let bytes: UInt64 = 9_007_199_254_740_993
        try await store.record([Observation(start: minute, end: minute.addingTimeInterval(0.125), received: bytes, peakDown: 99)], now: minute.addingTimeInterval(0.125))
        let result = try await store.aggregate(from: nil, to: minute.addingTimeInterval(20))
        XCTAssertEqual(result.summary.received, bytes)
        XCTAssertFalse(result.boundaryEstimated); XCTAssertFalse(result.peakIsUpperBound)
        XCTAssertEqual(result.savedThrough, minute.addingTimeInterval(0.125))
        let empty = try await store.aggregate(from: minute.addingTimeInterval(0.125), to: minute.addingTimeInterval(20))
        XCTAssertFalse(empty.hasRecords); XCTAssertEqual(empty.summary.received, 0)
    }

    func testUpperBoundaryExcludesFutureBucketsAfterClockChange() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location), minute = Date(timeIntervalSince1970: 1_800_057_600)
        try await store.record([
            Observation(start: minute, end: minute.addingTimeInterval(60), received: 100, peakDown: 10),
            Observation(start: minute.addingTimeInterval(3600), end: minute.addingTimeInterval(3660), received: 9999, peakDown: 9999)
        ], now: minute.addingTimeInterval(3660))
        let result = try await store.aggregate(from: nil, to: minute.addingTimeInterval(60))
        XCTAssertEqual(result.summary.received, 100); XCTAssertEqual(result.summary.peakDown, 10)
    }

    func testConnectionStreakResetsAcrossUnknownSleepStaleAndClockGaps() {
        var streak = ConnectionStreak()
        streak.advance(uptime: 100, observed: true, freshness: 40)
        XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 100, freshness: 40)
        streak.advance(uptime: 105, observed: true, freshness: 40)
        XCTAssertEqual(streak.duration, 5)
        streak.receive(.success, uptime: 110, freshness: 40)
        XCTAssertEqual(streak.duration, 10)
        streak.receive(.failed, uptime: 115, freshness: 40); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 120, freshness: 40); XCTAssertEqual(streak.duration, 0)
        streak.advance(uptime: 125, observed: false, freshness: 40); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 130, freshness: 40)
        streak.advance(uptime: 150, observed: true, freshness: 40); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 155, freshness: 40)
        streak.advance(uptime: 154, observed: true, freshness: 40); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 200, freshness: 40)
        for time in stride(from: 205.0, through: 240.0, by: 5) { streak.advance(uptime: time, observed: true, freshness: 40) }
        XCTAssertEqual(streak.duration, 40)
        streak.advance(uptime: 245, observed: true, freshness: 40); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 300, freshness: 130)
        for time in stride(from: 305.0, through: 425.0, by: 5) { streak.advance(uptime: time, observed: true, freshness: 130) }
        XCTAssertEqual(streak.duration, 125)
        streak.receive(.unexpected, uptime: 430, freshness: 130); XCTAssertNil(streak.duration)
        streak.receive(.success, uptime: 435, freshness: 130); streak.reset(); XCTAssertNil(streak.duration)
    }

    func testSelectedChartsMatchRangeAndPeakWithoutOverlappingTiersOrInventingCoverage() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location)
        let end = Date(timeIntervalSince1970: 1_800_057_600)
        let ages: [Double] = [1800, 7200, 2 * 86400, 20 * 86400, 200 * 86400]
        try await store.record(ages.enumerated().map { index, age in
            let start = end.addingTimeInterval(-age)
            return Observation(start: start, end: start.addingTimeInterval(60), received: UInt64(index + 1), peakDown: Double(index + 1) * 100)
        }, now: end)
        for (period, peak) in [(HistoryPeriod.hour, 100.0), (.hours24, 200), (.days7, 300), (.days30, 400), (.all, 500)] {
            let summary = try await store.aggregate(from: period.start(before: end), to: end)
            let chart = try await store.chart(from: period.start(before: end), to: end)
            XCTAssertEqual(chart.peak, peak)
            XCTAssertEqual(chart.peak, summary.summary.peakDown)
            XCTAssertEqual(chart.end, end)
            if let seconds = period.seconds { XCTAssertEqual(chart.end.timeIntervalSince(chart.start), seconds) }
            XCTAssertLessThanOrEqual(chart.points.count, 723)
            XCTAssertTrue(chart.points.contains { !$0.hasMeasurements && $0.hasGap }, "Unknown time must stay unknown")
            for pair in zip(chart.points, chart.points.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start) }
        }
    }

    func testLongChartIsBoundedAndKeepsZeroMixedGapsAndPeaks() async throws {
        let location = url(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = try HistoryStore(url: location), end = Date(timeIntervalSince1970: 1_800_057_600)
        let data = (0..<3653).map { index -> Observation in
            let start = end.addingTimeInterval(-Double(index + 1) * 86400)
            return Observation(start: start, end: start.addingTimeInterval(60), peakDown: index == 3000 ? 98765 : 0,
                               coverage: index == 2000 ? .appGap : .observed)
        }
        try await store.record(data, now: end)
        let chart = try await store.chart(from: nil, to: end, limit: 360)
        XCTAssertLessThanOrEqual(chart.points.count, 723)
        XCTAssertEqual(chart.peak, 98765)
        XCTAssertTrue(chart.points.contains { $0.hasMeasurements && $0.peakDown == 0 })
        XCTAssertTrue(chart.points.contains( where: \.hasGap))
        let summary = try await store.aggregate(from: nil, to: end)
        XCTAssertEqual(summary.summary.peakDown, chart.peak)
        XCTAssertEqual(summary.summary.appGap, 60)
    }
}
