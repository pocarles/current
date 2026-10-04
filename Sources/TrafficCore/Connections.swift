import Foundation

public enum InterfaceKind: String, CaseIterable, Sendable {
    case wifi, ethernet, tailscale, bluetoothPAN, vpn
    public var label: String {
        switch self { case .wifi: "Wi-Fi"; case .ethernet: "Ethernet"; case .tailscale: "Tailscale"; case .bluetoothPAN: "Bluetooth PAN"; case .vpn: "Other VPN" }
    }
    public var isOverlay: Bool { self == .tailscale || self == .vpn }
}

public struct ConnectionInventory: Sendable {
    public var physicalKinds: [String: InterfaceKind]
    public var tailscaleInterface: String?
    public var tailscaleIndex: UInt32?
    public var tailscaleInstalled: Bool
    public var tailscaleAvailable: Bool
    public init(physicalKinds: [String: InterfaceKind] = [:], tailscaleInterface: String? = nil,
                tailscaleInstalled: Bool = false, tailscaleAvailable: Bool = false, tailscaleIndex: UInt32? = nil) {
        self.physicalKinds = physicalKinds; self.tailscaleInterface = tailscaleInterface
        self.tailscaleIndex = tailscaleIndex; self.tailscaleInstalled = tailscaleInstalled; self.tailscaleAvailable = tailscaleAvailable
    }
    public func kind(of counter: InterfaceCounter) -> InterfaceKind? {
        if counter.name == tailscaleInterface, counter.index == tailscaleIndex, !counter.ethernet { return .tailscale }
        if counter.name.hasPrefix("utun") { return .vpn }
        guard counter.included || (counter.ethernet && physicalKinds[counter.name] != nil) else { return nil }
        return physicalKinds[counter.name] ?? .ethernet
    }
    /// An installed client's own addresses must all match one unique tunnel.
    /// A generic utun name, display name or address prefix never identifies it.
    public static func matchTailscale(selfAddresses: Set<String>, interfaceAddresses: [String: Set<String>]) -> String? {
        guard !selfAddresses.isEmpty else { return nil }
        let matches = interfaceAddresses.filter { $0.key.hasPrefix("utun") && selfAddresses.isSubset(of: $0.value) }.map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct InterfaceRate: Sendable, Equatable {
    public var name: String
    public var down: Double?
    public var up: Double?
}

/// Separate live detail readings. Tunnel deltas never enter CounterEngine's
/// physical total or its persisted history.
public struct InterfaceRateEngine: Sendable {
    private var baseline: [String: InterfaceCounter] = [:]
    private var lastDate: Date?
    private var lastUptime: Double?
    public init() {}
    public mutating func rebaseline(_ counters: [InterfaceCounter], at date: Date, uptime: Double) {
        baseline = Dictionary(uniqueKeysWithValues: counters.filter(\.active).map { ($0.name, $0) })
        lastDate = date; lastUptime = uptime
    }
    public mutating func sample(_ counters: [InterfaceCounter], at date: Date, uptime: Double) -> [InterfaceRate] {
        let active = counters.filter(\.active)
        defer { rebaseline(counters, at: date, uptime: uptime) }
        guard let lastDate, let lastUptime else { return active.map { InterfaceRate(name: $0.name) } }
        let elapsed = uptime - lastUptime, wall = date.timeIntervalSince(lastDate)
        let valid = elapsed > 0 && elapsed <= 15 && wall > 0 && abs(wall - elapsed) < 2
        return active.map { counter in
            guard valid, let previous = baseline[counter.name], previous.index == counter.index,
                  counter.received >= previous.received, counter.sent >= previous.sent else {
                return InterfaceRate(name: counter.name)
            }
            return InterfaceRate(name: counter.name, down: Double(counter.received - previous.received) / elapsed,
                                 up: Double(counter.sent - previous.sent) / elapsed)
        }
    }
}

public struct ConnectionDetail: Sendable, Identifiable, Equatable {
    public var id: InterfaceKind { kind }
    public var kind: InterfaceKind
    public var interfaces: [String]
    public var down: Double?
    public var up: Double?
    public var status: String
    public init(kind: InterfaceKind, interfaces: [String] = [], down: Double? = nil, up: Double? = nil, status: String = "Not active") {
        self.kind = kind; self.interfaces = interfaces; self.down = down; self.up = up; self.status = status
    }
    public static func make(counters: [InterfaceCounter], rates: [InterfaceRate], inventory: ConnectionInventory) -> [ConnectionDetail] {
        var rows: [ConnectionDetail] = []
        for kind in InterfaceKind.allCases {
            // Generic tunnels cannot establish protected-traffic attribution.
            if kind == .vpn { continue }
            let members = counters.filter { $0.active && inventory.kind(of: $0) == kind }
            if members.isEmpty { continue }
            var row = ConnectionDetail(kind: kind, interfaces: members.map(\.name).sorted())
            if !members.isEmpty {
                let matching = rates.filter { row.interfaces.contains($0.name) }
                if matching.count == members.count && matching.allSatisfy({ $0.down != nil && $0.up != nil }) {
                    row.down = matching.reduce(0) { $0 + $1.down! }; row.up = matching.reduce(0) { $0 + $1.up! }
                    row.status = kind.isOverlay ? "Separate overlay" : (members.allSatisfy(\.included) ? "In physical total" : "Live only")
                } else { row.status = "Waiting for sample" }
            }
            if kind == .bluetoothPAN && (row.down == nil || row.up == nil) { continue }
            rows.append(row)
        }
        return rows
    }
}

public enum GraphScale {
    public static func upperBound(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 1000 else { return 1000 }
        let power = pow(10, floor(log10(peak)))
        // A 102 MB/s measured peak gets 125 MB/s, rather than 200 MB/s.
        for step in [1.0, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8, 10] {
            let value = step * power
            if value >= peak { return value.isFinite ? value : peak }
        }
        return peak
    }
}
