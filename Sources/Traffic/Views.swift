import SwiftUI
import AppKit
import TrafficCore

struct GraphMarker: Equatable {
    var date: Date
    var label: String
}

/// Shared shape language: continuous corners, quiet fills that sit on any color theme.
enum PanelStyle {
    static let corner: CGFloat = 12
    static var cardFill: Color { Color.primary.opacity(0.045) }
    static var hairline: Color { Color.primary.opacity(0.07) }
}
extension View {
    func panelCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(PanelStyle.cardFill, in: RoundedRectangle(cornerRadius: PanelStyle.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PanelStyle.corner, style: .continuous).strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
    }
}
/// A compact text button with a soft tinted plate. Drawn in SwiftUI so previews render it.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .padding(.horizontal, 10).frame(height: 24)
            .background((prominent ? Color.accentColor : Color.accentColor.opacity(0.12)).opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct RateGraph: View {
    let chart: PeriodChart
    let title: String
    var markers: [GraphMarker] = []
    var height: CGFloat = 112
    private var observations: [GraphPoint] { chart.points }
    private var measuredPeak: Double { observations.filter(\.hasMeasurements).map { max($0.peakDown, $0.peakUp) }.max() ?? 0 }
    private var maximum: Double { GraphScale.upperBound(measuredPeak) }
    var body: some View {
        Canvas { context, size in
            let start = chart.start
            let span = max(1, chart.end.timeIntervalSince(start))
            let plotTop: CGFloat = 4
            for index in 0...2 {
                var line = Path()
                let y = size.height * CGFloat(index) / 2
                line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(index == 2 ? 0.22 : 0.1)), lineWidth: 0.5)
            }
            for observation in observations where observation.hasGap {
                let x = max(0, observation.start.timeIntervalSince(start) / span) * size.width
                let width = min(size.width - x, observation.end.timeIntervalSince(observation.start) / span * size.width)
                if width > 0 {
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.secondary.opacity(0.08)))
                }
            }
            for (upload, ink) in [(false, TrafficPalette.windowDownloadColor), (true, TrafficPalette.windowUploadColor)] {
                // Contiguous runs only: lines never bridge sleep, app gaps or missing readings.
                var runs: [[CGPoint]] = [], current: [CGPoint] = [], previous: GraphPoint?
                for observation in observations {
                    guard observation.hasMeasurements else { if !current.isEmpty { runs.append(current) }; current = []; previous = nil; continue }
                    let x = max(0, observation.end.timeIntervalSince(start) / span) * size.width
                    let y = size.height - CGFloat((upload ? observation.peakUp : observation.peakDown) / maximum) * (size.height - plotTop)
                    let joins = previous.map { !$0.hasGap && !observation.hasGap && observation.start.timeIntervalSince($0.end) < 0.001 } ?? false
                    if !joins && !current.isEmpty { runs.append(current); current = [] }
                    current.append(CGPoint(x: x, y: y)); previous = observation
                }
                if !current.isEmpty { runs.append(current) }
                for run in runs {
                    if run.count == 1 {
                        context.fill(Path(ellipseIn: CGRect(x: run[0].x - 1.5, y: run[0].y - 1.5, width: 3, height: 3)), with: .color(ink))
                        continue
                    }
                    var line = Path(); line.addLines(run)
                    var area = line
                    area.addLine(to: CGPoint(x: run.last!.x, y: size.height)); area.addLine(to: CGPoint(x: run[0].x, y: size.height)); area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [ink.opacity(upload ? 0.10 : 0.16), ink.opacity(0)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
            for (index, value) in [(0, maximum), (1, maximum / 2)] {
                let label = context.resolve(Text(Format.rate(value)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary))
                let origin = CGPoint(x: 0, y: size.height * CGFloat(index) / 2 + 2), measured = label.measure(in: size)
                context.fill(Path(roundedRect: CGRect(x: origin.x, y: origin.y, width: measured.width + 4, height: measured.height), cornerRadius: 3),
                             with: .color(TrafficPalette.surfaceColor.opacity(0.85)))
                context.draw(label, at: origin, anchor: .topLeading)
            }
            for marker in markers where marker.date >= start && marker.date <= chart.end {
                let x = marker.date.timeIntervalSince(start) / span * size.width
                var line = Path(); line.move(to: CGPoint(x: x, y: 14)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                let label = context.resolve(Text(marker.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary))
                let measured = label.measure(in: size)
                let center = CGPoint(x: min(max(x, measured.width / 2 + 60), size.width - measured.width / 2 - 3), y: 7)
                let plate = CGRect(x: center.x - measured.width / 2 - 4, y: center.y - measured.height / 2 - 1,
                                   width: measured.width + 8, height: measured.height + 2)
                context.fill(Path(roundedRect: plate, cornerRadius: 4), with: .color(TrafficPalette.surfaceColor))
                context.draw(label, at: center)
            }
        }
        .frame(height: height)
        .help("\(title). Peaks grouped into approximately \(Format.duration(chart.resolution)) bins; older retained summaries have coarser timing. Shaded bins include unrecorded, sleeping or app-off time; lines do not bridge those gaps. Clipped-bin peaks are upper bounds. Longer ranges refresh with saved history about once a minute.")
        .accessibilityLabel("\(title). Download and upload use their selected colors. Shaded gaps are unrecorded, sleeping or app gaps. Selected-range measured peak \(Format.rate(measuredPeak)).")
    }
}

struct PopoverView: View {
    @ObservedObject var model: MonitorModel
    var showHistory: () -> Void
    var showSettings: () -> Void
    var showAbout: () -> Void = {}
    var quit: () -> Void
    var renderingPreview = false
    var setPinned: (Bool) -> Void = { _ in }
    @State private var pinned = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.showLoginItemOffer { loginItemOffer }
            HStack(alignment: .top) {
                rate("Download", symbol: "arrow.down", value: model.down, color: TrafficPalette.windowDownloadColor, alignment: .leading)
                Spacer(minLength: 12)
                rate("Upload", symbol: "arrow.up", value: model.up, color: TrafficPalette.windowUploadColor, alignment: .trailing)
            }
            VStack(spacing: 10) {
                HStack {
                    Text(model.period.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    periodPicker
                }
                RateGraph(chart: model.displayedChart, title: model.period.title, markers: model.graphMarkers)
            }
            totals
            VStack(alignment: .leading, spacing: 12) {
                health
                Rectangle().fill(PanelStyle.hairline).frame(height: 0.5)
                SpeedTestCard(model: model)
            }.panelCard()
            if !model.connectionDetails.isEmpty { connections }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: showHistory) { Label("History", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).help("View history stored on this Mac")
                Spacer()
                if model.lowPower { Label("Low Power Mode", systemImage: "leaf").help("Checks every 2 minutes and samples less often while closed.") }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 460)
        .background(TrafficPalette.surfaceColor)
    }
    /// Shown once on a first install. Nothing changes until the person picks.
    private var loginItemOffer: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open at login?").font(.system(size: 13, weight: .semibold))
                Text("Keep Current in your menu bar after every restart.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not now") { model.answerLoginItemOffer(enable: false) }.buttonStyle(QuietButtonStyle())
            Button("Open at Login") { model.answerLoginItemOffer(enable: true) }.buttonStyle(QuietButtonStyle(prominent: true))
        }
        .panelCard(padding: 12)
        .accessibilityElement(children: .contain)
    }
    private var header: some View {
        HStack(spacing: 4) {
            HStack {
                Text("Current").font(.system(size: 15, weight: .semibold))
                Spacer()
            }.overlay { if !renderingPreview { PanelDragRegion(enabled: pinned) } }
            if renderingPreview {
                Image(systemName: "pin").frame(width: 28, height: 28).foregroundStyle(.secondary)
                Image(systemName: "ellipsis").frame(width: 28, height: 28).foregroundStyle(.secondary)
            } else {
                PanelPinButton(pinned: pinned) {
                    pinned.toggle(); setPinned(pinned)
                }.frame(width: 28, height: 28)
                PanelSettingsButton(settings: showSettings, about: showAbout, quit: quit)
                    .frame(width: 28, height: 28)
            }
        }
    }
    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(HistoryPeriod.allCases, id: \.self) { period in
                let selected = model.period == period
                Button { model.selectPeriod(period) } label: {
                    Text(period.rawValue).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel("Show \(period.title.lowercased())")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityLabel("History period")
    }
    /// Fixed height: switching periods or loading must never move or resize the panel.
    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let history = model.periodHistory {
                HStack(alignment: .firstTextBaseline) {
                    stat("Downloaded", Format.bytes(history.summary.received), color: TrafficPalette.windowDownloadColor)
                    Spacer()
                    stat("Uploaded", Format.bytes(history.summary.sent), color: TrafficPalette.windowUploadColor)
                    Spacer()
                    stat("Peak", "\(model.displayedPeakIsUpperBound ? "≤ " : "")\(Format.rate(model.displayedPeak))", color: .secondary, alignment: .trailing)
                        .help(model.displayedPeakIsUpperBound ? "An upper bound from a clipped history bucket; the exact peak time is no longer retained." : "Highest observed download or upload rate in the selected period, not connection capacity.")
                }
                // Only time Current could not measure leaves totals short. Sleep has no traffic to miss,
                // and the rolling window's split edge bucket is a negligible estimate, so neither is flagged.
                if let note = Format.unmeasuredNote(appGap: history.summary.appGap, unobserved: history.summary.unobserved) {
                    Label(note, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Totals include only measured time. Saved through \(history.savedThrough?.formatted(date: .abbreviated, time: .standard) ?? "no observations"). \(Format.duration(history.summary.sleep)) asleep; \(Format.duration(history.summary.appGap)) Current not running; \(Format.duration(history.summary.unobserved)) without readings.\(history.boundaryEstimated ? " Edge buckets are estimated proportionally." : "")")
                }
            } else {
                Text(model.periodLoading ? "Loading saved totals…" : "Saved totals unavailable")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
    }
    private var health: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(model.health.color).frame(width: 7, height: 7).padding(.top, 5)
                .shadow(color: model.health.color.opacity(0.5), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.health.label).font(.system(size: 13, weight: .medium))
                Group {
                    // While reachable, routine background checks stay silent; the exact time is on hover.
                    if model.health == .online && model.probesEnabled && !model.checkPending {
                        Text(model.lowPower ? "Checked every 2 min" : "Checked every 30 s")
                            .help(model.lastChecked.map { "Last check \($0.formatted(date: .omitted, time: .standard))" } ?? "")
                    } else if model.checkInProgress || model.checkPending {
                        Text(model.checkInProgress ? "Checking now…" : "Check queued…")
                    } else if let checked = model.lastChecked {
                        Text("Last check \(checked.formatted(date: .omitted, time: .standard))")
                    } else {
                        Text(model.probesEnabled ? "Waiting for a check" : "Passive traffic monitoring continues")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.connectedDuration.map(Format.connectionDuration) ?? "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                Text("Observed online").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.connectedDuration.map { "Current continuously observed online interval \(Format.connectionDuration($0)). Earlier connection start unknown." } ?? "Online interval unverified. Earlier connection start unknown.")
            .help("Current uninterrupted observation window supported by fresh successful internet checks. Resets after app restart, sleep, missing or stale samples, path changes or unsuccessful checks. The Mac may have connected earlier; that start is unknown. Periodic checks cannot prove uninterrupted access between probes.")
        }
    }
    private var connections: some View {
        DisclosureGroup(isExpanded: $model.connectionDetailsExpanded) {
            VStack(spacing: 8) {
                ForEach(model.connectionDetails) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.kind.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(row.kind.label).font(.system(size: 13))
                        Spacer()
                        Text(row.down.map(Format.rate) ?? "—")
                            .foregroundStyle(TrafficPalette.windowDownloadColor).frame(width: 80, alignment: .trailing)
                        Text(row.up.map(Format.rate) ?? "—")
                            .foregroundStyle(TrafficPalette.windowUploadColor).frame(width: 80, alignment: .trailing)
                    }.font(.system(size: 12).monospacedDigit())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.kind.label), download \(row.down.map(Format.rate) ?? "unobserved"), upload \(row.up.map(Format.rate) ?? "unobserved")")
                        .help(row.interfaces.joined(separator: ", ") + ": " + row.status + (row.kind.isOverlay ? ". Tunnel bytes, separate from physical totals; the same traffic is also counted on the physical link." : row.kind.isLocal ? ". Direct link to a nearby device." : ". Actual network interface counters."))
                }
            }.padding(.top, 10)
        } label: {
            HStack {
                Text("Connections").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(model.connectionDetails.map { $0.kind.label }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help("Live rates for links in use right now. A link appears while it has an address or carries traffic. Tunnel rates never add to physical totals.")
    }
    private func rate(_ title: String, symbol: String, value: Double, color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            let parts = Format.rateParts(value)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.rateAvailable ? parts.number : "—")
                    .font(.system(size: 40, weight: .semibold).monospacedDigit()).foregroundStyle(color)
                if model.rateAvailable { Text(parts.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel("\(title) \(model.rateAvailable ? Format.rate(value) : "unobserved")")
        }
    }
    private func stat(_ title: String, _ value: String, color: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Native header controls keep stable targets and accessibility during live sampling.
struct PanelDragRegion: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }
    func updateNSView(_ view: PanelDragView, context: Context) {
        view.enabled = enabled
        view.toolTip = enabled ? "Drag to move Current" : nil
    }
}
final class PanelDragView: NSView {
    var enabled = false
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.performDrag(with: event)
    }
}
struct PanelPinButton: NSViewRepresentable {
    let pinned: Bool
    let choose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: nil)!,
            target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false; button.setButtonType(.momentaryChange)
        button.focusRingType = .exterior
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.choose = choose
        if button.tag != (pinned ? 1 : 0) {
            button.tag = pinned ? 1 : 0
            button.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        }
        button.contentTintColor = pinned ? .labelColor : .secondaryLabelColor
        button.toolTip = pinned ? "Unpin Current" : "Keep Current visible while using other apps"
        button.setAccessibilityLabel(pinned ? "Unpin window" : "Pin window")
        button.setAccessibilityValue(pinned ? "Pinned" : "Unpinned")
    }
    @MainActor final class Coordinator: NSObject {
        var choose: () -> Void
        init(choose: @escaping () -> Void) { self.choose = choose }
        @objc func clicked() { choose() }
    }
}
struct PanelSettingsButton: NSViewRepresentable {
    let settings: () -> Void
    let about: () -> Void
    let quit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(settings: settings, about: about, quit: quit) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        let icon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil); menu.addItem(icon)
        for (title, action, key) in [("Settings…", #selector(Coordinator.openSettings), ","),
                                     ("About Current", #selector(Coordinator.openAbout), ""),
                                     ("Quit Current", #selector(Coordinator.exit), "q")] {
            if title == "Quit Current" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = context.coordinator; menu.addItem(item)
        }
        button.menu = menu
        button.setAccessibilityLabel("Current settings"); button.toolTip = "Current settings"
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.settings = settings; context.coordinator.about = about; context.coordinator.quit = quit
    }
    @MainActor final class Coordinator: NSObject {
        var settings: () -> Void, about: () -> Void, quit: () -> Void
        init(settings: @escaping () -> Void, about: @escaping () -> Void, quit: @escaping () -> Void) {
            self.settings = settings; self.about = about; self.quit = quit
        }
        @objc func openSettings() { settings() }
        @objc func openAbout() { about() }
        @objc func exit() { quit() }
    }
}

struct HistoryView: View {
    @ObservedObject var model: MonitorModel
    @State private var days = 30
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your traffic, over time").font(.title2.weight(.semibold))
                    Text("Measured traffic includes your local network. Days below use UTC.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Export") {
                    Button("CSV…") { model.export(backup: false) }
                    Button("SQLite backup…") { model.export(backup: true) }
                }
            }
            HStack {
                Picker("History type", selection: $tab) {
                    Text("Daily totals").tag(0); Text("Connection events").tag(1)
                }.pickerStyle(.segmented).frame(width: 280)
                Spacer()
                if tab == 0 {
                    Picker("Period", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("Year").tag(365); Text("All").tag(0)
                    }.frame(width: 150)
                }
            }
            if tab == 0 {
                HStack(spacing: 12) {
                    summary("Downloaded", value: Format.bytes(model.historyRows.reduce(0) { $0 + $1.summary.received }), color: TrafficPalette.windowDownloadColor)
                    summary("Uploaded", value: Format.bytes(model.historyRows.reduce(0) { $0 + $1.summary.sent }), color: TrafficPalette.windowUploadColor)
                    summary("Confirmed downtime", value: Format.duration(model.historyRows.reduce(0) { $0 + $1.summary.offline }))
                }
                Table(model.historyRows) {
                    TableColumn("Day · UTC") { row in Text(utcDay(row.start)) }
                    TableColumn("Download") { row in Text(Format.bytes(row.summary.received)).monospacedDigit().foregroundStyle(TrafficPalette.windowDownloadColor) }
                    TableColumn("Upload") { row in Text(Format.bytes(row.summary.sent)).monospacedDigit().foregroundStyle(TrafficPalette.windowUploadColor) }
                    TableColumn("Peak ↓") { row in Text(Format.rate(row.summary.peakDown)).monospacedDigit().foregroundStyle(TrafficPalette.windowDownloadColor) }
                    TableColumn("Peak ↑") { row in Text(Format.rate(row.summary.peakUp)).monospacedDigit().foregroundStyle(TrafficPalette.windowUploadColor) }
                    TableColumn("Offline") { row in Text(Format.duration(row.summary.offline)) }
                    TableColumn("Asleep / app off / missing") { row in Text("\(Format.duration(row.summary.sleep)) / \(Format.duration(row.summary.appGap)) / \(Format.duration(row.summary.unobserved))") }
                }
                .overlay { if model.historyRows.isEmpty { ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line", description: Text("Current saves the first batch within a minute.")) } }
            } else {
                List(model.recentEvents) { event in
                    HStack(alignment: .top) {
                        Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 155, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.kind.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 12, weight: .medium))
                            Text(event.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Peaks are observed rates, not connection capacity. Sleep, app gaps and missing readings have no measured traffic. Events show the most recent 100 entries; exports include all retained events.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 790, minHeight: 480)
        .background(TrafficPalette.surfaceColor)
        .task { model.flush(); await model.loadHistory(days: days) }
        .onChange(of: days) { _, value in Task { await model.loadHistory(days: value) } }
    }
    private func utcDay(_ start: Int64) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, yyyy"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(start)))
    }
    private func summary(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).panelCard()
    }
}

