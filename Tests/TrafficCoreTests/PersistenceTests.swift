import XCTest
@testable import TrafficCore

final class PersistenceTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testWriteFailureRetriesBatchWithReadingsAddedDuringWrite() {
        var buffer = PersistenceBuffer()
        buffer.append(Observation(start: date, end: date.addingTimeInterval(1), received: 100))
        buffer.event(at: date, kind: "launch", detail: "started")
        let batch = buffer.begin()!
        XCTAssertEqual(batch.observations.count, 1)
        XCTAssertNil(buffer.begin())
        buffer.append(Observation(start: date.addingTimeInterval(1), end: date.addingTimeInterval(2), received: 200))
        buffer.failed()
        let retry = buffer.begin()!
        XCTAssertEqual(retry.observations.reduce(0) { $0 + $1.received }, 300)
        XCTAssertEqual(retry.events.count, 1)
    }
    func testCommittedBatchNeverReturnsToRetryQueue() {
        var buffer = PersistenceBuffer()
        buffer.append(Observation(start: date, end: date.addingTimeInterval(1), received: 100))
        _ = buffer.begin()
        buffer.append(Observation(start: date.addingTimeInterval(1), end: date.addingTimeInterval(2), received: 200))
        buffer.committed()
        XCTAssertEqual(buffer.unsaved.reduce(0) { $0 + $1.received }, 200)
        XCTAssertEqual(buffer.begin()?.observations.reduce(0) { $0 + $1.received }, 200)
    }
    func testBufferOverflowBecomesExplicitGapInsteadOfObservedZero() {
        var buffer = PersistenceBuffer()
        for i in 0..<4000 {
            buffer.append(Observation(start: date.addingTimeInterval(Double(i)), end: date.addingTimeInterval(Double(i + 1)), received: 10))
        }
        XCTAssertEqual(buffer.pending.count, 3600)
        // Folded seconds count as unobserved (partial), never observed zero, and keep their bytes.
        XCTAssertEqual(buffer.pending.first?.coverage, .partial)
        XCTAssertEqual(buffer.pending.first?.received, 4010)
        XCTAssertEqual(buffer.pending.first?.duration, 401)
        XCTAssertEqual(buffer.pending.reduce(0) { $0 + $1.duration }, 4000)
    }
    func testQueueOverflowFoldKeepsBytesAndPeaks() {
        var buffer = PersistenceBuffer()
        for second in 0..<3601 {
            let start = date.addingTimeInterval(Double(second))
            buffer.append(Observation(start: start, end: start.addingTimeInterval(1), received: 10, sent: 1, peakDown: Double(second)))
        }
        XCTAssertEqual(buffer.pending.count, 3600)
        XCTAssertEqual(buffer.unsaved.reduce(0) { $0 + $1.received }, 36010)
        XCTAssertEqual(buffer.unsaved.reduce(0) { $0 + $1.sent }, 3601)
        XCTAssertEqual(buffer.pending[0].coverage, .partial); XCTAssertEqual(buffer.pending[0].peakDown, 1)
        XCTAssertEqual(buffer.pending[0].duration, 2)
    }
}
