import SwiftUI
import AppKit
import TrafficCore

struct RateGraph: View {
    let chart: PeriodChart
    let title: String
    private var observations: [GraphPoint] { chart.points }
    var height: CGFloat = 128
    private var measuredPeak: Double { observations.filter(\.hasMeasurements).map { max($0.peakDown, $0.peakUp) }.max() ?? 0 }
    private var maximum: Double { GraphScale.upperBound(measuredPeak) }
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title.uppercased()).lineLimit(1).font(.system(size: 10, weight: .medium)).tracking(0.8)
                Spacer()
            }.foregroundStyle(.secondary)
            HStack(spacing: 8) {
                VStack(alignment: .trailing) {
                    Text(Format.rate(maximum)); Spacer()
                    Text(Format.rate(maximum / 2)); Spacer()
                    Text("0")
                }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 52, height: height, alignment: .trailing)
                Canvas { context, size in
                let start = chart.start
                let span = max(1, chart.end.timeIntervalSince(start))
                for index in 0...2 {
                    var line = Path()
                    let y = size.height * CGFloat(index) / 2
                    line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                }
                for observation in observations where observation.hasGap {
                    let x = max(0, observation.start.timeIntervalSince(start) / span) * size.width
                    let width = min(size.width - x, observation.end.timeIntervalSince(observation.start) / span * size.width)
                    if width > 0 {
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.secondary.opacity(0.09)))
                    }
                }
                for (upload, ink) in [(false, TrafficPalette.windowDownloadColor), (true, TrafficPalette.windowUploadColor)] {
                    var path = Path(); var previous: GraphPoint?
                    for observation in observations {
                        guard observation.hasMeasurements else { previous = nil; continue }
                        let x = max(0, observation.end.timeIntervalSince(start) / span) * size.width
                        let y = size.height - CGFloat((upload ? observation.peakUp : observation.peakDown) / maximum) * (size.height - 4)
                        let joinsPrevious = previous.map { !$0.hasGap && !observation.hasGap && observation.start.timeIntervalSince($0.end) < 0.001 } ?? false
                        if joinsPrevious {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else { path.move(to: CGPoint(x: x, y: y)) }
                        if !joinsPrevious || observation.hasGap {
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(ink))
                        }
                        previous = observation
                    }
                    context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
                .frame(height: height)
            }
            .help("\(title). Peaks grouped into approximately \(Format.duration(chart.resolution)) bins; older retained summaries have coarser timing. Shaded bins include unrecorded, sleeping or app-off time; lines do not bridge those gaps. Clipped-bin peaks are upper bounds. Longer ranges refresh with saved history about once a minute.")
            .accessibilityLabel("\(title). Download and upload use their selected colors. Shaded gaps are unrecorded, sleeping or app gaps. Selected-range measured peak \(Format.rate(measuredPeak)).")
        }
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
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack {
                    Text("Current").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    if model.lowPower { Text("Low power").font(.system(size: 12)).foregroundStyle(.secondary) }
                }.overlay { if !renderingPreview { PanelDragRegion(enabled: pinned) } }
                if renderingPreview {
                    Image(systemName: "pin").frame(width: 28, height: 28)
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                } else {
                    PanelPinButton(pinned: pinned) {
                        pinned.toggle(); setPinned(pinned)
                    }.frame(width: 28, height: 28)
                    PanelSettingsButton(settings: showSettings, about: showAbout, quit: quit)
                        .frame(width: 28, height: 28)
                }

            }
            HStack(alignment: .top, spacing: 24) {
                rate("Download", symbol: "arrow.down", value: model.down, color: TrafficPalette.windowDownloadColor)
                Spacer(minLength: 0)
                rate("Upload", symbol: "arrow.up", value: model.up, color: TrafficPalette.windowUploadColor)
            }
            RateGraph(chart: model.displayedChart, title: model.period.title)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.period.title).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    if model.periodHistory != nil {
                        Text("Peak \(model.displayedPeakIsUpperBound ? "≤ " : "")\(Format.rate(model.displayedPeak))")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .help(model.displayedPeakIsUpperBound ? "An upper bound from a clipped history bucket; the exact peak time is no longer retained." : "Highest observed download or upload rate in the selected period, not connection capacity.")
                    }
                }.frame(height: 17)
                if let history = model.periodHistory {
                    HStack {
                        total("Downloaded", value: history.summary.received, color: TrafficPalette.windowDownloadColor)
                        Spacer()
                        total("Uploaded", value: history.summary.sent, color: TrafficPalette.windowUploadColor)
                    }
                    if history.summary.appGap > 5 || history.summary.sleep > 5 || history.summary.unobserved > 5 || history.boundaryEstimated {
                        Text("Incomplete coverage").font(.system(size: 11)).foregroundStyle(.secondary)
                            .help("Saved through \(history.savedThrough?.formatted(date: .abbreviated, time: .standard) ?? "no observations"). \(Format.duration(history.summary.sleep)) asleep; \(Format.duration(history.summary.appGap)) app off; \(Format.duration(history.summary.unobserved)) missing. Partial-bucket totals may be estimated.")
                    }
                } else {
                    Text(model.periodLoading ? "Loading saved totals…" : "Saved totals unavailable")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 48)
                }
            }.frame(height: 106, alignment: .top)
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(model.health.color).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.health.label).font(.system(size: 12, weight: .medium))
                    if model.checkInProgress || model.checkPending {
                        Text(model.checkInProgress ? "Checking now…" : "Check queued…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let checked = model.lastChecked {
                        Text("Last check \(checked.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(model.probesEnabled ? "Waiting for a check" : "Passive traffic monitoring continues")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Observed online").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.connectedDuration.map(Format.connectionDuration) ?? "—")
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityLabel(model.connectedDuration.map { "Current continuously observed online interval \(Format.connectionDuration($0)). Earlier connection start unknown." } ?? "Online interval unverified. Earlier connection start unknown.")
                .help("Current uninterrupted observation window supported by fresh successful internet checks. Resets after app restart, sleep, missing or stale samples, path changes or unsuccessful checks. The Mac may have connected earlier; that start is unknown. Periodic checks cannot prove uninterrupted access between probes.")
            }
            if !model.connectionDetails.isEmpty {
            DisclosureGroup(isExpanded: $model.connectionDetailsExpanded) {
                VStack(spacing: 9) {
                    ForEach(model.connectionDetails) { row in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.kind.label).font(.system(size: 13, weight: .medium))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.down.map(Format.rate) ?? "—")
                                .foregroundStyle(TrafficPalette.windowDownloadColor).frame(width: 88, alignment: .trailing)
                            Text(row.up.map(Format.rate) ?? "—")
                                .foregroundStyle(TrafficPalette.windowUploadColor).frame(width: 88, alignment: .trailing)
                        }.font(.system(size: 12).monospacedDigit())
                            .accessibilityLabel("\(row.kind.label), download \(row.down.map(Format.rate) ?? "unobserved"), upload \(row.up.map(Format.rate) ?? "unobserved")")
                            .help(row.interfaces.joined(separator: ", ") + ": " + row.status + (row.kind.isOverlay ? ". Bytes through the verified Tailscale tunnel, separate from physical totals. May include tailnet, subnet or exit-node routes; does not quantify all protected internet traffic." : ". Actual network interface counters."))
                    }
                }.padding(.top, 8)
            } label: {
                HStack {
                    Text("Connections").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(model.connectionDetails.filter { !$0.interfaces.isEmpty && $0.kind != .vpn }.map { $0.kind.label }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help("Current rates by verified network interface. Bluetooth appears only with valid PAN samples; Tailscale requires unique local-client attribution. Tunnel rates never add to physical totals.")
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: showHistory) { Label("History", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).help("View history stored on this Mac")
                Spacer()
                HStack(spacing: 2) {
                    ForEach(HistoryPeriod.allCases, id: \.self) { period in
                        Button { model.selectPeriod(period) } label: {
                            Text(period.rawValue).font(.system(size: 12, weight: model.period == period ? .semibold : .regular))
                                .frame(width: period == .all ? 68 : 38, height: 28)
                                .background(model.period == period ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                        .accessibilityLabel("Show \(period.title.lowercased())")
                        .accessibilityAddTraits(model.period == period ? [.isSelected] : [])
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("History period")
                Spacer()

            }.font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(30).frame(width: 460)
        .background(TrafficPalette.surfaceColor)
    }
    private func rate(_ title: String, symbol: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            let parts = Format.rateParts(value)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.rateAvailable ? parts.number : "—")
                    .font(.system(size: 34, weight: .medium).monospacedDigit()).foregroundStyle(color)
                if model.rateAvailable { Text(parts.unit).font(.system(size: 14)).foregroundStyle(.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel("\(title) \(model.rateAvailable ? Format.rate(value) : "unobserved")")
        }
    }
    private func total(_ title: String, value: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.bytes(value)).font(.system(size: 24, weight: .medium).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.system(size: 12)).foregroundStyle(color)
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
                HStack(spacing: 30) {
                    summary("Downloaded", value: Format.bytes(model.historyRows.reduce(0) { $0 + $1.summary.received }), color: TrafficPalette.windowDownloadColor)
                    summary("Uploaded", value: Format.bytes(model.historyRows.reduce(0) { $0 + $1.summary.sent }), color: TrafficPalette.windowUploadColor)
                    summary("Confirmed downtime", value: Format.duration(model.historyRows.reduce(0) { $0 + $1.summary.offline }))
                }.padding(.vertical, 8)
                Table(model.historyRows) {
                    TableColumn("Day · UTC") { row in Text(utcDay(row.start)) }
                    TableColumn("Download") { row in Text(Format.bytes(row.summary.received)).monospacedDigit().foregroundStyle(TrafficPalette.windowDownloadColor) }
                    TableColumn("Upload") { row in Text(Format.bytes(row.summary.sent)).monospacedDigit().foregroundStyle(TrafficPalette.windowUploadColor) }
                    TableColumn("Peak ↓") { row in Text(Format.rate(row.summary.peakDown)).monospacedDigit().foregroundStyle(TrafficPalette.windowDownloadColor) }
                    TableColumn("Peak ↑") { row in Text(Format.rate(row.summary.peakUp)).monospacedDigit().foregroundStyle(TrafficPalette.windowUploadColor) }
                    TableColumn("Offline") { row in Text(Format.duration(row.summary.offline)) }
                    TableColumn("Sleep / app / gaps") { row in Text("\(Format.duration(row.summary.sleep)) / \(Format.duration(row.summary.appGap)) / \(Format.duration(row.summary.unobserved))") }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.medium).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.system(size: 11)).foregroundStyle(color)
        }
    }
}
