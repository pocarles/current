import XCTest
import CNetwork
import Darwin
@testable import TrafficCore

final class MeasurementTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testPhysicalScopeExcludesVPNTunnelsAndPeerToPeer() {
        for name in ["utun0", "lo0", "bridge0", "awdl0", "llw0", "ap1", "vlan0", "en", "enx"] {
            XCTAssertFalse(InterfaceCounter(name: name, received: 0, sent: 0).included, name)
        }
        XCTAssertTrue(InterfaceCounter(name: "en0", received: 0, sent: 0).included)
        XCTAssertFalse(InterfaceCounter(name: "en1", received: 0, sent: 0, active: false).included)
        XCTAssertFalse(InterfaceCounter(name: "en1", received: 0, sent: 0, ethernet: false).included)
    }
    func test64BitCountersAndSimultaneousInterfacesWithoutVPNDoubleCount() {
        var engine = CounterEngine()
        let large: UInt64 = 5_000_000_000
        engine.rebaseline([
            .init(name: "en0", index: 1, received: large, sent: large),
            .init(name: "en1", index: 2, received: 1000, sent: 1000),
            .init(name: "utun0", received: 9000, sent: 9000)
        ], at: date, uptime: 10)
        let result = engine.sample([
            .init(name: "en0", index: 1, received: large + 1000, sent: large + 2000),
            .init(name: "en1", index: 2, received: 3000, sent: 4000),
            .init(name: "utun0", received: 20000, sent: 20000)
        ], at: date.addingTimeInterval(2), uptime: 12)!
        XCTAssertEqual(result.received, 3000); XCTAssertEqual(result.sent, 5000)
        XCTAssertEqual(result.peakDown, 1500); XCTAssertEqual(result.peakUp, 2500)
        XCTAssertEqual(result.coverage, .observed)
    }
    func testResetAndIndexReuseRebaselineWithoutSpike() {
        var engine = CounterEngine()
        engine.rebaseline([.init(name: "en0", received: 9000, sent: 9000)], at: date, uptime: 1)
        let reset = engine.sample([.init(name: "en0", received: 50, sent: 80)], at: date.addingTimeInterval(1), uptime: 2)!
        XCTAssertEqual(reset.received, 0); XCTAssertEqual(reset.coverage, .partial)
        let normal = engine.sample([.init(name: "en0", received: 150, sent: 280)], at: date.addingTimeInterval(2), uptime: 3)!
        XCTAssertEqual(normal.received, 100); XCTAssertEqual(normal.sent, 200)
        let replacement = engine.sample([.init(name: "en0", index: 8, received: 9999999, sent: 9999999)], at: date.addingTimeInterval(3), uptime: 4)!
        XCTAssertEqual(replacement.received, 0); XCTAssertEqual(replacement.coverage, .partial)
    }
    func testSwitchPreservesSurvivingInterfaceAndDoesNotCountNewLifetimeBytes() {
        var engine = CounterEngine()
        engine.rebaseline([.init(name: "en0", received: 100, sent: 100)], at: date, uptime: 1)
        let added = engine.sample([
            .init(name: "en0", received: 200, sent: 300), .init(name: "en1", index: 2, received: 100000, sent: 100000)
        ], at: date.addingTimeInterval(1), uptime: 2)!
        XCTAssertEqual(added.received, 100); XCTAssertEqual(added.sent, 200); XCTAssertEqual(added.coverage, .partial)
        let removed = engine.sample([.init(name: "en1", index: 2, received: 100100, sent: 100200)], at: date.addingTimeInterval(2), uptime: 3)!
        XCTAssertEqual(removed.received, 100); XCTAssertEqual(removed.sent, 200)
    }
    func testSleepAndDelayedTimerDoNotBecomeOvernightSpike() {
        var engine = CounterEngine()
        engine.rebaseline([.init(name: "en0", received: 100, sent: 100)], at: date, uptime: 1)
        let gap = engine.sample([.init(name: "en0", received: 1000000000, sent: 1000000000)], at: date.addingTimeInterval(3600), uptime: 3601)!
        XCTAssertEqual(gap.coverage, .unobserved); XCTAssertEqual(gap.received, 0)
        engine.rebaseline([.init(name: "en0", received: 1000000000, sent: 1000000000)], at: date.addingTimeInterval(3600), uptime: 3601)
        let next = engine.sample([.init(name: "en0", received: 1000000100, sent: 1000000100)], at: date.addingTimeInterval(3601), uptime: 3602)!
        XCTAssertEqual(next.peakDown, 100)
    }
    func testWallClockChangeCreatesGapRatherThanRate() {
        var engine = CounterEngine()
        engine.rebaseline([.init(name: "en0", received: 1, sent: 1)], at: date, uptime: 1)
        let forward = engine.sample([.init(name: "en0", received: 200, sent: 200)], at: date.addingTimeInterval(300), uptime: 2)!
        XCTAssertEqual(forward.coverage, .unobserved); XCTAssertEqual(forward.received, 0)
    }
    func testObservedZeroIsDistinctFromMissingBaseline() {
        var engine = CounterEngine()
        XCTAssertNil(engine.sample([], at: date, uptime: 1))
        let zero = engine.sample([], at: date.addingTimeInterval(1), uptime: 2)!
        XCTAssertEqual(zero.coverage, .observed); XCTAssertEqual(zero.received, 0)
    }
    func testMoreThan128VirtualInterfacesDoNotDropPhysicalCounters() throws {
        var capacities: [Int] = []
        let counters = try CounterReader.read { raw in
            capacities.append(raw.count)
            guard raw.count >= 129 else { return 129 }
            for index in 0..<129 {
                var item = TrafficInterface()
                let name = index == 128 ? "en0" : "utun\(index)"
                withUnsafeMutableBytes(of: &item.name) { bytes in
                    for (offset, byte) in name.utf8.enumerated() { bytes[offset] = byte }
                }
                item.index = UInt32(index + 1); item.flags = UInt32(IFF_UP | IFF_RUNNING)
                item.type = index == 128 ? 6 : 23; item.received = 123; item.sent = 456
                raw[index] = item
            }
            return 129
        }
        XCTAssertEqual(capacities, [128, 129])
        XCTAssertEqual(counters.count, 129)
        XCTAssertEqual(counters.filter(\.included).map(\.name), ["en0"])
        XCTAssertEqual(counters.last?.received, 123)
    }
    func testGrowingInterfaceSnapshotsHaveBoundedRetries() {
        var calls = 0
        XCTAssertThrowsError(try CounterReader.read { raw in calls += 1; return Int32(raw.count + 1) })
        XCTAssertEqual(calls, 4)
    }
}
