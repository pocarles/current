import AppKit

// Adaptive canvas and tonal direction families, drawn from Reserve.
// Existing raw values stay stable so saved choices survive palette refinements.
enum TrafficAppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}
enum TrafficColorTheme: String, CaseIterable, Sendable {
    case washed, forest, ocean, ember, graphite, iris
    static var allCases: [Self] { [.washed, .forest, .ocean, .ember, .graphite] }
    var title: String { self == .forest ? "Matrix" : self == .iris ? "Graphite" : rawValue.capitalized }
    var current: Self { self == .iris ? .graphite : self }
    private func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255)
    }
    // Reserve's near-neutral canvas identities. Direction pairs stay tonal.
    func surfaceRGB(dark: Bool) -> (CGFloat, CGFloat, CGFloat) {
        let hex: UInt32
        switch current {
        case .washed: hex = dark ? 0x1E1E1E : 0xECECEC
        case .forest: hex = dark ? 0x101612 : 0xF7FAF7
        case .ocean: hex = dark ? 0x0E1820 : 0xF5F9FC
        case .ember: hex = dark ? 0x1B1512 : 0xFCF8F3
        case .graphite, .iris: hex = dark ? 0x151617 : 0xF7F8F9
        }
        return components(hex)
    }
    func rgb(upload: Bool, dark: Bool, increasedContrast: Bool) -> (CGFloat, CGFloat, CGFloat) {
        let hex: UInt32
        switch current {
        case .washed:
            if increasedContrast {
                return upload ? (dark ? (0.67, 0.82, 0.95) : (0.055, 0.36, 0.78))
                              : (dark ? (0.65, 0.91, 0.80) : (0.055, 0.45, 0.21))
            }
            return upload ? (0.45, 0.68, 0.88) : (0.37, 0.72, 0.56)
        case .forest:
            hex = upload ? (dark ? 0x8BBC9A : 0x3E7355) : (dark ? 0x62D681 : 0x237740)
        case .ocean:
            hex = upload ? (dark ? 0x88B4CD : 0x426D88) : (dark ? 0x60C1EE : 0x17658D)
        case .ember:
            hex = upload ? (dark ? 0xCAA18A : 0x83543F) : (dark ? 0xF09970 : 0xA3522D)
        case .graphite, .iris:
            hex = upload ? (dark ? 0xA2AAB2 : 0x68717A) : (dark ? 0xD0D4D8 : 0x44505C)
        }
        return components(hex)
    }
}
struct TrafficAppearanceSettings: Equatable, Sendable {
    var mode = TrafficAppearanceMode.system
    var lightTheme = TrafficColorTheme.washed
    var darkTheme = TrafficColorTheme.washed
    static let defaults = TrafficAppearanceSettings()
    init(mode: TrafficAppearanceMode = .system, lightTheme: TrafficColorTheme = .washed, darkTheme: TrafficColorTheme = .washed) {
        self.mode = mode; self.lightTheme = lightTheme; self.darkTheme = darkTheme
    }
    init(preferences: UserDefaults) {
        mode = TrafficAppearanceMode(rawValue: preferences.string(forKey: "appearance.mode") ?? "") ?? .system
        lightTheme = TrafficColorTheme(rawValue: preferences.string(forKey: "appearance.lightTheme") ?? "") ?? .washed
        lightTheme = lightTheme.current
        darkTheme = TrafficColorTheme(rawValue: preferences.string(forKey: "appearance.darkTheme") ?? "") ?? .washed
        darkTheme = darkTheme.current
    }
    func save(to preferences: UserDefaults) {
        preferences.set(mode.rawValue, forKey: "appearance.mode")
        preferences.set(lightTheme.rawValue, forKey: "appearance.lightTheme")
        preferences.set(darkTheme.rawValue, forKey: "appearance.darkTheme")
    }
}
