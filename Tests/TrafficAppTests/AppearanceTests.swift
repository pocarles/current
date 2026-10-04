import XCTest
import AppKit
import SwiftUI
@testable import Traffic

@MainActor final class AppearanceTests: XCTestCase {
    func testLocalChoicesPersistIndependentlyAndInvalidValuesFallBack() {
        let name = "org.traffic.appearance-test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MonitorModel(automatic: false, preferences: defaults)
        XCTAssertEqual(model.appearance, .defaults)
        let chosen = TrafficAppearanceSettings(mode: .dark, lightTheme: .forest, darkTheme: .ember)
        model.setAppearance(chosen)
        let relaunched = MonitorModel(automatic: false, preferences: defaults)
        XCTAssertEqual(relaunched.appearance, chosen)
        defaults.set("unknown", forKey: "appearance.lightTheme")
        XCTAssertEqual(TrafficAppearanceSettings(preferences: defaults).lightTheme, .washed)
        XCTAssertEqual(TrafficAppearanceSettings(preferences: defaults).darkTheme, .ember)
        model.setAppearance(.defaults)
        XCTAssertEqual(TrafficAppearanceSettings(preferences: defaults), .defaults)
    }
    func testEachThemeResolvesBothRolesAndRespectsTheIntendedAppearance() throws {
        let previous = TrafficPalette.settings
        defer { TrafficPalette.apply(previous) }
        for theme in TrafficColorTheme.allCases {
            TrafficPalette.apply(.init(lightTheme: theme, darkTheme: theme))
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                appearance.performAsCurrentDrawingAppearance {
                    for upload in [false, true] {
                        let actual = (upload ? TrafficPalette.upload : TrafficPalette.download).usingColorSpace(.sRGB)!
                        let expected = TrafficPalette.resolved(upload: upload,
                            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, dark: dark, theme: theme)
                        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.00001)
                        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.00001)
                        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.00001)
                    }
                    XCTAssertNotEqual(TrafficPalette.download.usingColorSpace(.sRGB), TrafficPalette.upload.usingColorSpace(.sRGB))
                    XCTAssertEqual(TrafficPalette.download.usingColorSpace(.sRGB), TrafficPalette.windowDownload.usingColorSpace(.sRGB))
                    XCTAssertEqual(TrafficPalette.surface.usingColorSpace(.sRGB), TrafficPalette.resolvedSurface(dark: dark, theme: theme))
                }
                for upload in [false, true] {
                    let rgb = TrafficPalette.resolved(upload: upload, increasedContrast: true, dark: dark, theme: theme).usingColorSpace(.sRGB)!
                    func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                    let lum = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                    let surface = TrafficPalette.resolvedSurface(dark: dark, theme: theme).usingColorSpace(.sRGB)!
                    let background = 0.2126 * linear(surface.redComponent) + 0.7152 * linear(surface.greenComponent) + 0.0722 * linear(surface.blueComponent)
                    XCTAssertGreaterThanOrEqual((max(lum, background) + 0.05) / (min(lum, background) + 0.05), 4.5)
                }
            }
        }
        TrafficPalette.apply(.init(lightTheme: .forest, darkTheme: .ember))
        XCTAssertNotEqual(StatusFace.ink(TrafficPalette.download, appearance: .aqua), StatusFace.ink(TrafficPalette.download, appearance: .darkAqua))
    }
    func testRetiredIrisMigratesToGraphiteWithoutChangingOtherChoices() {
        let name = "org.traffic.theme-migration.\(UUID())", preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("iris", forKey: "appearance.lightTheme")
        preferences.set("ember", forKey: "appearance.darkTheme")
        preferences.set("dark", forKey: "appearance.mode")
        let value = TrafficAppearanceSettings(preferences: preferences)
        XCTAssertEqual(value.lightTheme, .graphite); XCTAssertEqual(value.darkTheme, .ember)
        XCTAssertEqual(value.mode, .dark)
        XCTAssertEqual(TrafficColorTheme.forest.title, "Matrix")
        value.save(to: preferences)
        XCTAssertEqual(preferences.string(forKey: "appearance.lightTheme"), "graphite")
    }
    func testRenderedPreviewAndPanelUseTheSameCanvasInEveryTheme() throws {
        _ = NSApplication.shared
        let previous = TrafficPalette.settings
        defer { TrafficPalette.apply(previous) }
        let name = "org.traffic.canvas-test.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = MonitorModel(automatic: false, preferences: preferences)
        for theme in TrafficColorTheme.allCases {
            TrafficPalette.apply(.init(lightTheme: theme, darkTheme: theme))
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let scheme: ColorScheme = dark ? .dark : .light
                let preview = ImageRenderer(content: PalettePreview(theme: theme, dark: dark)
                    .frame(width: 250).environment(\.colorScheme, scheme))
                let panel = ImageRenderer(content: PopoverView(model: model, showHistory: {}, showSettings: {}, quit: {}, renderingPreview: true)
                    .environment(\.colorScheme, scheme))
                var previewImage: NSImage?, panelImage: NSImage?
                appearance.performAsCurrentDrawingAppearance {
                    previewImage = preview.nsImage; panelImage = panel.nsImage
                }
                let previewBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(previewImage?.tiffRepresentation)))
                let panelBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(panelImage?.tiffRepresentation)))
                let sample = try XCTUnwrap(previewBitmap.colorAt(x: 10, y: 50)?.usingColorSpace(.sRGB))
                let runtime = try XCTUnwrap(panelBitmap.colorAt(x: 10, y: 70)?.usingColorSpace(.sRGB))
                let expected = TrafficPalette.resolvedSurface(dark: dark, theme: theme).usingColorSpace(.sRGB)!
                // Compare the two color-managed raster outputs directly;
                // NSImage's TIFF profile is distinct from source sRGB values.
                XCTAssertEqual(sample.redComponent, runtime.redComponent, accuracy: 2.0 / 255, "\(theme) \(dark)")
                XCTAssertEqual(sample.greenComponent, runtime.greenComponent, accuracy: 2.0 / 255, "\(theme) \(dark)")
                XCTAssertEqual(sample.blueComponent, runtime.blueComponent, accuracy: 2.0 / 255, "\(theme) \(dark)")
                if theme == .washed {
                    let grey = CGFloat(dark ? 30 : 236) / 255
                    XCTAssertEqual(expected.redComponent, grey, accuracy: 0.00001)
                    XCTAssertEqual(expected.greenComponent, grey, accuracy: 0.00001)
                    XCTAssertEqual(expected.blueComponent, grey, accuracy: 0.00001)
                }
            }
        }
    }
}
