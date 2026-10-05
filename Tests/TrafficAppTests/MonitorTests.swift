import XCTest
import Foundation
import TrafficCore
@testable import Traffic

private final class TestInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_791_028_800) // isolated test day
    private var uptime: Double = 1
    private var received: UInt64 = 0, sent: UInt64 = 0
    private var broken = false
    private var extra: [InterfaceCounter] = []
    func now() -> Date { lock.withLock { date } }
    func clock() -> Double { lock.withLock { uptime } }
    func counters() throws -> [InterfaceCounter] {
        try lock.withLock {
            if broken { throw HistoryError("mock counters unavailable") }
            return [.init(name: "en0", received: received, sent: sent)] + extra
        }
    }
    func advance(_ seconds: Double, received: UInt64 = 0, sent: UInt64 = 0) {
        lock.withLock { date = date.addingTimeInterval(seconds); uptime += seconds; self.received += received; self.sent += sent }
    }
    func setWallClock(by seconds: Double) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func setExtra(_ counters: [InterfaceCounter]) { lock.withLock { extra = counters } }
    func setBroken(_ broken: Bool) { lock.withLock { self.broken = broken } }
}
private actor ProbeSequence {
    var outcomes: [ProbeOutcome]
    init(_ outcomes: [ProbeOutcome]) { self.outcomes = outcomes }
    func next() -> ProbeOutcome { outcomes.isEmpty ? .success : outcomes.removeFirst() }
}
private actor InventoryGate {
    var calls: [Bool] = []
    var pending: CheckedContinuation<Void, Never>?
    func read(_ tunnels: Bool) async -> ConnectionInventory {
        calls.append(tunnels)
        if !tunnels { await withCheckedContinuation { pending = $0 } }
        return ConnectionInventory(physicalKinds: ["en0": .wifi], tailscaleInstalled: tunnels)
    }
    func release() { pending?.resume(); pending = nil }
}
private actor CancelledProbeFixture {
    var first = true
    func next() async -> ProbeOutcome {
        if !first { return .success }
        first = false
        do { try await Task.sleep(for: .seconds(10)); return .success }
        catch { return .failed }
    }
}
private actor FaultyRepository: HistoryRepository {
    let underlying: HistoryStore
    var failReads = false, failWrites = false
    var delayAggregate = false
    init(_ store: HistoryStore) { underlying = store }
    func inject(reads: Bool = false, writes: Bool = false) { failReads = reads; failWrites = writes }
    func delayNextAggregate() { delayAggregate = true }
    func lastRecorded() async throws -> Date? { try await underlying.lastRecorded() }
    func record(_ observations: [Observation], now: Date, events: [RecordedEvent], connectivity: ConnectivityUpdate) async throws {
        if failWrites { throw HistoryError("mock disk failure") }
        try await underlying.record(observations, now: now, events: events, connectivity: connectivity)
    }
    func onlineEvidence() async throws -> OnlineEvidence? { try await underlying.onlineEvidence() }
    func recentGraph(ending end: Date) async throws -> [GraphPoint] { try await underlying.recentGraph(ending: end) }
    func chart(from start: Date?, to end: Date, limit: Int) async throws -> PeriodChart { try await underlying.chart(from: start, to: end, limit: limit) }
    func today(at date: Date, calendar: Calendar) async throws -> HistorySummary {
        if failReads { throw HistoryError("mock read failure") }
        return try await underlying.today(at: date, calendar: calendar)
    }
    func aggregate(from start: Date?, to end: Date) async throws -> PeriodHistory {
        if failReads { throw HistoryError("mock read failure") }
        let result = try await underlying.aggregate(from: start, to: end)
        let delay = delayAggregate; delayAggregate = false
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        return result
    }
    func rows(grain: Int, since: Date, limit: Int) async throws -> [HistoryRow] { try await underlying.rows(grain: grain, since: since, limit: limit) }
    func events(limit: Int) async throws -> [HistoryEvent] { try await underlying.events(limit: limit) }
    func backup(to destination: URL) async throws { try await underlying.backup(to: destination) }
    func exportCSV(to destination: URL) async throws { try await underlying.exportCSV(to: destination) }
}

