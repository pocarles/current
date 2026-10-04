import XCTest
@testable import TrafficCore

final class HealthTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testTwoSpacedFailureRoundsConfirmOutageAndRecovery() {
        var machine = HealthMachine()
        _ = machine.receive(.success, at: date)
        XCTAssertEqual(machine.state, .online)
        _ = machine.receive(.failed, at: date.addingTimeInterval(1))
        XCTAssertEqual(machine.state, .uncertain); XCTAssertNil(machine.outageStart)
        let outage = machine.receive(.failed, at: date.addingTimeInterval(9))!
        XCTAssertEqual(outage.to, .offline); XCTAssertEqual(outage.outageStart, date.addingTimeInterval(9))
        XCTAssertNil(machine.receive(.failed, at: date.addingTimeInterval(20)))
        let recovery = machine.receive(.success, at: date.addingTimeInterval(40))!
        XCTAssertEqual(recovery.from, .offline); XCTAssertEqual(recovery.to, .online)
        XCTAssertEqual(recovery.outageStart, date.addingTimeInterval(9)); XCTAssertNil(machine.outageStart)
    }
    func testRapidFailuresDoNotAlertAndSuccessClearsSuspicion() {
        var machine = HealthMachine()
        _ = machine.receive(.failed, at: date)
        _ = machine.receive(.failed, at: date.addingTimeInterval(1))
        XCTAssertEqual(machine.state, .uncertain)
        _ = machine.receive(.success, at: date.addingTimeInterval(2))
        _ = machine.receive(.failed, at: date.addingTimeInterval(10))
        XCTAssertEqual(machine.state, .uncertain)
    }
    func testCaptiveOrUnexpectedResponseIsUncertain() {
        var machine = HealthMachine()
        for i in 0..<10 { _ = machine.receive(.unexpected, at: date.addingTimeInterval(Double(i) * 30)) }
        XCTAssertEqual(machine.state, .uncertain); XCTAssertNil(machine.outageStart)
    }
    func testWakeResetsFailureHistoryNoFalseOvernightOutage() {
        var machine = HealthMachine()
        _ = machine.receive(.failed, at: date)
        machine.reset(to: .sleeping)
        machine.reset()
        _ = machine.receive(.failed, at: date.addingTimeInterval(3600))
        XCTAssertEqual(machine.state, .uncertain); XCTAssertNil(machine.outageStart)
    }
    func testPortalAfterOutageBecomesUncertainAndRetainsRecoveryContext() {
        var machine = HealthMachine()
        _ = machine.receive(.failed, at: date)
        let outage = machine.receive(.failed, at: date.addingTimeInterval(8))!
        XCTAssertTrue(outage.newOutage)
        _ = machine.receive(.unexpected, at: date.addingTimeInterval(20))
        XCTAssertEqual(machine.state, .uncertain)
        XCTAssertEqual(machine.outageStart, date.addingTimeInterval(8))
        _ = machine.receive(.failed, at: date.addingTimeInterval(30))
        let phase = machine.receive(.failed, at: date.addingTimeInterval(40))!
        XCTAssertFalse(phase.newOutage)
        let recovery = machine.receive(.success, at: date.addingTimeInterval(50))!
        XCTAssertEqual(recovery.outageStart, date.addingTimeInterval(8))
        XCTAssertEqual(recovery.to, .online)
    }
    func testProbeRequiresExactResponseNoRedirectNoUnexpectedBody() {
        let endpoint = ProbeEndpoint.primary
        XCTAssertTrue(endpoint.accepts(status: 204, body: Data(), finalURL: endpoint.url))
        XCTAssertFalse(endpoint.accepts(status: 200, body: Data(), finalURL: endpoint.url))
        XCTAssertFalse(endpoint.accepts(status: 204, body: Data("portal".utf8), finalURL: endpoint.url))
        XCTAssertFalse(endpoint.accepts(status: 204, body: Data(), finalURL: URL(string: "https://example.com/")))
    }
}
