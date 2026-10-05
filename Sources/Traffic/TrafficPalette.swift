import AppKit
import SwiftUI

@MainActor enum TrafficPalette {
    private(set) static var settings = TrafficAppearanceSettings.defaults
    private static var directionDownload = direction("TrafficDownload", upload: false, settings: .defaults)
    private static var directionUpload = direction("TrafficUpload", upload: true, settings: .defaults)
    private static var canvas = surface(settings: .defaults)
    private static let healthy = direction("TrafficReachable", upload: false, settings: .defaults)
    static var download: NSColor { directionDownload }
    static var upload: NSColor { directionUpload }
    static var windowDownload: NSColor { download }
    static var windowUpload: NSColor { upload }
    static var downloadAccent: NSColor { download }
    static var uploadAccent: NSColor { upload }
    static var reachable: NSColor { healthy }
    static var reachableColor: Color { Color(nsColor: healthy) }
    static var windowDownloadColor: Color { Color(nsColor: download) }
    static var windowUploadColor: Color { Color(nsColor: upload) }
    static var downloadAccentColor: Color { windowDownloadColor }
    static var uploadAccentColor: Color { windowUploadColor }
    static var surface: NSColor { canvas }
    static var surfaceColor: Color { Color(nsColor: canvas) }
    static func apply(_ value: TrafficAppearanceSettings) {
        guard settings != value else { return }
        settings = value
        // Regenerate only on preference changes, never at the sample cadence.
        directionDownload = direction("TrafficDownload", upload: false, settings: value)
        directionUpload = direction("TrafficUpload", upload: true, settings: value)
        canvas = surface(settings: value)
    }
    // Runtime panels and Settings previews must resolve the same canvas.
    nonisolated static func resolvedSurface(dark: Bool, theme: TrafficColorTheme = .washed) -> NSColor {
        let rgb = theme.surfaceRGB(dark: dark)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    private static func surface(settings: TrafficAppearanceSettings) -> NSColor {
        // AppKit may resolve dynamic colors off the main thread, so providers stay nonisolated.
        NSColor(name: NSColor.Name("TrafficSurface-\(settings.lightTheme.rawValue)-\(settings.darkTheme.rawValue)")) { appearance in
            let dark = isDark(appearance)
            return resolvedSurface(dark: dark, theme: dark ? settings.darkTheme : settings.lightTheme)
        }
    }
    nonisolated static func resolved(upload: Bool, increasedContrast: Bool, dark: Bool, theme: TrafficColorTheme = .washed) -> NSColor {
        let rgb = theme.rgb(upload: upload, dark: dark, increasedContrast: increasedContrast)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    private static func direction(_ name: String, upload: Bool, settings: TrafficAppearanceSettings) -> NSColor {
        NSColor(name: NSColor.Name("\(name)-\(settings.lightTheme.rawValue)-\(settings.darkTheme.rawValue)")) { appearance in
            let match = appearance.bestMatch(from: highContrastAppearances + [.aqua, .darkAqua])
            let dark = isDark(appearance)
            return resolved(upload: upload, increasedContrast: match.map(highContrastAppearances.contains) ?? false,
                dark: dark, theme: dark ? settings.darkTheme : settings.lightTheme)
        }
    }
    private nonisolated static let highContrastAppearances: [NSAppearance.Name] = [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
    private nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        [.darkAqua, .accessibilityHighContrastDarkAqua].contains(appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]))
    }
}
