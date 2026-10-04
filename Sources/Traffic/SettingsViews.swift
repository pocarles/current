import AppKit
import SwiftUI

struct SettingsPane: View {
    @ObservedObject var model: MonitorModel
    let tab: SettingsTab
    var showHistory: () -> Void
    var body: some View {
        ScrollView { content }
        .background(Color(nsColor: .windowBackgroundColor))
        .font(.system(size: 15))
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 28) {
                switch tab {
                case .general: general
                case .appearance: appearance
                case .history: history
                case .about: about
                }
                if let error = model.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 28, weight: .semibold))
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var general: some View {
        Group {
            heading("General")
            card {
                SettingsCheckbox(title: "Internet checks", value: model.probesEnabled, choose: model.setProbes)
                    .frame(height: 24)
                    .help("Check internet access even when Wi-Fi stays connected.")
                Divider()
                SettingsCheckbox(title: "Outage and recovery notifications", value: model.noticesEnabled, choose: model.setNotifications)
                    .frame(height: 24)
                note("Requires macOS notification permission.")
            }
            DisclosureGroup("Connection check privacy") {
                note("Google and Cloudflare receive your public IP. Checks run every 30 seconds (120 in Low Power Mode), with a 5-second timeout. Two failed checks confirm an outage.")
                    .padding(.top, 8)
            }.font(.system(size: 12))
        }
    }
    private var appearance: some View {
        Group {
            heading("Appearance")
            HStack(spacing: 20) {
                Text("Window mode").fontWeight(.medium).fixedSize()
                SettingsModePicker(mode: model.appearance.mode) {
                    var value = model.appearance; value.mode = $0; model.setAppearance(value)
                }.frame(width: 360, height: 28)
            }
            HStack(alignment: .top, spacing: 16) {
                paletteCard(dark: false)
                paletteCard(dark: true)
            }
            HStack {
                Spacer(minLength: 12)
                Button("Reset appearance") { model.setAppearance(.defaults) }
                    .help("Restore System mode and Washed colors for light and dark.")
            }
        }
    }
    private func paletteCard(dark: Bool) -> some View {
        let selected = dark ? model.appearance.darkTheme : model.appearance.lightTheme
        return card {
            HStack {
                Image(systemName: dark ? "moon" : "sun.max").foregroundStyle(.secondary)
                Text(dark ? "Dark colors" : "Light colors").fontWeight(.medium)
            }
            PalettePreview(theme: selected, dark: dark)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(TrafficColorTheme.allCases, id: \.self) { theme in
                    PaletteChoice(theme: theme, dark: dark, selected: theme == selected) {
                        var value = model.appearance
                        if dark { value.darkTheme = theme } else { value.lightTheme = theme }
                        model.setAppearance(value)
                    }.frame(maxWidth: .infinity).frame(height: 74)
                }
            }

        }
    }
    private var history: some View {
        Group {
            heading("History")
            card {
                HStack(spacing: 16) {
                    retention("7 days", "Minute summaries")
                    Divider()
                    retention("180 days", "Hourly summaries")
                    Divider()
                    retention("100 years", "Daily summaries")
                }.frame(height: 46)
            }
            card {
                HStack {
                    Label("History files", systemImage: "externaldrive").fontWeight(.medium)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataURL]) }
                }
                Text(model.dataURL.deletingLastPathComponent().path)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    .help(model.dataURL.path)
                Divider()
                HStack(spacing: 10) {
                    Button("Open history", action: showHistory)
                    Spacer()
                    Button("Export CSV…") { model.export(backup: false) }
                        .help("Export daily totals and retained events.")
                    Button("Back up…") { model.export(backup: true) }
                        .help("Save all retained history as a SQLite database.")
                }
            }
            DisclosureGroup("Restore a backup") {
                note("Quit Current. Preserve the current database and its WAL sidecars before replacing it with your backup. Replacement can lose newer history.").padding(.top, 8)
            }.font(.system(size: 12))
        }
    }
    private func retention(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var about: some View {
        Group {
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").foregroundStyle(TrafficPalette.windowDownloadColor)
                    Image(systemName: "arrow.up").foregroundStyle(TrafficPalette.windowUploadColor)
                }.font(.system(size: 24, weight: .medium)).frame(width: 64, height: 64)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current").font(.system(size: 30, weight: .semibold))
                    note("Version 0.1.0")
                }
            }
            card {
                LabeledContent("Author", value: "Pierre-Olivier Carles")
                Divider()
                LabeledContent("License", value: "MIT")
                Divider()
                Text("© 2026 Pierre-Olivier Carles").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Check for Updates") {}.disabled(true)
                .help("Automatic updates are not configured.")
        }
    }

}

struct SettingsCheckbox: NSViewRepresentable {
    let title: String
    let value: Bool
    let choose: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.choose = choose
        let state = value ? NSControl.StateValue.on : .off
        if button.state != state { button.state = state }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var choose: (Bool) -> Void
        init(choose: @escaping (Bool) -> Void) { self.choose = choose }
        @objc func changed(_ button: NSButton) { choose(button.state == .on) }
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
        NSSize(width: proposal.width ?? 200, height: 74)
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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        TrafficPalette.resolvedSurface(dark: dark, theme: theme).setFill(); shape.fill()
        (chosen ? NSColor.controlAccentColor : (dark ? NSColor.white : .black).withAlphaComponent(0.12)).setStroke()
        shape.lineWidth = chosen ? 2 : 0.7; shape.stroke()
        if isHighlighted { NSColor.labelColor.withAlphaComponent(0.05).setFill(); shape.fill() }
        let ink = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1)
        (theme.title as NSString).draw(at: NSPoint(x: 12, y: isFlipped ? 10 : bounds.height - 25),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ink])
        if chosen {
            ("✓" as NSString).draw(at: NSPoint(x: bounds.width - 23, y: isFlipped ? 10 : bounds.height - 25),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.controlAccentColor])
        }
        for (upload, heights) in [(false, [0.15, 0.3, 0.24, 0.72, 0.4, 0.5]), (true, [0.08, 0.15, 0.12, 0.25, 0.2, 0.3])] {
            let path = NSBezierPath()
            for (index, height) in heights.enumerated() {
                let point = NSPoint(x: 12 + CGFloat(index) / 5 * (bounds.width - 24), y: isFlipped ? bounds.height - 10 - height * 26 : 10 + height * 26)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            TrafficPalette.resolved(upload: upload, increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                dark: dark, theme: theme).setStroke()
            path.lineWidth = 1.5; path.lineJoinStyle = .round; path.stroke()
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
            }.frame(height: 44).accessibilityHidden(true)
        }.padding(18).background(Color(nsColor: TrafficPalette.resolvedSurface(dark: dark, theme: theme)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: dark ? .white : .black).opacity(0.08), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample preview, \(dark ? "dark" : "light") \(theme.title), download 842 kilobytes per second, upload 125 kilobytes per second")
    }
    private func previewRate(_ arrow: String, _ value: String, upload: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(arrow).font(.system(size: 11, weight: .medium))
            Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text("KB/s").font(.system(size: 11)).foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
        }.foregroundStyle(Self.ink(theme, dark: dark, upload: upload))
    }
}
