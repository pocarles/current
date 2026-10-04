import XCTest
@testable import TrafficCore

final class OnlineEvidenceTests: XCTestCase {
    func testEvidenceIsAtomicBackupFriendlyAndOptionalInSchemaThree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-online-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let missing = try await store.onlineEvidence(); XCTAssertNil(missing)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = OnlineEvidence(since: now.addingTimeInterval(-1000), seconds: 900, hasGaps: true)
        try await store.record([], now: now, connectivity: .replace(evidence))
        let saved = try await store.onlineEvidence(); XCTAssertEqual(saved, evidence)
        do {
            try await store.record([Observation(start: now, end: now.addingTimeInterval(1), received: 999)], now: now.addingTimeInterval(1),
                connectivity: .replace(OnlineEvidence(since: now, seconds: .nan)))
            XCTFail("Invalid evidence must roll the entire transaction back")
        } catch {}
        let stillSaved = try await store.onlineEvidence(); XCTAssertEqual(stillSaved, evidence)
        let rows = try await store.rows(); XCTAssertTrue(rows.isEmpty)
        let backupURL = directory.appendingPathComponent("backup.sqlite")
        try await store.backup(to: backupURL)
        let backup = try HistoryStore(url: backupURL)
        let copied = try await backup.onlineEvidence(); XCTAssertEqual(copied, evidence)
        try await store.record([], now: now, connectivity: .replace(nil))
        let cleared = try await store.onlineEvidence(); XCTAssertNil(cleared)
    }
}
