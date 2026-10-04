import XCTest
import AppKit
import TrafficCore
@testable import Traffic

@MainActor final class StatusFaceTests: XCTestCase {
    func testMenuRatesDrawWhiteInEveryPaletteWithSeparateHealthColor() throws {
        let previous = TrafficPalette.settings
        defer { TrafficPalette.apply(previous) }
        for theme in TrafficColorTheme.allCases {
            TrafficPalette.apply(.init(lightTheme: theme, darkTheme: theme))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 48,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 64, height: 24).fill()
            let face = StatusFace(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
            face.down = StatusRate(842_000); face.up = StatusRate(125_000); face.health = .online
            face.draw(face.bounds); NSGraphicsContext.restoreGraphicsState()
            for rows in [0..<24, 24..<48] {
                var bright = 0
                for y in rows { for x in 0..<108 {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.01)
                    XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.01)
                    if color.redComponent > 0.9 { bright += 1 }
                } }
                XCTAssertGreaterThan(bright, 20, "Both rate rows must have visible white ink")
            }
            let dot = try XCTUnwrap(bitmap.colorAt(x: 118, y: 24)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(dot.greenComponent, dot.redComponent, "Health must stay separate from white rates")
        }
    }
    func testDirectionInkContrastInLightAndDarkAppearances() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var failure: Error?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                do {
                    let background = try luminance(.windowBackgroundColor)
                    for (role, color) in [("window download", TrafficPalette.windowDownload), ("window upload", TrafficPalette.windowUpload)] {
                        let foreground = try luminance(color)
                        let contrast = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                        print("DIRECTION_CONTRAST \(name.rawValue) \(role) ratio=\(contrast)")
                        // Washed colors are not an ordinary-text WCAG claim;
                        // labels/arrows remain, with increased-contrast support.
                        XCTAssertGreaterThanOrEqual(contrast, 2)
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
        }
    }
    func testSharedDirectionPaletteAndIncreasedContrastCompanion() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                XCTAssertEqual(TrafficPalette.download.usingColorSpace(.sRGB), TrafficPalette.windowDownload.usingColorSpace(.sRGB))
                XCTAssertEqual(TrafficPalette.download.usingColorSpace(.sRGB), TrafficPalette.downloadAccent.usingColorSpace(.sRGB))
                XCTAssertEqual(TrafficPalette.upload.usingColorSpace(.sRGB), TrafficPalette.windowUpload.usingColorSpace(.sRGB))
                XCTAssertEqual(TrafficPalette.upload.usingColorSpace(.sRGB), TrafficPalette.uploadAccent.usingColorSpace(.sRGB))
            }
        }
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for dark in [false, true] {
            for upload in [false, true] {
                let color = TrafficPalette.resolved(upload: upload, increasedContrast: true, dark: dark)
                let background = dark ? 0.02 : 1.0, foreground = luminance(color)
                XCTAssertGreaterThanOrEqual((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05), 4.5)
            }
        }
    }
    func testCompactUnitsAndRoundingBoundaries() {
        for (value, expected) in [(0.0, "0B/s"), (12, "12B/s"), (999, "999B/s"),
                                  (999.5, "1.0kB/s"), (1_250, "1.2kB/s"),
                                  (9_950, "10kB/s"), (999_500, "1.0MB/s"),
                                  (842_000, "842kB/s"), (125_000_000, "125MB/s"),
                                  (18_446_744_073_709_551_616, "18EB/s")] {
            let rate = StatusRate(value)
            XCTAssertEqual(rate.number + rate.unit, expected, "\(value)")
        }
        for value in [-1.0, .nan, .infinity] { XCTAssertEqual(StatusRate(value), .unobserved) }
    }

    func testEveryScaleFitsFixedWidthWithoutOverlappingArrowOrHealth() {
        var values: [Double] = [0, 9.949, 9.95, 99.5, 998.5, 999.49, 999.5, .greatestFiniteMagnitude]
        for exponent in 0...308 {
            let scale = pow(10.0, Double(exponent))
            for multiple in [1.0, 9.949, 9.95, 99.49, 999.49, 999.5] {
                let value = scale * multiple
                if value.isFinite { values.append(value) }
            }
        }
        let available = StatusFace.textRight - StatusFace.textLeft
        var widest: CGFloat = 0
        for value in values {
            let width = StatusFace.text(StatusRate(value)).size().width
            widest = max(widest, width)
            XCTAssertLessThanOrEqual(width, available, "Rate \(value) needs \(width) points")
        }
        print("STATUS_LAYOUT reserved=\(StatusFace.width) textAvailable=\(available) widestTested=\(widest)")
        let face = StatusFace(frame: NSRect(x: 0, y: 0, width: StatusFace.width, height: 24))
        XCTAssertNil(face.hitTest(NSPoint(x: 20, y: 10)))
        XCTAssertFalse(face.isAccessibilityElement())
        let model = MonitorModel(automatic: false, preferences: UserDefaults(suiteName: "org.traffic.status-tests")!)
        model.down = 999_500; model.up = 12; model.rateAvailable = true; model.health = .offline
        face.update(model)
        XCTAssertEqual(face.down, StatusRate(model.down)); XCTAssertEqual(face.up, StatusRate(model.up))
        XCTAssertEqual(face.health, .offline)
        XCTAssertEqual(face.frame.width, 64)
        model.rateAvailable = false; face.update(model)
        XCTAssertEqual(face.down, .unobserved); XCTAssertEqual(face.up, .unobserved)
    }

    func testStatusInkStaysIdenticalInOpenAndClosedDrawingAppearances() throws {
        func render(menu: NSAppearance.Name, drawing: NSAppearance.Name) throws -> Data {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 48,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            context.cgContext.scaleBy(x: 2, y: 2)
            NSColor(white: menu == .aqua ? 0.35 : 0.15, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 64, height: 24).fill()
            let face = StatusFace(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
            face.menuAppearanceName = menu; face.down = StatusRate(842_000); face.up = StatusRate(125_000); face.health = .online
            NSAppearance(named: drawing)!.performAsCurrentDrawingAppearance { face.draw(face.bounds) }
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        for menu in [NSAppearance.Name.aqua, .darkAqua] {
            let closed = try render(menu: menu, drawing: menu)
            let selected = try render(menu: menu, drawing: menu == .aqua ? .darkAqua : .aqua)
            XCTAssertEqual(closed, selected, "Selected drawing must keep the closed menu ink: \(menu)")
        }
    }

    func testResolvedMenuInkMatchesItsUnselectedPaletteComponents() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for dynamic in [TrafficPalette.download, TrafficPalette.upload] {
                var expected: [CGFloat] = []
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let rgb = dynamic.usingColorSpace(.sRGB)!
                    expected = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                }
                let resolved = try XCTUnwrap(StatusFace.ink(dynamic, appearance: name).usingColorSpace(.sRGB))
                let actual = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
                for (component, reference) in zip(actual, expected) { XCTAssertEqual(component, reference, accuracy: 0.00001) }
            }
        }
    }

    func testRenderSelectedStatusColors() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAFFIC_STATUS_PREVIEW_DIR"] else {
            throw XCTSkip("Set TRAFFIC_STATUS_PREVIEW_DIR to render selected menu ink.")
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 360, height: 130).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
        ("Current · closed / selected ink · 64 pt" as NSString).draw(at: NSPoint(x: 12, y: 108), withAttributes: label)
        ("Closed" as NSString).draw(at: NSPoint(x: 100, y: 90), withAttributes: label)
        ("Open" as NSString).draw(at: NSPoint(x: 200, y: 90), withAttributes: label)
        for (index, menu) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let y = CGFloat(65 - index * 30)
            ((menu == .aqua ? "Light" : "Dark") as NSString).draw(at: NSPoint(x: 12, y: y + 7), withAttributes: label)
            for (x, selected) in [(100.0, false), (200.0, true)] {
                let face = StatusFace(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
                face.menuAppearanceName = menu; face.down = StatusRate(842_000); face.up = StatusRate(125_000); face.health = .online
                NSGraphicsContext.saveGraphicsState(); context.cgContext.translateBy(x: x, y: y)
                NSColor(white: menu == .aqua ? 0.35 : 0.15, alpha: 1).setFill(); face.bounds.fill()
                let drawing = selected ? (menu == .aqua ? NSAppearance.Name.darkAqua : .aqua) : menu
                NSAppearance(named: drawing)!.performAsCurrentDrawingAppearance { face.draw(face.bounds) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        ("Sample render · selected drawing simulated" as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: label)
        NSGraphicsContext.restoreGraphicsState()
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("status-selected.png"))
    }

    func testRenderActualStatusFace() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAFFIC_STATUS_PREVIEW_DIR"] else {
            throw XCTSkip("Set TRAFFIC_STATUS_PREVIEW_DIR to render the actual AppKit status face.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, Double?, Double?, ConnectionHealth)] = [
            ("Quiet / online", 12, 0, .online),
            ("Normal / online", 842_000, 125_000, .online),
            ("High / online", 999_499_000, 9_940_000_000, .online),
            ("Counter limit", Double(UInt64.max), 125_000_000_000, .online),
            ("Offline (LAN traffic)", 1_250, 0, .offline),
            ("Unobserved / checking", nil, nil, .checking)
        ]
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 456,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 360, height: 228).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
        ("Current · actual status face · 64 pt" as NSString).draw(at: NSPoint(x: 12, y: 207), withAttributes: label)
        for (index, item) in cases.enumerated() {
            let y = CGFloat(174 - index * 27)
            (item.0 as NSString).draw(at: NSPoint(x: 12, y: y + 7), withAttributes: label)
            for (x, appearance) in [(166.0, NSAppearance.Name.aqua), (250.0, .darkAqua)] {
                let face = StatusFace(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
                face.menuAppearanceName = appearance
                face.down = item.1.map(StatusRate.init) ?? .unobserved
                face.up = item.2.map(StatusRate.init) ?? .unobserved; face.health = item.3
                NSGraphicsContext.saveGraphicsState()
                context.cgContext.translateBy(x: x, y: y)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    (appearance == .aqua ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.15, alpha: 1)).setFill()
                    face.bounds.fill(); face.draw(face.bounds)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        ("Sample rates · 2× render · not a live screenshot" as NSString)
            .draw(at: NSPoint(x: 12, y: 12), withAttributes: label)
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("status-compact.png"))
    }
}
