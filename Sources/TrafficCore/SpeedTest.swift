import Foundation

/// One run of macOS's built-in `networkQuality` test against Apple's servers.
public struct SpeedTestResult: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    /// Throughput in bits per second, the unit internet plans are sold in.
    public var download: Double
    public var upload: Double
    /// Round trips per minute while the link is loaded. Higher feels snappier.
    public var responsiveness: Double?
    /// Unloaded round trip in milliseconds.
    public var idleLatency: Double?
    /// Bytes the test itself moved, which also appear in measured totals.
    public var bytesUsed: UInt64
    public var interface: String?

    public init(start: Date, end: Date, download: Double, upload: Double, responsiveness: Double? = nil,
                idleLatency: Double? = nil, bytesUsed: UInt64 = 0, interface: String? = nil) {
        self.start = start; self.end = end; self.download = download; self.upload = upload
        self.responsiveness = responsiveness; self.idleLatency = idleLatency; self.bytesUsed = bytesUsed; self.interface = interface
    }

    /// Parse `networkQuality -c` output. Rejects missing, negative or non-finite throughput.
    public static func parse(_ data: Data, start: Date, end: Date) -> SpeedTestResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = (json[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        guard let download = number("dl_throughput"), let upload = number("ul_throughput") else { return nil }
        let bytes = [number("dl_bytes_transferred"), number("ul_bytes_transferred")].compactMap { $0 }.reduce(0, +)
        guard bytes <= Self.maxBytes else { return nil }
        let result = SpeedTestResult(start: start, end: end, download: download, upload: upload,
            responsiveness: number("responsiveness").flatMap { $0 > 0 ? $0 : nil }, idleLatency: number("base_rtt"),
            bytesUsed: UInt64(bytes), interface: json["interface_name"] as? String)
        return result.isPlausible ? result : nil
    }
    static let maxBytes = 1e15
    /// Physically possible values only. Anything else, parsed or restored from settings, is discarded
    /// so later integer conversions can never trap.
    public var isPlausible: Bool {
        func within(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        return within(download, 0...1e12) && within(upload, 0...1e12)
            && (responsiveness.map { within($0, 0.1...1e6) } ?? true)
            && (idleLatency.map { within($0, 0...1e6) } ?? true)
            && Double(bytesUsed) <= Self.maxBytes && end >= start
    }

    public enum Snappiness: String, Sendable {
        case snappy, fine, sluggish
        public var label: String {
            switch self { case .snappy: "Snappy"; case .fine: "Fine"; case .sluggish: "Sluggish" }
        }
        public var detail: String {
            switch self {
            case .snappy: "Stays quick even while the connection is busy."
            case .fine: "Small delays when someone else is downloading or uploading."
            case .sluggish: "Calls and games may lag while the connection is busy."
            }
        }
    }
    /// Working latency under load: Snappy at 75 ms or less, Sluggish above 200 ms.
    public var snappiness: Snappiness? {
        guard let responsiveness else { return nil }
        if responsiveness >= 800 { return .snappy }
        return responsiveness >= 300 ? .fine : .sluggish
    }
    public var workingLatency: Double? { responsiveness.map { 60_000 / $0 } }

    /// What the numbers mean in everyday terms.
    public var verdicts: [String] {
        let streams = Int(download / 25_000_000)
        let fourK = streams >= 1 ? "\(streams >= 100 ? "99+" : String(streams)) × 4K streams" : "4K streaming may buffer"
        let game = download > 0 ? "50 GB game in \(Self.duration(50e9 * 8 / download))" : "Downloads stalled"
        let calls: String
        if upload >= 3_500_000 && snappiness != .sluggish { calls = "Video calls: smooth" }
        else if upload >= 1_500_000 { calls = "Video calls: okay" }
        else { calls = "Video calls may stutter" }
        return [fourK, game, calls]
    }

    public static func bits(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 Mbps" }
        if value >= 1e9 { return String(format: "%.1f Gbps", value / 1e9) }
        if value >= 1e7 { return "\(Int((value / 1e6).rounded())) Mbps" }
        if value >= 1e6 { return String(format: "%.1f Mbps", value / 1e6) }
        return "\(Int((value / 1e3).rounded())) kbps"
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds < 365 * 86400 else { return "over a year" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        let hours = Int(seconds / 3600), minutes = Int((seconds - Double(hours) * 3600) / 60)
        if hours >= 48 { return "\(hours / 24) days" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
