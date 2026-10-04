import Foundation
import Darwin
import CNetwork

public struct InterfaceCounter: Sendable, Equatable {
    public var name: String
    public var index: UInt32
    public var received: UInt64
    public var sent: UInt64
    public var active: Bool
    public var ethernet: Bool
    public init(name: String, index: UInt32 = 1, received: UInt64, sent: UInt64, active: Bool = true, ethernet: Bool = true) {
        self.name = name; self.index = index; self.received = received; self.sent = sent
        self.active = active; self.ethernet = ethernet
    }
    public var included: Bool {
        active && ethernet && name.hasPrefix("en") && !name.dropFirst(2).isEmpty && name.dropFirst(2).allSatisfy(\.isNumber)
    }
}

public enum CounterReader {
    public static func read() throws -> [InterfaceCounter] {
        try read(snapshot: { buffer in
            let capacity = Int32(buffer.count)
            return traffic_interfaces(&buffer, capacity)
        })
    }
    static func read(snapshot: (inout [TrafficInterface]) -> Int32) throws -> [InterfaceCounter] {
        var raw = [TrafficInterface](repeating: TrafficInterface(), count: 128)
        var count = snapshot(&raw)
        // Retry a larger snapshot rather than dropping physical accounting
        // because many virtual interfaces filled the initial small buffer.
        for _ in 0..<3 where count > raw.count {
            guard count <= 4096 else { throw MeasurementError.unavailable(code: -1) }
            raw = [TrafficInterface](repeating: TrafficInterface(), count: Int(count))
            count = snapshot(&raw)
        }
        guard count >= 0, count <= raw.count else { throw MeasurementError.unavailable(code: count) }
        return raw.prefix(Int(count)).map { item in
            var name = item.name
            let text = withUnsafePointer(to: &name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            return InterfaceCounter(name: text, index: item.index, received: item.received, sent: item.sent,
                active: item.flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING), ethernet: item.type == 6)
        }
    }
}
public enum MeasurementError: Error { case unavailable(code: Int32) }
public enum Coverage: String, Codable, Sendable { case observed, partial, sleep, unobserved, appGap }

public struct Observation: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var received: UInt64
    public var sent: UInt64
    public var peakDown: Double
    public var peakUp: Double
    public var coverage: Coverage
    public var offlineSeconds: Double
    public var uncertainSeconds: Double
    public var duration: Double { max(0, end.timeIntervalSince(start)) }
    public init(start: Date, end: Date, received: UInt64 = 0, sent: UInt64 = 0,
                peakDown: Double = 0, peakUp: Double = 0, coverage: Coverage = .observed,
                offlineSeconds: Double = 0, uncertainSeconds: Double = 0) {
        self.start = start; self.end = end; self.received = received; self.sent = sent
        self.peakDown = peakDown; self.peakUp = peakUp; self.coverage = coverage
        self.offlineSeconds = offlineSeconds; self.uncertainSeconds = uncertainSeconds
    }
}

public struct CounterEngine: Sendable {
    private var baseline: [String: InterfaceCounter] = [:]
    private var lastDate: Date?
    private var lastUptime: Double?
    public private(set) var interfaces: [String] = []
    public init() {}
    public mutating func rebaseline(_ counters: [InterfaceCounter], at date: Date, uptime: Double) {
        let selected = counters.filter(\.included)
        baseline = Dictionary(uniqueKeysWithValues: selected.map { ($0.name, $0) })
        interfaces = selected.map(\.name).sorted(); lastDate = date; lastUptime = uptime
    }
    public mutating func sample(_ counters: [InterfaceCounter], at date: Date, uptime: Double) -> Observation? {
        guard let previousDate = lastDate, let previousUptime = lastUptime else {
            rebaseline(counters, at: date, uptime: uptime); return nil
        }
        let elapsed = uptime - previousUptime
        let wallElapsed = date.timeIntervalSince(previousDate)
        defer { rebaseline(counters, at: date, uptime: uptime) }
        // Delayed timers and wall-clock changes must not become huge rates or pretend to be zero.
        guard elapsed > 0, elapsed <= 15, wallElapsed > 0, abs(wallElapsed - elapsed) < 2 else {
            return Observation(start: min(previousDate, date), end: date, coverage: .unobserved)
        }
        var received: UInt64 = 0, sent: UInt64 = 0
        var complete = true
        let selected = counters.filter(\.included)
        if Set(selected.map(\.name)) != Set(baseline.keys) { complete = false }
        for counter in selected {
            guard let old = baseline[counter.name], old.index == counter.index,
                  counter.received >= old.received, counter.sent >= old.sent else {
                complete = false; continue
            }
            received += counter.received - old.received
            sent += counter.sent - old.sent
        }
        return Observation(start: previousDate, end: date, received: received, sent: sent,
            peakDown: Double(received) / elapsed, peakUp: Double(sent) / elapsed,
            coverage: complete ? .observed : .partial)
    }
}
