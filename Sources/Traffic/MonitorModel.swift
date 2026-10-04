import AppKit
import SwiftUI
import Network
import UserNotifications
import TrafficCore

@MainActor
final class MonitorModel: ObservableObject {
    @Published var down: Double = 0
    @Published var up: Double = 0
    @Published var rateAvailable = false
    @Published var health: ConnectionHealth = .checking
    @Published var lastChecked: Date?
    @Published private(set) var checkInProgress = false
    @Published private(set) var checkPending = false
    @Published var interfaces: [String] = []
    @Published var graph: [GraphPoint] = []
    @Published var today = HistorySummary()
    @Published var period = HistoryPeriod.hour
    @Published var periodHistory: PeriodHistory?
    @Published var periodChart: PeriodChart?
    @Published var periodLoading = false
    @Published var connectedDuration: Double?
    @Published var connectionDetails: [ConnectionDetail] = []
    @Published var connectionDetailsExpanded = false
    @Published var historyRows: [HistoryRow] = []
    @Published var recentEvents: [HistoryEvent] = []
    @Published var errorMessage: String?
    @Published var noticesEnabled = false
    @Published var probesEnabled = true
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var appearance = TrafficAppearanceSettings.defaults
    var onStatusChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var popoverOpen = false { didSet {
        scheduleSampler()
        if popoverOpen { Task { await refreshConnectionInventory(includeTailscale: true) } }
    } }
    var historyOpen = false
    var displayedChart: PeriodChart {
        if period == .hour {
            let end = graph.last?.end ?? nowProvider()
            return PeriodChart(start: end.addingTimeInterval(-3600), end: end, points: graph, resolution: 10)
        }
        return periodChart ?? PeriodChart(start: period.start(before: nowProvider()) ?? nowProvider().addingTimeInterval(-3600), end: nowProvider())
    }
    var displayedPeak: Double {
        if period == .hour { return displayedChart.peak }
        return max(periodHistory?.summary.peakDown ?? 0, periodHistory?.summary.peakUp ?? 0)
    }
    var displayedPeakIsUpperBound: Bool { period != .hour && periodHistory?.peakIsUpperBound == true }
    private var engine = CounterEngine()
    private var detailEngine = InterfaceRateEngine()
    private var connectionInventory = ConnectionInventory()
    private var lastCounters: [InterfaceCounter] = []
    private var lastRates: [InterfaceRate] = []
    private var lastInventory = Date.distantPast
    private var inventoryLoading = false
    private var inventoryNeedsTailscale = false
    private var inventoryHadTailscale = false
    private var pathSignature: String?
    private let inventoryProvider: @Sendable (Bool) async -> ConnectionInventory
    private var machine = HealthMachine()
    private var connectionStreak = ConnectionStreak()
    private var liveGraph = LiveGraph()
    private var historicalGraph: [GraphPoint] = []
    private var periodGeneration = 0
    private var store: (any HistoryRepository)?
    private var persistence = PersistenceBuffer()
    private var persistedToday = HistorySummary()
    private var persistedDay = Calendar.current.startOfDay(for: Date())
    private var sampler: Timer?
    private var probeTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied = true
    private var isSleeping = false
    private var sleepStart: Date?
    private var probing = false
    private var probeTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var lastProbeStarted = Date.distantPast
    private var lastFlush = Date()
    private var finishingFlush = false
    private var started = false
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var historyDays = 30
    private var healthSince = Date()
    private var lastAccounted = Date()
    private var terminationRequested = false
    let dataURL: URL
    private let preferences: UserDefaults
    private let automatic: Bool
    private let counterProvider: @Sendable () throws -> [InterfaceCounter]
    private let uptimeProvider: @Sendable () -> Double
    private let nowProvider: @Sendable () -> Date
    private let probeProvider: @Sendable () async -> ProbeOutcome
    private var checkFreshness: Double { (lowPower ? 120 : 30) + 10 }

