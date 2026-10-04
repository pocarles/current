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
        XCTAssertEqual(buffer.pending.first?.coverage, .unobserved)
        XCTAssertEqual(buffer.pending.first?.duration, 401)
        XCTAssertEqual(buffer.pending.reduce(0) { $0 + $1.duration }, 4000)
    }
}