/// Speed test with live progress, plain-language results and a data warning on metered links.
struct SpeedTestCard: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        switch model.speedTestPhase {
        case .confirmMetered: confirm
        case .running(let since): running(since)
        case .idle, .failed: summary
        }
    }
    private func title(_ text: String, symbol: String, pulsing: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolEffect(.pulse, isActive: pulsing)
            Text(text)
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
    private var confirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            title(model.meteredInterface != nil ? "You're on a hotspot" : "Connection type not confirmed yet", symbol: "personalhotspot")
            Text(model.speedTestDataNote)
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.cancelSpeedTest() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Test anyway") { model.requestSpeedTest() }.buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func running(_ since: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Testing your connection…", symbol: "speedometer", pulsing: true)
            TimelineView(.periodic(from: since, by: 0.25)) { context in
                ProgressView(value: min(0.97, context.date.timeIntervalSince(since) / 14)).progressViewStyle(.linear)
            }
            Text("The live numbers above show the test as it runs.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                title("Speed test", symbol: "speedometer")
                if let result = model.lastSpeedTest {
                    Text(Calendar.current.isDateInToday(result.end) ? result.end.formatted(date: .omitted, time: .shortened)
                         : result.end.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(model.lastSpeedTest == nil ? "Run test" : "Run again") { model.requestSpeedTest() }
                    .buttonStyle(QuietButtonStyle())
                    .help(model.meteredInterface != nil ? "You're on a hotspot. Current asks before using data." : "Measures download, upload and responsiveness with Apple's servers. Data use grows with connection speed.")
            }
            if let result = model.lastSpeedTest {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    speed(result.download, direction: "Download", symbol: "arrow.down", color: TrafficPalette.windowDownloadColor)
                    speed(result.upload, direction: "Upload", symbol: "arrow.up", color: TrafficPalette.windowUploadColor)
                    Spacer()
                    if let snappiness = result.snappiness {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(snappiness.label).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(snappiness == .snappy ? TrafficPalette.reachableColor : snappiness == .sluggish ? Color.orange : Color.primary)
                            Text("\(Int(result.workingLatency ?? 0)) ms under load").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.help(snappiness.detail)
                    }
                }
                Text(result.verdicts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Download, upload and responsiveness, measured with Apple's servers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = model.speedTestPhase {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func speed(_ bits: Double, direction: String, symbol: String, color: Color) -> some View {
        let text = SpeedTestResult.bits(bits), parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(parts.first ?? text).font(.system(size: 20, weight: .semibold).monospacedDigit())
            if parts.count > 1 { Text(parts[1]).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondary) }
        }.foregroundStyle(color)
        .accessibilityElement(children: .ignore).accessibilityLabel("Speed test \(direction.lowercased()) \(text)")
    }
}
