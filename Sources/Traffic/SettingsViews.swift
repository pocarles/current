import AppKit
import SwiftUI

struct SettingsPane: View {
    @ObservedObject var model: MonitorModel
    let tab: SettingsTab
    var showHistory: () -> Void
    var body: some View {
        Form {
            switch tab {
            case .general: general
            case .appearance: appearance
            case .history: history
            case .about: about
            }
            if let error = model.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.visible)
    }
    private func row(_ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func footer(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var general: some View {
        Section {
            LabeledContent {
                SettingsSwitch(title: "Internet checks", value: model.probesEnabled, choose: model.setProbes)
            } label: { row("Internet checks", "Confirms real internet access, even when Wi-Fi stays connected.") }
            LabeledContent {
                SettingsSwitch(title: "Outage and recovery notifications", value: model.noticesEnabled, choose: model.setNotifications)
            } label: { row("Outage alerts", "Notifies you when the internet drops and when it's back.") }
        } header: { Text("Monitoring") } footer: {
            footer("Each check asks Google, then Cloudflare, for an empty page every 30 seconds (2 minutes in Low Power Mode). Both see your public IP address. Two failed checks at least 5 seconds apart confirm an outage.")
        }
        Section {
            LabeledContent("Measured by", value: "Apple networkQuality")
            LabeledContent("Last test used", value: model.lastSpeedTest.map { Format.bytes($0.bytesUsed) } ?? "No test yet")
        } header: { Text("Speed test") } footer: {
            footer("Tests run only when you ask, at full speed for about 12 seconds, so faster connections use more data. On a phone hotspot or other metered connection, Current asks first.")
        }
    }
    @ViewBuilder private var appearance: some View {
        Section {
            LabeledContent("Window") {
                SettingsModePicker(mode: model.appearance.mode) {
                    var value = model.appearance; value.mode = $0; model.setAppearance(value)
                }.frame(width: 240, height: 24)
            }
            HStack(spacing: 12) {
                PalettePreview(theme: model.appearance.lightTheme, dark: false)
                PalettePreview(theme: model.appearance.darkTheme, dark: true)
            }.padding(.vertical, 4)
        } header: { Text("Mode") }
        paletteSection(dark: false)
        paletteSection(dark: true)
    }
    private func paletteSection(dark: Bool) -> some View {
        let selected = dark ? model.appearance.darkTheme : model.appearance.lightTheme
        return Section {
            HStack(spacing: 10) {
                ForEach(TrafficColorTheme.allCases, id: \.self) { theme in
                    PaletteChoice(theme: theme, dark: dark, selected: theme == selected) {
                        var value = model.appearance
                        if dark { value.darkTheme = theme } else { value.lightTheme = theme }
                        model.setAppearance(value)
                    }.frame(maxWidth: .infinity).frame(height: 58)
                }
            }.padding(.vertical, 4)
        } header: {
            Label(dark ? "Dark colors" : "Light colors", systemImage: dark ? "moon" : "sun.max")
        } footer: {
            if dark {
                HStack {
                    Spacer()
                    Button("Reset Appearance") { model.setAppearance(.defaults) }
                        .help("Restore System mode and Washed colors for light and dark.")
                }
            }
        }
    }
    @ViewBuilder private var history: some View {
        Section {
            LabeledContent("Minute detail", value: "7 days")
            LabeledContent("Hourly detail", value: "180 days")
            LabeledContent("Daily totals", value: "100 years")
        } header: { Text("Kept on this Mac") } footer: {
            footer("History never leaves this Mac. Older detail is folded into coarser summaries, so totals stay exact.")
        }
        Section {
            LabeledContent {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataURL]) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Location")
                    Text(model.dataURL.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(model.dataURL.path)
                }
            }
            HStack(spacing: 8) {
                Button("Open History", action: showHistory)
                Spacer()
                Button("Export CSV…") { model.export(backup: false) }.help("Export daily totals and retained events.")
                Button("Back Up…") { model.export(backup: true) }.help("Save all retained history as a SQLite database.")
            }
        } header: { Text("Your data") } footer: {
            footer("To restore a backup, quit Current and keep a copy of the current database and its -wal and -shm files before replacing it. Replacing it can lose newer history.")
        }
    }
    // Outside the app bundle (tests, `swift run`) the main bundle belongs to another program.
    private var version: String {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Current" else { return "0.1.0" }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
    @ViewBuilder private var about: some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").foregroundStyle(TrafficPalette.windowDownloadColor)
                    Image(systemName: "arrow.up").foregroundStyle(TrafficPalette.windowUploadColor)
                }
                .font(.system(size: 26, weight: .semibold)).frame(width: 72, height: 72)
                .background(Color(nsColor: TrafficPalette.surface), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                Text("Current").font(.system(size: 22, weight: .semibold))
                Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Live traffic, internet health and speed, right in your menu bar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        Section {
            LabeledContent("Author", value: "Pierre-Olivier Carles")
            LabeledContent("License", value: "MIT")
            LabeledContent("Source") {
                Link("github.com/pocarles/current", destination: URL(string: "https://github.com/pocarles/current")!)
            }
            LabeledContent("Updates") {
                Link("Releases on GitHub", destination: URL(string: "https://github.com/pocarles/current/releases")!)
            }
        } footer: { footer("© 2026 Pierre-Olivier Carles. Current has no account, analytics or automatic updater.") }
    }
}