@MainActor final class MonitorTests: XCTestCase {
    private var directory: URL!
    private var preferences: UserDefaults!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Traffic-app-test-\(UUID().uuidString)")
        preferences = UserDefaults(suiteName: "org.traffic.test.\(UUID().uuidString)")!
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func model(_ inputs: TestInputs, repository: (any HistoryRepository)? = nil, probe: ProbeSequence = ProbeSequence([])) -> MonitorModel {
        MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), repository: repository, automatic: false, preferences: preferences,
                     counters: { try inputs.counters() }, uptime: { inputs.clock() }, now: { inputs.now() }, probe: { await probe.next() }, inventory: { _ in ConnectionInventory(physicalKinds: ["en0": .wifi]) })
    }
    func testFirstOpenQueuesTunnelIdentityBehindStartupInventory() async throws {
        let gate = InventoryGate(), inputs = TestInputs()
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false,
            preferences: preferences, counters: { try inputs.counters() }, now: { inputs.now() },
            inventory: { await gate.read($0) })
        let first = Task { await model.refreshConnectionInventory(includeTailscale: false) }
        for _ in 0..<1000 {
            if await !gate.calls.isEmpty { break }
            await Task.yield()
        }
        model.popoverOpen = true
        await model.refreshConnectionInventory(includeTailscale: true)
        await gate.release()
        await first.value
        let calls = await gate.calls
        XCTAssertEqual(calls, [false, true])
        XCTAssertNil(model.connectionDetails.first { $0.kind == .tailscale })
        model.popoverOpen = false
    }
    func testManualRefreshReportsProgressThrottlingAndUpdatesLastCheck() async throws {
        let inputs = TestInputs(), model = model(inputs, probe: ProbeSequence([.success, .unexpected, .success]))
        await model.start().value
        model.refreshConnectivity()
        XCTAssertTrue(model.checkInProgress)
        await model.checkConnectivity()?.value
        XCTAssertFalse(model.checkInProgress)
        XCTAssertFalse(model.checkPending)
        XCTAssertEqual(model.lastChecked, inputs.now())
        XCTAssertEqual(model.health, .online)
        let checked = model.lastChecked
        inputs.advance(1)
        model.refreshConnectivity()
        XCTAssertTrue(model.checkPending)
        XCTAssertFalse(model.checkInProgress)
        XCTAssertEqual(model.lastChecked, checked, "Throttled refresh must not fabricate a completed check")
        inputs.advance(4)
        await model.checkConnectivity()?.value
        XCTAssertFalse(model.checkPending)
        XCTAssertEqual(model.lastChecked, inputs.now())
        XCTAssertEqual(model.health, .uncertain)
        model.setProbes(false); model.refreshConnectivity()
        XCTAssertFalse(model.checkInProgress); XCTAssertFalse(model.checkPending)
    }
    func testCommittedWriteFollowedByReadFailureDoesNotDuplicateBytes() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store), model = model(inputs, repository: repository)
        await model.start().value
        inputs.advance(1, received: 100, sent: 200); model.sample()
        await repository.inject(reads: true)
        let firstSaved = await model.flushAndWait(); XCTAssertTrue(firstSaved)
        XCTAssertEqual(model.today.received, 100)
        XCTAssertEqual(model.today.sent, 200)
        XCTAssertEqual(model.today.observed, 1)
        XCTAssertEqual(model.today.peakDown, 100)
        XCTAssertTrue(model.errorMessage?.contains("History saved") == true)
        await repository.inject()
        let secondSaved = await model.flushAndWait(); XCTAssertTrue(secondSaved)
        let rows = try await store.rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 100)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.sent }, 200)
    }
    func testPeriodChangesLoadMatchingSavedTotalsAndPeak() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let end = inputs.now()
        try await store.record([
            Observation(start: end.addingTimeInterval(-3600), end: end.addingTimeInterval(-3540), received: 100, peakDown: 10),
            Observation(start: end.addingTimeInterval(-3 * 86400), end: end.addingTimeInterval(-3 * 86400 + 60), received: 200, peakDown: 20),
            Observation(start: end.addingTimeInterval(-15 * 86400), end: end.addingTimeInterval(-15 * 86400 + 60), received: 300, peakDown: 30)
        ], now: end)
        let model = model(inputs, repository: store)
        await model.start().value
        await model.loadPeriod()
        XCTAssertEqual(model.periodHistory?.summary.received, 100)
        XCTAssertEqual(model.periodHistory?.summary.peakDown, 10)
        for (period, bytes, peak) in [(HistoryPeriod.hours24, UInt64(100), 10.0), (.days7, 300, 20), (.days30, 600, 30), (.all, 600, 30), (.hour, 100, 10)] {
            model.selectPeriod(period)
            XCTAssertNil(model.periodHistory)
            for _ in 0..<100 where model.periodHistory == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.period, period); XCTAssertEqual(model.periodHistory?.summary.received, bytes)
            XCTAssertEqual(model.periodHistory?.summary.peakDown, peak)
            XCTAssertEqual(model.displayedPeak, peak)
            if let seconds = period.seconds { XCTAssertEqual(model.displayedChart.end.timeIntervalSince(model.displayedChart.start), seconds) }
            XCTAssertFalse(model.periodLoading)
        }
    }
    func testOnlineObservedTimeNeedsSuccessAndExcludesSleepAndMissingSamples() async throws {
        let inputs = TestInputs(), probe = ProbeSequence([.success, .failed, .success, .success])
        let model = model(inputs, probe: probe)
        await model.start().value
        XCTAssertNil(model.connectedDuration)
        await model.checkConnectivity()?.value
        XCTAssertEqual(model.connectedDuration, 0)
        inputs.advance(5); model.sample(); XCTAssertEqual(model.connectedDuration, 5)
        await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .uncertain); XCTAssertNil(model.connectedDuration)
        inputs.advance(5); await model.checkConnectivity()?.value
        XCTAssertEqual(model.connectedDuration, 0)
        inputs.advance(5); model.sample(); XCTAssertEqual(model.connectedDuration, 5)
        model.willSleep(); XCTAssertNil(model.connectedDuration)
        inputs.advance(3600); model.didWake(); XCTAssertNil(model.connectedDuration)
        inputs.advance(5); await model.checkConnectivity()?.value
        XCTAssertEqual(model.connectedDuration, 0)
        inputs.setBroken(true); inputs.advance(1); model.sample(); XCTAssertNil(model.connectedDuration)
        model.setProbes(false); XCTAssertNil(model.connectedDuration)
        XCTAssertEqual(Format.connectionDuration(1062), "17m 42s")
    }
    func testContinuousIntervalNeverRestoresAccumulatedOrAppOffTime() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try await store.record([], now: inputs.now(), connectivity: .replace(OnlineEvidence(since: inputs.now().addingTimeInterval(-999), seconds: 999)))
        let first = model(inputs, repository: store)
        await first.start().value; XCTAssertNil(first.connectedDuration)
        await first.checkConnectivity()?.value; XCTAssertEqual(first.connectedDuration, 0)
        inputs.advance(5); first.sample()
        // A duplicate timer/probe instant must preserve the continuous interval.
        first.sample(); XCTAssertEqual(first.connectedDuration, 5)
        let quitSaved = await withCheckedContinuation { continuation in first.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertTrue(quitSaved)
        let retired = try await store.onlineEvidence(); XCTAssertNil(retired)
        inputs.advance(120, received: 100_000)
        let second = model(inputs, repository: store)
        await second.start().value; XCTAssertNil(second.connectedDuration)
        await second.checkConnectivity()?.value; XCTAssertEqual(second.connectedDuration, 0)
        inputs.advance(5); second.sample(); XCTAssertEqual(second.connectedDuration, 5)
        second.invalidateConnectionInterval(); XCTAssertNil(second.connectedDuration)
        inputs.advance(5); await second.checkConnectivity()?.value; XCTAssertEqual(second.connectedDuration, 0)
    }
    func testCrashRestoresHourHistoryButNeverAConnectionInterval() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let end = inputs.now()
        try await store.record([Observation(start: end.addingTimeInterval(-1800), end: end.addingTimeInterval(-1740), peakDown: 987)], now: end)
        let first = model(inputs, repository: store); await first.start().value
        XCTAssertEqual(first.graph.map(\.peakDown).max(), 987)
        await first.checkConnectivity()?.value
        inputs.advance(5); first.sample(); let flushed = await first.flushAndWait(); XCTAssertTrue(flushed)
        inputs.advance(5); first.sample(); XCTAssertEqual(first.connectedDuration, 10)
        let restarted = model(inputs, repository: store); await restarted.start().value
        XCTAssertNil(restarted.connectedDuration)
        await restarted.checkConnectivity()?.value; XCTAssertEqual(restarted.connectedDuration, 0)
        XCTAssertEqual(restarted.graph.first?.start, inputs.now().addingTimeInterval(-3600))
        XCTAssertEqual(restarted.graph.last?.end, inputs.now())
        XCTAssertEqual(restarted.graph.map(\.peakDown).max(), 987)
    }
    func testInterfaceDetailsKeepOverlayBytesOutsidePhysicalTotals() async throws {
        let inputs = TestInputs()
        inputs.setExtra([.init(name: "utun9", index: 99, received: 1000, sent: 2000, ethernet: false)])
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false, preferences: preferences,
            counters: { try inputs.counters() }, uptime: { inputs.clock() }, now: { inputs.now() }, probe: { .success },
            inventory: { _ in ConnectionInventory(physicalKinds: ["en0": .wifi], tailscaleInterface: "utun9", tailscaleInstalled: true, tailscaleAvailable: true, tailscaleIndex: 99,
                addresses: ["en0": ["192.168.1.4"], "utun9": ["100.80.1.2"]]) })
        await model.start().value; await model.refreshConnectionInventory(includeTailscale: true)
        model.popoverOpen = true
        inputs.setExtra([.init(name: "utun9", index: 99, received: 1500, sent: 2200, ethernet: false)])
        inputs.advance(1, received: 100, sent: 50); model.sample()
        XCTAssertEqual(model.down, 100); XCTAssertEqual(model.up, 50)
        XCTAssertEqual(model.connectionDetails.first { $0.kind == .wifi }?.down, 100)
        XCTAssertEqual(model.connectionDetails.first { $0.kind == .tailscale }?.down, 500)
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        XCTAssertEqual(model.today.received, 100)
        model.willSleep(); inputs.advance(3600)
        inputs.setExtra([.init(name: "utun9", index: 99, received: 1_000_000, sent: 2_000_000, ethernet: false)])
        model.didWake(); inputs.advance(1, received: 10); model.sample()
        XCTAssertEqual(model.down, 10)
        XCTAssertNil(model.connectionDetails.first { $0.kind == .tailscale }?.down)
    }
    func testLateOldPeriodResponseCannotOverwriteNewSelection() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let end = inputs.now(), repository = FaultyRepository(store)
        try await store.record([
            Observation(start: end.addingTimeInterval(-3600), end: end.addingTimeInterval(-3540), received: 100, peakDown: 10),
            Observation(start: end.addingTimeInterval(-3 * 86400), end: end.addingTimeInterval(-3 * 86400 + 60), received: 200, peakDown: 20)
        ], now: end)
        let model = model(inputs, repository: repository)
        await model.start().value
        model.period = .days7
        await repository.delayNextAggregate()
        let old = Task { await model.loadPeriod() }
        try await Task.sleep(for: .milliseconds(10))
        model.selectPeriod(.hours24)
        for _ in 0..<100 where model.periodHistory == nil { try await Task.sleep(for: .milliseconds(5)) }
        await old.value
        XCTAssertEqual(model.period, .hours24)
        XCTAssertEqual(model.periodHistory?.summary.received, 100); XCTAssertEqual(model.periodHistory?.summary.peakDown, 10)
    }
    func testWriteFailureRetriesAndExportDoesNotSilentlyOmitPendingBytes() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store), model = model(inputs, repository: repository)
        await model.start().value
        inputs.advance(1, received: 100); model.sample()
        await repository.inject(writes: true)
        let failed = await model.flushAndWait(); XCTAssertFalse(failed)
        do { try await model.export(to: directory.appendingPathComponent("bad.csv"), backup: false); XCTFail("Export must stop if flush fails") } catch {}
        inputs.advance(1, received: 200); model.sample()
        await repository.inject()
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        let rows = try await store.rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 300)
    }
    func testFailedQuitKeepsPendingBytesAndAllowsRetry() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store), model = model(inputs, repository: repository)
        await model.start().value
        inputs.advance(1, received: 123); model.sample()
        await repository.inject(writes: true)
        let failed = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertFalse(failed)
        XCTAssertEqual(model.today.received, 123)
        XCTAssertTrue(model.errorMessage?.contains("still running") == true)
        await repository.inject()
        let saved = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertTrue(saved)
        let rows = try await store.rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 123)
    }
    func testCancelledQuitDoesNotBecomeAQuitEventInALaterOrdinaryFlush() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store), model = model(inputs, repository: repository)
        await model.start().value
        inputs.advance(1, received: 123); model.sample()
        await repository.inject(writes: true)
        let failed = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertFalse(failed)
        await repository.inject()
        let flushed = await model.flushAndWait(); XCTAssertTrue(flushed)
        let ordinaryEvents = try await store.events()
        XCTAssertFalse(ordinaryEvents.contains { $0.kind == "quit" })
        let rows = try await store.rows(); XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 123)
        let successfulQuit = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertTrue(successfulQuit)
        let finalEvents = try await store.events()
        XCTAssertEqual(finalEvents.filter { $0.kind == "quit" }.count, 1)
    }
    func testCancelledQuitClearsInFlightProbeAndAllowsAnotherCheck() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store), probe = CancelledProbeFixture()
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), repository: repository,
            automatic: false, preferences: preferences, counters: { try inputs.counters() },
            uptime: { inputs.clock() }, now: { inputs.now() }, probe: { await probe.next() }, inventory: { _ in ConnectionInventory() })
        await model.start().value
        let pending = model.checkConnectivity()
        await Task.yield()
        await repository.inject(writes: true)
        let failed = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        await pending?.value
        XCTAssertFalse(failed); XCTAssertFalse(model.checkInProgress)
        await repository.inject()
        inputs.advance(6)
        await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .online); XCTAssertFalse(model.checkInProgress)
    }
    func testHourPeakUsesLiveSeriesWithoutSQLBoundaryFlag() {
        let model = model(TestInputs()), now = Date()
        var summary = HistorySummary(); summary.peakDown = 900
        model.periodHistory = PeriodHistory(summary: summary, end: now, peakIsUpperBound: true)
        model.graph = [GraphPoint(start: now.addingTimeInterval(-10), end: now, peakDown: 123, peakUp: 42, hasMeasurements: true, hasGap: false)]
        XCTAssertEqual(model.displayedPeak, 123); XCTAssertFalse(model.displayedPeakIsUpperBound)
        model.period = .days7
        XCTAssertEqual(model.displayedPeak, 900); XCTAssertTrue(model.displayedPeakIsUpperBound)
    }
    func testReadFailureFallbackPreservesEveryCoverageFieldAfterCommit() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let repository = FaultyRepository(store)
        let model = model(inputs, repository: repository, probe: ProbeSequence([.failed, .failed]))
        await model.start().value
        await repository.inject(reads: true)
        inputs.advance(1, received: 100); model.sample(); await model.checkConnectivity()?.value
        inputs.advance(8, received: 800); model.sample(); await model.checkConnectivity()?.value
        inputs.advance(2, received: 200); model.sample()
        model.willSleep(); inputs.advance(60); model.didWake()
        inputs.setBroken(true); inputs.advance(1); model.sample()
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        let actual = try await store.today(at: inputs.now(), calendar: .current), visible = model.today
        XCTAssertEqual(visible.received, actual.received); XCTAssertEqual(visible.sent, actual.sent)
        XCTAssertEqual(visible.observed, actual.observed); XCTAssertEqual(visible.sleep, actual.sleep)
        XCTAssertEqual(visible.unobserved, actual.unobserved); XCTAssertEqual(visible.appGap, actual.appGap)
        XCTAssertEqual(visible.offline, actual.offline); XCTAssertEqual(visible.uncertain, actual.uncertain)
        XCTAssertEqual(visible.peakDown, actual.peakDown); XCTAssertEqual(visible.peakUp, actual.peakUp)
        XCTAssertGreaterThan(visible.observed, 0); XCTAssertEqual(visible.sleep, 60)
        XCTAssertGreaterThanOrEqual(visible.unobserved, 1); XCTAssertGreaterThan(visible.uncertain, 0)
    }
    func testOutageSleepAndWakeDoNotCreateOvernightDowntimeOrTrafficSpike() async throws {
        let inputs = TestInputs(), sequence = ProbeSequence([.failed, .failed, .success])
        let model = model(inputs, probe: sequence)
        await model.start().value
        inputs.advance(1, received: 100); await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .uncertain)
        inputs.advance(8, received: 800); await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .offline)
        for _ in 0..<30 { inputs.advance(1, received: 10); model.sample() }
        model.willSleep(); XCTAssertEqual(model.health, .sleeping)
        let sleepSaved = await model.flushAndWait(); XCTAssertTrue(sleepSaved)
        inputs.advance(3600, received: 1_000_000_000)
        model.didWake(); XCTAssertEqual(model.health, .checking)
        inputs.advance(1, received: 10); model.sample()
        XCTAssertEqual(model.down, 10, accuracy: 0.001)
        inputs.advance(5); await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .online)
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite")), rows = try await store.rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.offline }, 30, accuracy: 0.001)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.sleep }, 3600, accuracy: 0.001)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 1210)
        let events = try await store.events()
        XCTAssertTrue(events.contains { $0.kind == "sleep" }); XCTAssertTrue(events.contains { $0.kind == "wake" })
    }
    func testUncertainResponsesAndPausedChecksNeverClaimOnline() async throws {
        let inputs = TestInputs(), sequence = ProbeSequence([.unexpected, .unexpected, .success])
        let model = model(inputs, probe: sequence)
        await model.start().value
        inputs.advance(5); await model.checkConnectivity()?.value
        inputs.advance(8); await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .uncertain)
        model.setProbes(false); XCTAssertEqual(model.health, .disabled)
        for _ in 0..<10 { inputs.advance(1, received: 10); model.sample() }
        XCTAssertNil(model.checkConnectivity()); XCTAssertEqual(model.today.received, 100)
        model.setProbes(true)
        inputs.advance(5); await model.checkConnectivity()?.value
        XCTAssertEqual(model.health, .online)
    }
    func testCounterReadFailureAndRecoveryPreserveExplicitGap() async throws {
        let inputs = TestInputs(), model = model(inputs)
        await model.start().value
        inputs.advance(1, received: 100); model.sample()
        inputs.setBroken(true); inputs.advance(2, received: 900); model.sample()
        XCTAssertFalse(model.rateAvailable)
        inputs.setBroken(false); inputs.advance(1, received: 100); model.sample()
        inputs.advance(1, received: 50); model.sample()
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        XCTAssertEqual(model.today.received, 150)
        XCTAssertEqual(model.today.unobserved, 3, accuracy: 0.001)
    }
    func testRelaunchAppGapIsSeparateFromMissingReadings() async throws {
        let inputs = TestInputs(), first = model(inputs)
        await first.start().value
        inputs.advance(1, received: 100); first.sample()
        let saved = await first.flushAndWait(); XCTAssertTrue(saved)
        inputs.advance(60, received: 9999)
        let second = model(inputs)
        await second.start().value
        XCTAssertEqual(second.today.received, 100)
        XCTAssertEqual(second.today.appGap, 60, accuracy: 0.001)
        XCTAssertEqual(second.today.unobserved, 0, accuracy: 0.001)
        inputs.setBroken(true); inputs.advance(1); second.sample()
        let secondSaved = await second.flushAndWait(); XCTAssertTrue(secondSaved)
        XCTAssertEqual(second.today.appGap, 60, accuracy: 0.001)
        XCTAssertEqual(second.today.unobserved, 1, accuracy: 0.001)
    }
    func testModelExportBackupAndRestorePreserveAllData() async throws {
        let inputs = TestInputs(), model = model(inputs)
        await model.start().value
        inputs.advance(2, received: 1234, sent: 5678); model.sample()
        let backup = directory.appendingPathComponent("backup.sqlite")
        try await model.export(to: backup, backup: true)
        let restored = try HistoryStore(url: backup), rows = try await restored.rows(), events = try await restored.events()
        XCTAssertEqual(rows.first?.summary.received, 1234); XCTAssertEqual(rows.first?.summary.sent, 5678)
        XCTAssertEqual(events.first?.kind, "launch")
        let csv = directory.appendingPathComponent("export.csv")
        try await model.export(to: csv, backup: false)
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains(",1234,5678,"))
        await model.loadHistory(days: 30)
        XCTAssertEqual(model.historyRows.first?.summary.received, 1234)
    }
    func testQuitIsNeverRefusedWhenHistoryNeverOpened() async {
        let model = model(TestInputs())
        let quit = await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume(returning: $0) } }
        XCTAssertTrue(quit)
    }
    func testBackwardWallClockChangeDoesNotStallConnectivityChecks() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let model = model(inputs, repository: store)
        await model.start().value
        await model.checkConnectivity()?.value
        inputs.setWallClock(by: -3600); inputs.advance(6)
        let next = model.checkConnectivity()
        XCTAssertNotNil(next)
        await next?.value
    }
    func testUnmeasuredNoteIgnoresSleepAndShortGaps() {
        XCTAssertNil(Format.unmeasuredNote(appGap: 30, unobserved: 20))
        XCTAssertEqual(Format.unmeasuredNote(appGap: 720, unobserved: 60), "13m not measured · Current wasn't running")
        XCTAssertEqual(Format.unmeasuredNote(appGap: 0, unobserved: 300), "5m not measured · no readings")
    }
    func testSpeedTestAsksOnHotspotThenSavesResultAndHistoryEvent() async throws {
        let inputs = TestInputs(), store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let result = SpeedTestResult(start: inputs.now(), end: inputs.now().addingTimeInterval(9), download: 300e6, upload: 40e6,
                                     responsiveness: 900, bytesUsed: 420_000_000)
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), repository: store, automatic: false,
            preferences: preferences, counters: { try inputs.counters() }, uptime: { inputs.clock() }, now: { inputs.now() },
            speedTest: { result })
        await model.start().value
        model.meteredInterface = "en0"
        model.requestSpeedTest()
        XCTAssertEqual(model.speedTestPhase, .confirmMetered); XCTAssertTrue(model.speedTestDataNote.hasPrefix("It can use several hundred MB"))
        model.cancelSpeedTest(); XCTAssertEqual(model.speedTestPhase, .idle)
        model.requestSpeedTest(); model.requestSpeedTest()
        guard case .running = model.speedTestPhase else { return XCTFail("confirmed test should run") }
        while model.speedTestPhase != .idle { await Task.yield() }
        XCTAssertEqual(model.lastSpeedTest, result); XCTAssertEqual(model.graphMarkers.first?.date, result.start)
        XCTAssertTrue(model.speedTestDataNote.hasPrefix("Your last test used 420 MB"))
        let saved = await model.flushAndWait(); XCTAssertTrue(saved)
        let events = try await store.events(limit: 10)
        XCTAssertTrue(events.contains { $0.kind == "speed_test" && $0.detail.contains("300 Mbps down") && $0.detail.contains("Snappy") })
        let relaunched = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false, preferences: preferences)
        XCTAssertEqual(relaunched.lastSpeedTest, result)
    }
    func testFailedSpeedTestReportsWithoutChangingTheLastResult() async {
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false, preferences: preferences,
            speedTest: { throw HistoryError("The speed test didn't finish.") })
        model.requestSpeedTest()
        while case .running = model.speedTestPhase { await Task.yield() }
        XCTAssertEqual(model.speedTestPhase, .failed("The speed test didn't finish.")); XCTAssertNil(model.lastSpeedTest)
    }
    func testSleepStopsARunningSpeedTestAndDiscardsItsResult() async {
        let gate = SpeedTestGate()
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false, preferences: preferences,
            speedTest: { try await gate.wait() })
        model.requestSpeedTest()
        guard case .running = model.speedTestPhase else { return XCTFail("test should start") }
        model.willSleep()
        XCTAssertEqual(model.speedTestPhase, .idle)
        await gate.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.speedTestPhase, .idle); XCTAssertNil(model.lastSpeedTest)
        let cancelled = await gate.sawCancellation; XCTAssertTrue(cancelled)
    }
    func testUnknownConnectionTypeAsksBeforeTesting() {
        let model = MonitorModel(dataURL: directory.appendingPathComponent("history.sqlite"), automatic: false, preferences: preferences,
            speedTest: { SpeedTestResult(start: Date(), end: Date(), download: 1, upload: 1) })
        model.meteringKnown = false
        model.requestSpeedTest()
        XCTAssertEqual(model.speedTestPhase, .confirmMetered)
    }
    func testLoginItemIsOfferedOnlyOnAFirstInstallAndNeverSwitchedOnAlone() {
        XCTAssertTrue(MonitorModel.shouldOfferLoginItem(firstInstall: true, status: .disabled))
        for status in [LoginItemStatus.enabled, .needsApproval, .unavailable] {
            XCTAssertFalse(MonitorModel.shouldOfferLoginItem(firstInstall: true, status: status))
        }
        XCTAssertFalse(MonitorModel.shouldOfferLoginItem(firstInstall: false, status: .disabled))
        let fresh = FakeLoginItem(), model = MonitorModel(dataURL: directory.appendingPathComponent("never-created.sqlite"),
            automatic: false, preferences: preferences, loginItem: fresh)
        model.evaluateLoginItemOffer()
        XCTAssertTrue(model.showLoginItemOffer); XCTAssertEqual(fresh.calls, [])
        model.answerLoginItemOffer(enable: false)
        XCTAssertFalse(model.showLoginItemOffer); XCTAssertEqual(fresh.calls, []); XCTAssertEqual(model.loginItemStatus, .disabled)
        let again = MonitorModel(dataURL: directory.appendingPathComponent("never-created.sqlite"), automatic: false,
            preferences: preferences, loginItem: FakeLoginItem())
        again.evaluateLoginItemOffer(); XCTAssertFalse(again.showLoginItemOffer, "a declined offer is not repeated")
    }
    func testAcceptingTheOfferRegistersAndFailuresAreReported() {
        let item = FakeLoginItem(), model = MonitorModel(dataURL: directory.appendingPathComponent("never-created.sqlite"),
            automatic: false, preferences: preferences, loginItem: item)
        model.evaluateLoginItemOffer(); model.answerLoginItemOffer(enable: true)
        XCTAssertEqual(item.calls, [true]); XCTAssertEqual(model.loginItemStatus, .enabled); XCTAssertNil(model.errorMessage)
        item.fails = true; model.setOpenAtLogin(false)
        XCTAssertEqual(model.loginItemStatus, .enabled); XCTAssertTrue(model.errorMessage?.contains("Open at login") == true)
    }
    func testUpgradesWithHistoryAreNotAskedAndRemembered() throws {
        let url = directory.appendingPathComponent("history.sqlite")
        _ = try HistoryStore(url: url)
        let model = MonitorModel(dataURL: url, automatic: false, preferences: preferences, loginItem: FakeLoginItem())
        model.evaluateLoginItemOffer()
        XCTAssertFalse(model.showLoginItemOffer); XCTAssertTrue(preferences.bool(forKey: MonitorModel.loginItemOfferKey))
    }
}
@MainActor private final class FakeLoginItem: LoginItemControl {
    var status = LoginItemStatus.disabled
    var calls: [Bool] = []
    var fails = false
    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if fails { throw HistoryError("The operation couldn't be completed.") }
        status = enabled ? .enabled : .disabled
    }
    func openSystemSettings() {}
}
private actor SpeedTestGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var sawCancellation = false
    func wait() async throws -> SpeedTestResult {
        await withCheckedContinuation { waiter = $0 }
        sawCancellation = Task.isCancelled
        return SpeedTestResult(start: Date(), end: Date(), download: 1e8, upload: 1e7)
    }
    func finish() async {
        while waiter == nil { await Task.yield() }
        waiter?.resume(); waiter = nil
    }
}
