import Foundation

public enum InterfaceKind: String, CaseIterable, Sendable {
    // Declaration order is display order.
    case wifi, ethernet, hotspot, thunderbolt, bluetoothPAN, airdrop, tailscale, vpn
    public var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .hotspot: "Hotspot"
        case .thunderbolt: "Thunderbolt Bridge"
        case .bluetoothPAN: "Bluetooth"
        case .airdrop: "AirDrop & Continuity"
        case .tailscale: "Tailscale"
        case .vpn: "VPN"
        }
    }
    public var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .hotspot: "personalhotspot"
        case .thunderbolt: "bolt.horizontal"
        case .bluetoothPAN: "dot.radiowaves.left.and.right"
        case .airdrop: "airplayaudio"
        case .tailscale: "point.3.connected.trianglepath.dotted"
        case .vpn: "lock.shield"
        }
    }
    /// Tunnels carry traffic that the physical interfaces also count, so they never add to totals.
    public var isOverlay: Bool { self == .tailscale || self == .vpn }
    /// Peer-to-peer links between nearby devices, not internet access.
    public var isLocal: Bool { self == .airdrop || self == .thunderbolt }
}

public struct ConnectionInventory: Sendable {
    public var physicalKinds: [String: InterfaceKind]
    public var tailscaleInterface: String?
    public var tailscaleIndex: UInt32?
    public var tailscaleInstalled: Bool
    public var tailscaleAvailable: Bool
    /// Local addresses by interface name. An address is what makes an idle link "in use".
    public var addresses: [String: Set<String>]
    /// Interfaces macOS reports as metered, such as a phone hotspot over Wi-Fi or USB.
    public var meteredInterfaces: Set<String>
    public init(physicalKinds: [String: InterfaceKind] = [:], tailscaleInterface: String? = nil,
                tailscaleInstalled: Bool = false, tailscaleAvailable: Bool = false, tailscaleIndex: UInt32? = nil,
                addresses: [String: Set<String>] = [:], meteredInterfaces: Set<String> = []) {
        self.physicalKinds = physicalKinds; self.tailscaleInterface = tailscaleInterface
        self.tailscaleIndex = tailscaleIndex; self.tailscaleInstalled = tailscaleInstalled; self.tailscaleAvailable = tailscaleAvailable
        self.addresses = addresses; self.meteredInterfaces = meteredInterfaces
    }
    public func kind(of counter: InterfaceCounter) -> InterfaceKind? {
        if counter.name == tailscaleInterface, counter.index == tailscaleIndex, !counter.ethernet { return .tailscale }
        if ["utun", "ipsec", "ppp"].contains(where: counter.name.hasPrefix) { return .vpn }
        if counter.name.hasPrefix("awdl") || counter.name.hasPrefix("llw") { return .airdrop }
        // Only real network interfaces: Ethernet-type links, plus the bridge that has its own type.
        guard counter.included || (physicalKinds[counter.name].map { counter.ethernet || $0 == .thunderbolt } ?? false) else { return nil }
        let kind = physicalKinds[counter.name] ?? .ethernet
        if meteredInterfaces.contains(counter.name), [.wifi, .ethernet, .bluetoothPAN].contains(kind) { return .hotspot }
        return kind
    }
    /// A link is in use when it holds an address that can carry traffic. Link-local
    /// addresses exist on idle ports, except Thunderbolt Bridge, which runs on them.
    public func hasUsableAddress(_ name: String, kind: InterfaceKind) -> Bool {
        guard kind != .airdrop else { return false }
        return (addresses[name] ?? []).contains { address in
            if address.contains(":") { return !address.lowercased().hasPrefix("fe80") }
            return kind == .thunderbolt || !address.hasPrefix("169.254.")
        }
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
        baseline = Dictionary(uniqueKeysWithValues: counters.filter(\.active).uniqueByName().map { ($0.name, $0) })
        lastDate = date; lastUptime = uptime
    }
    public mutating func sample(_ counters: [InterfaceCounter], at date: Date, uptime: Double) -> [InterfaceRate] {
        let active = counters.filter(\.active).uniqueByName()
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
    /// Combined rate at which a link counts as busy, enough to ignore discovery beacons.
    public static let busyRate: Double = 2048
    /// Rows appear only for links in use: a usable address, or traffic now or recently.
    public static func make(counters: [InterfaceCounter], rates: [InterfaceRate], inventory: ConnectionInventory,
                            recentlyBusy: Set<String> = []) -> [ConnectionDetail] {
        let rateByName = Dictionary(rates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [ConnectionDetail] = []
        for kind in InterfaceKind.allCases {
            var members = counters.filter { $0.active && inventory.kind(of: $0) == kind }.filter { member in
                let rate = rateByName[member.name]
                let busy = (rate?.down ?? 0) + (rate?.up ?? 0) >= busyRate
                return busy || recentlyBusy.contains(member.name) || inventory.hasUsableAddress(member.name, kind: kind)
            }
            // An in-use bridge already carries its member ports' traffic; count it once.
            if kind == .thunderbolt, members.contains(where: { $0.name.hasPrefix("bridge") }) {
                members = members.filter { $0.name.hasPrefix("bridge") }
            }
            if members.isEmpty { continue }
            var row = ConnectionDetail(kind: kind, interfaces: members.map(\.name).sorted())
            let matching = members.compactMap { rateByName[$0.name] }
            if matching.count == members.count && matching.allSatisfy({ $0.down != nil && $0.up != nil }) {
                row.down = matching.reduce(0) { $0 + $1.down! }; row.up = matching.reduce(0) { $0 + $1.up! }
                row.status = kind.isOverlay ? "Separate overlay" : kind.isLocal ? "Local link"
                    : (members.allSatisfy(\.included) ? "In physical total" : "Live only")
            } else { row.status = "Waiting for sample" }
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
