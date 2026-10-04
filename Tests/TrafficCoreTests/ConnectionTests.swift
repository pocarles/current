import XCTest
@testable import TrafficCore

final class ConnectionTests: XCTestCase {
    func testTailscaleRequiresUniqueFullLocalIdentityAndMatchingInterfaceIndex() {
        let own: Set<String> = ["100.80.1.2", "fd7a::123"]
        XCTAssertNil(ConnectionInventory.matchTailscale(selfAddresses: [], interfaceAddresses: ["utun3": own]))
        XCTAssertNil(ConnectionInventory.matchTailscale(selfAddresses: own, interfaceAddresses: ["utun3": ["100.80.1.2"]]))
        XCTAssertNil(ConnectionInventory.matchTailscale(selfAddresses: own, interfaceAddresses: ["en0": own]))
        XCTAssertNil(ConnectionInventory.matchTailscale(selfAddresses: own, interfaceAddresses: ["utun3": own, "utun4": own]))
        XCTAssertEqual(ConnectionInventory.matchTailscale(selfAddresses: own, interfaceAddresses: ["utun3": own, "utun4": ["100.90.2.3"]]), "utun3")
        let inventory = ConnectionInventory(tailscaleInterface: "utun3", tailscaleIndex: 3)
        XCTAssertEqual(inventory.kind(of: .init(name: "utun3", index: 3, received: 0, sent: 0, ethernet: false)), .tailscale)
        XCTAssertEqual(inventory.kind(of: .init(name: "utun3", index: 4, received: 0, sent: 0, ethernet: false)), .vpn)
        XCTAssertEqual(inventory.kind(of: .init(name: "utun8", index: 8, received: 0, sent: 0, ethernet: false)), .vpn)
    }
    func testBluetoothMeansAnActualNetworkInterfaceAndNoAccessoryTraffic() {
        let inventory = ConnectionInventory(physicalKinds: ["en8": .bluetoothPAN, "Keyboard": .bluetoothPAN])
        XCTAssertEqual(inventory.kind(of: .init(name: "en8", received: 0, sent: 0)), .bluetoothPAN)
        XCTAssertNil(inventory.kind(of: .init(name: "Keyboard", received: 900, sent: 900, ethernet: false)))
        let rows = ConnectionDetail.make(counters: [.init(name: "Keyboard", received: 900, sent: 900, ethernet: false)], rates: [], inventory: inventory)
        XCTAssertFalse(rows.contains { $0.kind == .bluetoothPAN })
        let pan = InterfaceCounter(name: "en8", received: 100, sent: 50)
        XCTAssertFalse(ConnectionDetail.make(counters: [pan], rates: [], inventory: inventory).contains { $0.kind == .bluetoothPAN })
        let measured = ConnectionDetail.make(counters: [pan], rates: [InterfaceRate(name: "en8", down: 0, up: 50)], inventory: inventory)
        XCTAssertEqual(measured.first { $0.kind == .bluetoothPAN }?.down, 0)
        XCTAssertEqual(measured.first { $0.kind == .bluetoothPAN }?.up, 50)
    }
    func testInterfaceRatesResetOnGapsSwitchesAndCounterResets() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var engine = InterfaceRateEngine()
        engine.rebaseline([.init(name: "en0", received: 100, sent: 200)], at: origin, uptime: 0)
        let first = engine.sample([.init(name: "en0", received: 150, sent: 240)], at: origin.addingTimeInterval(1), uptime: 1)
        XCTAssertEqual(first[0].down, 50); XCTAssertEqual(first[0].up, 40)
        let reset = engine.sample([.init(name: "en0", received: 0, sent: 0)], at: origin.addingTimeInterval(2), uptime: 2)
        XCTAssertNil(reset[0].down)
        let swapped = engine.sample([.init(name: "en0", index: 99, received: 900, sent: 900)], at: origin.addingTimeInterval(3), uptime: 3)
        XCTAssertNil(swapped[0].down)
        let gap = engine.sample([.init(name: "en0", index: 99, received: 999_999, sent: 999_999)], at: origin.addingTimeInterval(3600), uptime: 3600)
        XCTAssertNil(gap[0].down)
        let zero = engine.sample([.init(name: "en0", index: 99, received: 999_999, sent: 999_999)], at: origin.addingTimeInterval(3601), uptime: 3601)
        XCTAssertEqual(zero[0].down, 0)
    }
    func testSimultaneousPhysicalAndTunnelRatesRemainSeparate() {
        let counters: [InterfaceCounter] = [
            .init(name: "en0", received: 100, sent: 100), .init(name: "en1", received: 200, sent: 200),
            .init(name: "utun2", index: 2, received: 500, sent: 500, ethernet: false)
        ]
        let inventory = ConnectionInventory(physicalKinds: ["en0": .wifi, "en1": .ethernet], tailscaleInterface: "utun2", tailscaleIndex: 2)
        let rows = ConnectionDetail.make(counters: counters, rates: counters.map { InterfaceRate(name: $0.name, down: Double($0.received), up: Double($0.sent)) }, inventory: inventory)
        XCTAssertEqual(rows.first { $0.kind == .wifi }?.down, 100)
        XCTAssertEqual(rows.first { $0.kind == .ethernet }?.down, 200)
        XCTAssertEqual(rows.first { $0.kind == .tailscale }?.down, 500)
        XCTAssertEqual(counters.filter(\.included).reduce(0) { $0 + $1.received }, 300)
    }
    func testChartScaleIsReadableBoundedAndAlwaysCoversMeasuredPeaks() {
        for (value, expected) in [(0.0, 1000.0), (842_000, 1_000_000), (1_800_000, 2_000_000), (2_010_000, 2_500_000), (100_000_000, 100_000_000), (102_000_000, 125_000_000), (0.5, 1000)] {
            XCTAssertEqual(GraphScale.upperBound(value), expected)
        }
        XCTAssertTrue(GraphScale.upperBound(.greatestFiniteMagnitude).isFinite)
        XCTAssertGreaterThanOrEqual(GraphScale.upperBound(.greatestFiniteMagnitude), .greatestFiniteMagnitude)
    }
    func testUnattributedTunnelsAndInactiveOptionalRowsAreNeverPresented() {
        let tunnel = InterfaceCounter(name: "utun2", index: 2, received: 100, sent: 50, ethernet: false)
        let rates = [InterfaceRate(name: "utun2", down: 100, up: 50)]
        XCTAssertTrue(ConnectionDetail.make(counters: [tunnel], rates: rates, inventory: ConnectionInventory(tailscaleInstalled: true)).isEmpty)
        let attributed = ConnectionInventory(tailscaleInterface: "utun2", tailscaleIndex: 2)
        XCTAssertEqual(ConnectionDetail.make(counters: [tunnel], rates: rates, inventory: attributed).map(\.kind), [.tailscale])
        let wrongIndex = ConnectionInventory(tailscaleInterface: "utun2", tailscaleIndex: 3)
        XCTAssertTrue(ConnectionDetail.make(counters: [tunnel], rates: rates, inventory: wrongIndex).isEmpty)
    }
}