    init(dataURL: URL? = nil, repository: (any HistoryRepository)? = nil, automatic: Bool = true, preferences: UserDefaults = .standard,
         counters: @escaping @Sendable () throws -> [InterfaceCounter] = { try CounterReader.read() },
         uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         now: @escaping @Sendable () -> Date = { Date() },
         probe: @escaping @Sendable () async -> ProbeOutcome = { await ConnectivityProbe.check() },
         inventory: @escaping @Sendable (Bool) async -> ConnectionInventory = { await NetworkInventory.read(includeTailscale: $0) }) {
        self.preferences = preferences
        appearance = TrafficAppearanceSettings(preferences: preferences)
        noticesEnabled = preferences.bool(forKey: "outageNotifications")
        probesEnabled = !preferences.bool(forKey: "probesDisabled")
        self.automatic = automatic; counterProvider = counters; uptimeProvider = uptime
        nowProvider = now; probeProvider = probe; inventoryProvider = inventory; store = repository
        lastAccounted = now(); lastFlush = now(); healthSince = now()
        persistedDay = Calendar.current.startOfDay(for: now())
        if let dataURL { self.dataURL = dataURL; return }

        if let custom = ProcessInfo.processInfo.environment["TRAFFIC_DATA_DIR"] {
            self.dataURL = URL(fileURLWithPath: custom).appendingPathComponent("traffic.sqlite")
        } else {
            self.dataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Traffic", isDirectory: true).appendingPathComponent("traffic.sqlite")
        }
    }
    @discardableResult
    func start() -> Task<Void, Never> {
        Task {
            do {
                let store: any HistoryRepository
                if let existing = self.store { store = existing }
                else { store = try HistoryStore(url: dataURL) }
                self.store = store
                let now = nowProvider()
                let previous = try await store.lastRecorded()
                if let previous, previous < now {
                    try await store.record([Observation(start: previous, end: now, coverage: .appGap)], now: now,
                        events: [(now, "launch", "App started. Gap since the last saved observation: \(Int(now.timeIntervalSince(previous))) seconds. A crash gap can include the last unsaved minute.")])
                } else { try await store.record([], now: now, events: [(now, "launch", "App started")]) }
                persistedToday = try await store.today(at: nowProvider(), calendar: .current)
                persistedDay = Calendar.current.startOfDay(for: nowProvider())
                historicalGraph = try await store.recentGraph(ending: now)
                graph = historicalGraph
                rebuildToday()
            } catch { errorMessage = "History unavailable: \(error)" }
            beginMonitoring()
        }
    }
    private func beginMonitoring() {
        guard !terminationRequested else { return }
        started = true
        let now = nowProvider(); lastAccounted = now
        if let counters = try? counterProvider() {
            engine.rebaseline(counters, at: now, uptime: uptimeProvider())
            detailEngine.rebaseline(counters, at: now, uptime: uptimeProvider()); lastCounters = counters
        }
        scheduleSampler()
        if automatic { Task { await refreshConnectionInventory(includeTailscale: false) } }
        guard automatic else {
            if !probesEnabled { machine.reset(to: .disabled); health = .disabled }
            return
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = String(describing: path.status) + path.availableInterfaces.map { "\($0.name)#\($0.index)" }.sorted().joined(separator: "|")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pathSignature != nil && self.pathSignature != signature { self.invalidateConnectionInterval() }
                self.pathSignature = signature
                self.pathSatisfied = satisfied
                if self.popoverOpen { Task { await self.refreshConnectionInventory(includeTailscale: true, force: true) } }
                self.checkConnectivity()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Traffic.path", qos: .utility))
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.scheduleSampler(); self.scheduleProbe(after: self.lowPower ? 60 : 30)
            }
        })
        if !probesEnabled { machine.reset(to: .disabled); health = .disabled }
        checkConnectivity()
    }
    private func scheduleSampler() {
        sampler?.invalidate(); sampler = nil
        guard started, automatic, !isSleeping else { return }
        let interval: Double = lowPower && !popoverOpen ? 5 : 1
        sampler = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sampler?.tolerance = interval * 0.2
        RunLoop.main.add(sampler!, forMode: .common)
    }
    func sample() {
        guard !isSleeping else { return }
        let date = nowProvider()
        // A probe can close a sample at the same timestamp as the timer.
        // Duplicate instants add no data and must not break a valid interval.
        guard date != lastAccounted else { return }
        var observed = false
        do {
            let counters = try counterProvider()
            lastCounters = counters
            lastRates = detailEngine.sample(counters, at: date, uptime: uptimeProvider())
            if popoverOpen { rebuildConnectionDetails() }
            if var observation = engine.sample(counters, at: date, uptime: uptimeProvider()) {
                let healthDuration = max(0, observation.end.timeIntervalSince(max(observation.start, healthSince)))
                if health == .offline { observation.offlineSeconds = min(observation.duration, healthDuration) }
                if health == .uncertain || health == .checking || health == .disabled { observation.uncertainSeconds = min(observation.duration, healthDuration) }
                append(observation)
                down = observation.peakDown; up = observation.peakUp
                rateAvailable = observation.coverage == .observed || (observation.coverage == .partial && (observation.received > 0 || observation.sent > 0))
                observed = observation.coverage == .observed
                lastAccounted = date
            } else if date > lastAccounted {
                append(Observation(start: lastAccounted, end: date, coverage: .unobserved))
                lastAccounted = date
            }
            interfaces = engine.interfaces
        } catch {
            append(Observation(start: lastAccounted, end: date, coverage: .unobserved))
            lastAccounted = date; down = 0; up = 0; rateAvailable = false
            engine = CounterEngine(); detailEngine = InterfaceRateEngine(); lastRates = []
            if popoverOpen { rebuildConnectionDetails() }
        }
        connectionStreak.advance(uptime: uptimeProvider(), observed: observed && health == .online, freshness: checkFreshness)
        connectedDuration = connectionStreak.duration
        if date.timeIntervalSince(lastFlush) >= 60 { flush() }
        onStatusChange?()
    }
    private func append(_ observation: Observation) {
        guard observation.duration > 0 else { return }
        persistence.append(observation)
        liveGraph.append(observation)
        if let first = liveGraph.points.first {
            historicalGraph = historicalGraph.compactMap { point in
                guard point.start < first.start else { return nil }
                var point = point; point.end = min(point.end, first.start)
                return point.end > observation.end.addingTimeInterval(-LiveGraph.span) ? point : nil
            }
        }
        graph = LiveGraph.window(historicalGraph + liveGraph.points, ending: observation.end)
        if persistence.pending.count >= 3600 {
            errorMessage = "History writes failed for over an hour. Older unsaved readings were marked unobserved."
        }
        rebuildToday()
    }
    private func rebuildToday() {
        let start = Calendar.current.startOfDay(for: nowProvider())
        if start != persistedDay { persistedToday = HistorySummary(); persistedDay = start }
        var total = persistedToday
        for observation in persistence.unsaved where observation.end > start && observation.duration > 0 {
            accumulate(observation, into: &total, day: start)
        }
        today = total
    }
    private func accumulate(_ observation: Observation, into total: inout HistorySummary, day: Date) {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let seconds = max(0, min(end, observation.end).timeIntervalSince(max(day, observation.start)))
        let fraction = min(1, seconds / observation.duration)
        total.received += fraction == 1 ? observation.received : UInt64(Double(observation.received) * fraction)
        total.sent += fraction == 1 ? observation.sent : UInt64(Double(observation.sent) * fraction)
        total.peakDown = max(total.peakDown, observation.peakDown); total.peakUp = max(total.peakUp, observation.peakUp)
        total.observed += observation.coverage == .observed ? seconds : 0
        total.sleep += observation.coverage == .sleep ? seconds : 0
        total.unobserved += [.partial, .unobserved].contains(observation.coverage) ? seconds : 0
        total.appGap += observation.coverage == .appGap ? seconds : 0
        total.offline += observation.offlineSeconds * fraction
        total.uncertain += observation.uncertainSeconds * fraction
    }
    func flush(completion: ((Bool) -> Void)? = nil) {
        guard let store else { completion?(false); return }
        guard !finishingFlush, let batch = persistence.begin() else {
            if let completion {
                Task { try? await Task.sleep(for: .milliseconds(100)); self.flush(completion: completion) }
            }
            return
        }
        finishingFlush = true
        lastFlush = nowProvider()
        // Earlier accumulated evidence is retired; unknown app-off time can
        // never extend a continuous interval. Existing byte/event history stays.
        let connectivity = ConnectivityUpdate.replace(nil)
        Task {
            do {
                try await store.record(batch.observations, now: nowProvider(), events: batch.events, connectivity: connectivity)
            } catch {
                persistence.failed()
                errorMessage = "History write failed: \(error)"
                finishingFlush = false; rebuildToday(); completion?(false); return
            }
            // The transaction committed. A later read failure cannot put this batch back in the queue.
            persistence.committed()
            // Keep visible totals correct even if the refresh query fails.
            let savedPending = batch.observations
            var fallbackTotal = persistedToday
            let start = Calendar.current.startOfDay(for: nowProvider())
            if start != persistedDay { fallbackTotal = HistorySummary() }
            for observation in savedPending where observation.end > start && observation.duration > 0 {
                accumulate(observation, into: &fallbackTotal, day: start)
            }
            persistedToday = fallbackTotal; persistedDay = start
            do {
                persistedToday = try await store.today(at: nowProvider(), calendar: .current)
                errorMessage = nil
                if historyOpen { await loadHistory(days: historyDays) }
                if popoverOpen { await loadPeriod(); await refreshConnectionInventory(includeTailscale: true) }
            } catch { errorMessage = "History saved, but totals refresh failed: \(error)" }
            finishingFlush = false; rebuildToday(); completion?(true)
        }
    }
    private func scheduleProbe(after interval: Double) {
        probeTimer?.invalidate(); probeTimer = nil
        guard automatic, probesEnabled, !isSleeping else { return }
        probeTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.checkConnectivity() }
        }
        probeTimer?.tolerance = min(5, interval * 0.1)
        RunLoop.main.add(probeTimer!, forMode: .common)
    }
    @discardableResult
    func checkConnectivity() -> Task<Void, Never>? {
        guard probesEnabled, !isSleeping else { return nil }
        if probing { return probeTask }
        let elapsed = nowProvider().timeIntervalSince(lastProbeStarted)
        guard elapsed >= 5 else { scheduleProbe(after: 5 - elapsed); return nil }
        probing = true; checkInProgress = true; checkPending = false; lastProbeStarted = nowProvider()
        let generation = probeGeneration
        let hasPath = pathSatisfied
        let task = Task {
            let outcome: ProbeOutcome = hasPath ? await probeProvider() : .failed
            guard generation == probeGeneration else { return }
            probing = false; checkInProgress = false
            let date = nowProvider()
            // Close the current sample before a health transition to preserve elapsed state.
            sample()
            var flushTransition = false
            if let transition = machine.receive(outcome, at: date) {
                healthSince = date
                flushTransition = transition.to == .uncertain || transition.from == .uncertain
                persistence.event(at: date, kind: transition.to.rawValue, detail: transition.to.label)
                if transition.to == .offline && transition.newOutage {
                    notify(title: "Internet connection lost", body: "Two checks failed. Current will keep checking.")
                    flushTransition = true
                } else if transition.outageStart != nil && transition.to == .online {
                    let duration = transition.outageStart.map { date.timeIntervalSince($0) } ?? 0
                    persistence.event(at: date, kind: "recovery", detail: "Reachability recovered \(Int(duration)) seconds after outage confirmation. Intervening uncertain checks may be included.")
                    notify(title: "Internet connection restored", body: "Connection returned after \(Format.duration(duration)).")
                    flushTransition = true
                }
            }
            health = machine.state; lastChecked = machine.lastChecked
            connectionStreak.receive(outcome, uptime: uptimeProvider(), freshness: checkFreshness)
            connectedDuration = connectionStreak.duration
            if flushTransition { flush(completion: { _ in }) }
            onStatusChange?()
            let interval: Double = health == .uncertain ? 8 : (health == .offline ? (lowPower ? 60 : 30) : (lowPower ? 120 : 30))
            scheduleProbe(after: interval)
        }
        probeTask = task
        return task
    }
    func refreshConnectivity() {
        guard probesEnabled, !isSleeping else { return }
        checkPending = !probing
        _ = checkConnectivity()
    }
    func setAppearance(_ value: TrafficAppearanceSettings) {
        guard value != appearance else { return }
        // Publish new color values before SwiftUI observes the preference.
        // Native window appearance still changes after the control action.
        TrafficPalette.apply(value)
        appearance = value; value.save(to: preferences); onAppearanceChange?()
    }
    func setProbes(_ enabled: Bool) {
        sample()
        probesEnabled = enabled; preferences.set(!enabled, forKey: "probesDisabled")
        probeGeneration += 1; probeTask?.cancel(); probeTask = nil; probing = false; probeTimer?.invalidate()
        checkInProgress = false; checkPending = false
        machine.reset(to: enabled ? .checking : .disabled); health = machine.state; lastChecked = nil; healthSince = nowProvider()
        invalidateConnectionInterval()
        persistence.event(at: nowProvider(), kind: enabled ? "checks_resumed" : "checks_paused", detail: enabled ? "Internet checks resumed" : "Internet checks paused")
        onStatusChange?()
        if enabled { checkConnectivity() }
    }
    func setNotifications(_ enabled: Bool) {
        guard enabled else {
            noticesEnabled = false; preferences.set(false, forKey: "outageNotifications"); return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.noticesEnabled = granted
                self?.preferences.set(granted, forKey: "outageNotifications")
                if !granted { self?.errorMessage = error?.localizedDescription ?? "Notifications are disabled in System Settings." }
            }
        }
    }
    private func notify(title: String, body: String) {
        guard noticesEnabled else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func willSleep() {
        sample(); isSleeping = true; sleepStart = nowProvider()
        persistence.event(at: nowProvider(), kind: "sleep", detail: "Mac sleeping. Counter sampling and probes paused.")
        sampler?.invalidate(); probeTimer?.invalidate(); probeGeneration += 1; probeTask?.cancel(); probeTask = nil; probing = false
        checkInProgress = false; checkPending = false
        machine.reset(to: .sleeping); health = .sleeping; rateAvailable = false; down = 0; up = 0
        invalidateConnectionInterval()
        flush(); onStatusChange?()
    }
    func didWake() {
        let now = nowProvider()
        if let start = sleepStart { append(Observation(start: start, end: now, coverage: .sleep)) }
        sleepStart = nil; isSleeping = false; lastAccounted = now
        if let counters = try? counterProvider() { engine.rebaseline(counters, at: now, uptime: uptimeProvider()) }
        else { engine = CounterEngine() }
        detailEngine = InterfaceRateEngine(); lastRates = []; rebuildConnectionDetails()
        probeGeneration += 1; probeTask?.cancel(); probeTask = nil; probing = false
        machine.reset(to: probesEnabled ? .checking : .disabled); health = machine.state; lastChecked = nil; healthSince = now
        invalidateConnectionInterval()
        persistence.event(at: now, kind: "wake", detail: "Mac awake. Counters rebaselined; internet health checked again.")
        scheduleSampler(); scheduleProbe(after: 5); flush(); onStatusChange?()
    }
    func invalidateConnectionInterval() {
        connectionStreak.reset(); connectedDuration = nil
    }
    func refreshConnectionInventory(includeTailscale: Bool, force: Bool = false) async {
        guard !isSleeping else { return }
        if inventoryLoading {
            inventoryNeedsTailscale = inventoryNeedsTailscale || includeTailscale
            return
        }
        let now = nowProvider()
        guard (force && now.timeIntervalSince(lastInventory) >= 5) || (includeTailscale && !inventoryHadTailscale) || now.timeIntervalSince(lastInventory) >= 60 else { return }
        inventoryLoading = true
        let result = await inventoryProvider(includeTailscale)
        connectionInventory = result; lastInventory = now; inventoryHadTailscale = includeTailscale; inventoryLoading = false
        rebuildConnectionDetails()
        if inventoryNeedsTailscale {
            inventoryNeedsTailscale = false
            if !includeTailscale && popoverOpen { await refreshConnectionInventory(includeTailscale: true) }
        }
    }
    private func rebuildConnectionDetails() {
        connectionDetails = ConnectionDetail.make(counters: lastCounters, rates: lastRates, inventory: connectionInventory)
    }
    func loadHistory(days: Int = 30) async {
        historyDays = days
        guard let store else { return }
        do {
            historyRows = try await store.rows(grain: 86400, since: days == 0 ? .distantPast : nowProvider().addingTimeInterval(-Double(days) * 86400), limit: days == 0 ? 40000 : days + 1)
            recentEvents = try await store.events(limit: 100)
        } catch { errorMessage = "Cannot read history: \(error)" }
    }
    func selectPeriod(_ selection: HistoryPeriod) {
        guard selection != period else { return }
        period = selection; periodGeneration += 1; periodHistory = nil; periodChart = nil; periodLoading = true
        Task {
            let saved = await flushAndWait()
            guard selection == period else { return }
            if saved { if periodHistory == nil { await loadPeriod() } }
            else { periodLoading = false; errorMessage = "Period totals unavailable until recent history can be saved." }
        }
    }
    func loadPeriod() async {
        guard let store else { periodLoading = false; return }
        periodGeneration += 1
        let generation = periodGeneration, selection = period, end = nowProvider()
        periodLoading = true
        do {
            let result = try await store.aggregate(from: selection.start(before: end), to: end)
            guard generation == periodGeneration, selection == period else { return }
            let chart = selection == .hour ? displayedChart : try await store.chart(from: selection.start(before: end), to: end, limit: 360)
            guard generation == periodGeneration, selection == period else { return }
            periodHistory = result; periodChart = chart; periodLoading = false
        } catch {
            guard generation == periodGeneration else { return }
            periodHistory = nil; periodChart = nil; periodLoading = false; errorMessage = "Cannot load selected period: \(error)"
        }
    }
    func export(backup: Bool) {
        let panel = NSSavePanel()
        panel.title = backup ? "Back up Current history" : "Export Current history"
        panel.nameFieldStringValue = backup ? "Current-backup.sqlite" : "Current-history.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await export(to: destination, backup: backup)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { errorMessage = "Export failed: \(error)" }
        }
    }
    func flushAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            flush { saved in continuation.resume(returning: saved) }
        }
    }
    func export(to destination: URL, backup: Bool) async throws {
        guard await flushAndWait(), let store else { throw HistoryError("Current observations could not be saved. Export was cancelled.") }
        if backup { try await store.backup(to: destination) }
        else { try await store.exportCSV(to: destination) }
    }
    func prepareToQuit(_ completion: @escaping (Bool) -> Void) {
        guard !terminationRequested else { return }
        sample(); terminationRequested = true; sampler?.invalidate(); probeTimer?.invalidate()
        probeGeneration += 1; probeTask?.cancel(); probeTask = nil
        probing = false; checkInProgress = false; checkPending = false
        onStatusChange?()
        persistence.event(at: nowProvider(), kind: "quit", detail: "App quit. Future time is unobserved until the next launch.")
        flush { [weak self] saved in
            guard let self else { completion(false); return }
            if saved { self.pathMonitor.cancel() }
            else {
                self.persistence.removePendingEvents(kind: "quit")
                self.terminationRequested = false
                self.errorMessage = "Current is still running because history could not be saved. Retry quitting after resolving the storage error."
                self.scheduleSampler(); self.scheduleProbe(after: 0)
            }
            completion(saved)
        }
    }
}