/// A native switch keeps keyboard, VoiceOver and accessibility-press behavior.
struct SettingsSwitch: NSViewRepresentable {
    let title: String
    let value: Bool
    let choose: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }
    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.target = context.coordinator; control.action = #selector(Coordinator.changed(_:))
        control.controlSize = .small
        control.setAccessibilityLabel(title)
        return control
    }
    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.choose = choose
        let state = value ? NSControl.StateValue.on : .off
        if control.state != state { control.state = state }
    }
    @MainActor final class Coordinator: NSObject {
        var choose: (Bool) -> Void
        init(choose: @escaping (Bool) -> Void) { self.choose = choose }
        @objc func changed(_ control: NSSwitch) { choose(control.state == .on) }
    }
}

struct SettingsModePicker: NSViewRepresentable {
    let mode: TrafficAppearanceMode
    let choose: (TrafficAppearanceMode) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: TrafficAppearanceMode.allCases.map(\.title), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.setAccessibilityLabel("Window mode")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = choose
        let index = TrafficAppearanceMode.allCases.firstIndex(of: mode)!
        if control.selectedSegment != index { control.selectedSegment = index }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 280, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var choose: (TrafficAppearanceMode) -> Void
        init(choose: @escaping (TrafficAppearanceMode) -> Void) { self.choose = choose }
        @objc func changed(_ control: NSSegmentedControl) {
            guard TrafficAppearanceMode.allCases.indices.contains(control.selectedSegment) else { return }
            choose(TrafficAppearanceMode.allCases[control.selectedSegment])
        }
    }
}

/// A real AppKit button gives palette choices native focus, Space activation
/// and accessibility actions without relying on live menu tracking.
struct PaletteChoice: NSViewRepresentable {
    let theme: TrafficColorTheme
    let dark: Bool
    let selected: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> PaletteChoiceButton { PaletteChoiceButton() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PaletteChoiceButton, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 80, height: 58)
    }
    func updateNSView(_ button: PaletteChoiceButton, context: Context) {
        button.theme = theme; button.dark = dark; button.chosen = selected; button.invoke = action
        button.title = theme.title
        button.setAccessibilityLabel("\(dark ? "Dark" : "Light") colors, \(theme.title)")
        button.toolTip = "Use \(theme.title) in \(dark ? "dark" : "light") appearance"
        button.needsDisplay = true
    }
}
@MainActor final class PaletteChoiceButton: NSButton {
    var theme = TrafficColorTheme.washed
    var dark = false, chosen = false
    var invoke: (() -> Void)?
    init() {
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryChange)
        focusRingType = .exterior; target = self; action = #selector(choose)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func choose() { invoke?() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityValue() -> Any? { chosen ? "Selected" : "" }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        TrafficPalette.resolvedSurface(dark: dark, theme: theme).setFill(); shape.fill()
        (chosen ? NSColor.controlAccentColor : (dark ? NSColor.white : .black).withAlphaComponent(0.12)).setStroke()
        shape.lineWidth = chosen ? 2.5 : 0.6; shape.stroke()
        if isHighlighted { NSColor.labelColor.withAlphaComponent(0.05).setFill(); shape.fill() }
        let ink = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1)
        let titleTop: CGFloat = 8, chartHeight = max(10, bounds.height * 0.32)
        (theme.title as NSString).draw(at: NSPoint(x: 9, y: isFlipped ? titleTop : bounds.height - titleTop - 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: ink])
        for (upload, heights) in [(false, [0.15, 0.3, 0.24, 0.72, 0.4, 0.5]), (true, [0.08, 0.15, 0.12, 0.25, 0.2, 0.3])] {
            let path = NSBezierPath()
            for (index, height) in heights.enumerated() {
                let rise = 8 + height * chartHeight
                let point = NSPoint(x: 9 + CGFloat(index) / 5 * (bounds.width - 18), y: isFlipped ? bounds.height - rise : rise)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            TrafficPalette.resolved(upload: upload, increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                dark: dark, theme: theme).setStroke()
            path.lineWidth = 1.5; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
        }
    }
}

struct PalettePreview: View {
    let theme: TrafficColorTheme
    let dark: Bool
    static func ink(_ theme: TrafficColorTheme, dark: Bool, upload: Bool) -> Color {
        Color(nsColor: TrafficPalette.resolved(upload: upload,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, dark: dark, theme: theme))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                previewRate("↓", "842", upload: false)
                Spacer(minLength: 5)
                previewRate("↑", "125", upload: true)
            }
            Canvas { context, size in
                for (upload, heights) in [(false, [0.75, 0.55, 0.62, 0.16, 0.5, 0.35]), (true, [0.9, 0.82, 0.9, 0.75, 0.82, 0.72])] {
                    var path = Path()
                    for (index, height) in heights.enumerated() {
                        let point = CGPoint(x: CGFloat(index) / 5 * size.width, y: height * size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(Self.ink(theme, dark: dark, upload: upload)),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }.frame(height: 34).accessibilityHidden(true)
        }.padding(14).background(Color(nsColor: TrafficPalette.resolvedSurface(dark: dark, theme: theme)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: dark ? .white : .black).opacity(0.08), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample preview, \(dark ? "dark" : "light") \(theme.title), download 842 kilobytes per second, upload 125 kilobytes per second")
    }
    private func previewRate(_ arrow: String, _ value: String, upload: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(arrow).font(.system(size: 11, weight: .medium))
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text("KB/s").font(.system(size: 11)).foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
        }.foregroundStyle(Self.ink(theme, dark: dark, upload: upload))
    }
}
