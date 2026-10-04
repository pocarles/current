import Foundation

public typealias RecordedEvent = (Date, String, String)
public protocol HistoryRepository: Sendable {
    func lastRecorded() async throws -> Date?
    func record(_ observations: [Observation], now: Date, events: [RecordedEvent], connectivity: ConnectivityUpdate) async throws
    func onlineEvidence() async throws -> OnlineEvidence?
    func recentGraph(ending end: Date) async throws -> [GraphPoint]
    func today(at date: Date, calendar: Calendar) async throws -> HistorySummary
    func aggregate(from start: Date?, to end: Date) async throws -> PeriodHistory
    func chart(from start: Date?, to end: Date, limit: Int) async throws -> PeriodChart
    func rows(grain: Int, since: Date, limit: Int) async throws -> [HistoryRow]
    func events(limit: Int) async throws -> [HistoryEvent]
    func backup(to destination: URL) async throws
    func exportCSV(to destination: URL) async throws
}

public extension HistoryRepository {
    func record(_ observations: [Observation], now: Date, events: [RecordedEvent]) async throws {
        try await record(observations, now: now, events: events, connectivity: .unchanged)
    }
}

// Separate the saved-write boundary from UI queries. A failed read must never retry a committed batch.
public struct PersistenceBuffer: Sendable {
    public private(set) var pending: [Observation] = []
    public private(set) var inFlight: [Observation] = []
    public private(set) var events: [RecordedEvent] = []
    private var inFlightEvents: [RecordedEvent] = []
    public private(set) var writing = false
    public var unsaved: [Observation] { pending + inFlight }
    public init() {}
    public mutating func append(_ observation: Observation) {
        pending.append(observation)
        if pending.count > 3600 {
            let count = pending.count - 3599
            let removed = pending.prefix(count)
            let gap = Observation(start: removed.first!.start, end: removed.last!.end, coverage: .unobserved)
            pending.removeFirst(count); pending.insert(gap, at: 0)
        }
    }
    public mutating func event(at date: Date, kind: String, detail: String) {
        events.append((date, kind, detail))
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
    }
    /// Remove a cancelled action from the pending queue only. Saved events and
    /// observations are unaffected. Call after a failed batch is restored.
    public mutating func removePendingEvents(kind: String) {
        events.removeAll { $0.1 == kind }
    }
    public mutating func begin() -> (observations: [Observation], events: [RecordedEvent])? {
        guard !writing else { return nil }
        writing = true; inFlight = pending; pending = []
        inFlightEvents = events; events = []
        return (inFlight, inFlightEvents)
    }
    public mutating func committed() {
        inFlight = []; inFlightEvents = []; writing = false
    }
    public mutating func failed() {
        pending = inFlight + pending; events = inFlightEvents + events
        inFlight = []; inFlightEvents = []; writing = false
    }
}
