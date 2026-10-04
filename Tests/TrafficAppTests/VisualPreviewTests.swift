import XCTest
import SwiftUI
import AppKit
import TrafficCore
@testable import Traffic

@MainActor final class VisualPreviewTests: XCTestCase {
    func testRenderSamplePopoverPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["TRAFFIC_PREVIEW_DIR"] else {
            throw XCTSkip("Set TRAFFIC_PREVIEW_DIR to render sample-data product previews.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = UserDefaults(suiteName: "org.traffic.preview")!
        let model = MonitorModel(automatic: false, preferences: preferences)
        model.setAppearance(.defaults)
        TrafficPalette.apply(.defaults)
        defer { model.setAppearance(.defaults); TrafficPalette.apply(.defaults) }
        let now = Date(timeIntervalSince1970: 1_791_028_800)
        model.down = 842_000; model.up = 125_000; model.rateAvailable = true
        model.health = .online; model.lastChecked = now; model.interfaces = ["en0"]
        model.connectedDuration = 17 * 60 + 42
        model.connectionDetails = [
            ConnectionDetail(kind: .wifi, interfaces: ["en0"], down: 842_000, up: 125_000, status: "In physical total"),
            ConnectionDetail(kind: .ethernet, interfaces: ["en1"], down: 0, up: 0, status: "In physical total"),
            ConnectionDetail(kind: .tailscale, interfaces: ["utun9"], down: 42_000, up: 8_000, status: "Separate overlay")
        ]
        model.graph = (0..<360).map { index in
            let x = Double(index)
            let down = max(0, 700_000 + 300_000 * sin(x / 28) + 1_100_000 * exp(-pow((x - 190) / 18, 2)))
            let up = max(0, 90_000 + 60_000 * sin(x / 44))
            return GraphPoint(start: now.addingTimeInterval(x * 10 - 3600), end: now.addingTimeInterval(x * 10 - 3590),
                              peakDown: down, peakUp: up, hasMeasurements: index < 80 || index > 87, hasGap: (80...87).contains(index))
        }
        for period in HistoryPeriod.allCases {
          model.period = period
          let index = HistoryPeriod.allCases.firstIndex(of: period)! + 1
          var summary = HistorySummary()
          summary.received = UInt64(index) * 4_230_000_000; summary.sent = UInt64(index) * 813_000_000
          summary.peakDown = Double(index) * 2_500_000; summary.peakUp = Double(index) * 300_000
          summary.observed = Double(index) * 20 * 3600; summary.appGap = Double(index) * 180
          summary.sleep = period == .all ? 8 * 3600 : 0; summary.unobserved = period == .days30 ? 120 : 0
          model.periodHistory = PeriodHistory(summary: summary, end: now, savedThrough: now,
              hasRecords: true, boundaryEstimated: period == .days30, peakIsUpperBound: period == .days30)
          let span = period.seconds ?? 90 * 86400
          let chartStart = now.addingTimeInterval(-span)
          model.periodChart = PeriodChart(start: chartStart, end: now, points: model.graph.map { point in
              var point = point
              point.start = chartStart.addingTimeInterval(point.start.timeIntervalSince(now.addingTimeInterval(-3600)) / 3600 * span)
              point.end = chartStart.addingTimeInterval(point.end.timeIntervalSince(now.addingTimeInterval(-3600)) / 3600 * span)
              point.peakDown *= Double(index); point.peakUp *= Double(index)
              return point
          }, resolution: span / 360)
          for theme in (period == .hour ? TrafficColorTheme.allCases : [.washed]) {
          model.setAppearance(TrafficAppearanceSettings(lightTheme: theme, darkTheme: theme))
          TrafficPalette.apply(model.appearance)
          for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            model.health = period == .days30 && name == "dark" ? .uncertain : .online
            model.connectedDuration = model.health == .online ? 17 * 60 + 42 : nil
            for expanded in (period == .hours24 || (period == .hour && theme == .washed) ? [false, true] : [false]) {
            model.connectionDetailsExpanded = expanded
            let content = VStack(spacing: 0) {
                PopoverView(model: model, showHistory: {}, showSettings: {}, quit: {}, renderingPreview: true)
                Text("Sample data · rendered preview")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.vertical, 10).frame(width: 460)
                    .background(Color(nsColor: .windowBackgroundColor))
            }.environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            var rendered: NSImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
            let image = try XCTUnwrap(rendered)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(bitmap.pixelsWide, 920)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 700)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let periodName = period == .all ? "all" : period.rawValue
            let themeSuffix = theme == .washed ? "" : "-\(theme.rawValue)"
            try data.write(to: directory.appendingPathComponent("period-\(periodName)-\(name)\(themeSuffix)\(expanded ? "-connections" : "").png"))
            }
          }
          }
        }
    }
}