extension ConnectionHealth {
    @MainActor var color: Color {
        switch self {
        case .online: Color(nsColor: TrafficPalette.reachable)
        case .offline: .red
        case .uncertain: .orange
        default: .secondary
        }
    }
    @MainActor var nsColor: NSColor {
        switch self {
        case .online: TrafficPalette.reachable
        case .offline: .systemRed
        case .uncertain: .systemOrange
        default: .secondaryLabelColor
        }
    }
}
enum Format {
    static func rateParts(_ rate: Double) -> (number: String, unit: String) {
        let parts = self.rate(rate).split(separator: " ", maxSplits: 1)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "B/s")
    }
    static func bytes(_ bytes: UInt64) -> String { scaled(Double(bytes), rate: false) }
    static func rate(_ rate: Double) -> String { scaled(rate, rate: true) }
    private static func scaled(_ value: Double, rate: Bool) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = max(0, value), index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        let number = value >= 100 || index == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(units[index])\(rate ? "/s" : "")"
    }
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(max(0, seconds)))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86400)
    }
    static func connectionDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let value = Int(max(0, min(seconds, Double(Int.max / 2))))
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(value % 60)s" }
        if value < 86400 { return "\(value / 3600)h \(value % 3600 / 60)m" }
        return "\(value / 86400)d \(value % 86400 / 3600)h"
    }
}
