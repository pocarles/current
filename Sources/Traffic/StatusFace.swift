import AppKit
import TrafficCore

/// Menu-only rounding. Full rates remain available in the tooltip and popover.
struct StatusRate: Equatable {
    let number: String
    let unit: String
    static let unobserved = StatusRate(number: "—", unit: "")

    init(_ bytesPerSecond: Double) {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { self = .unobserved; return }
        let units = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
        var scaled = bytesPerSecond, index = 0
        while scaled >= 1000, index < units.count - 1 { scaled /= 1000; index += 1 }
        // Even an unexpected rate beyond 999 EB/s must fit without clipping.
        if scaled >= 999.5, index == units.count - 1 {
            self.init(number: String(format: "%.0e", locale: Locale(identifier: "en_US_POSIX"), bytesPerSecond)
                .replacingOccurrences(of: "E+", with: "e")
                .replacingOccurrences(of: "e+", with: "e"), unit: "B/s")
            return
        }
        if scaled >= 999.5, index < units.count - 1 { scaled /= 1000; index += 1 }
        let decimals = index > 0 && scaled < 9.95 ? 1 : 0
        self.init(number: String(format: decimals == 1 ? "%.1f" : "%.0f",
                                locale: Locale(identifier: "en_US_POSIX"), scaled), unit: units[index])
    }

    private init(number: String, unit: String) { self.number = number; self.unit = unit }
}

@MainActor
final class StatusFace: NSView {
    static let width: CGFloat = 64
    static let textRight: CGFloat = 54
    static let textLeft: CGFloat = 11
    var down = StatusRate.unobserved, up = StatusRate.unobserved
    var health: ConnectionHealth = .checking
    var menuAppearanceName: NSAppearance.Name = .aqua
    private var popoverOpen = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); rememberUnselectedAppearance()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !popoverOpen { rememberUnselectedAppearance() }
        needsDisplay = true
    }
    private func rememberUnselectedAppearance() {
        // A highlighted status button can temporarily change its descendants'
        // appearance before the click action opens the panel. Keep the last
        // unselected view appearance, including menu-bar vibrancy.
        guard (superview as? NSStatusBarButton)?.isHighlighted != true else { return }
        menuAppearanceName = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }
    static func ink(_ color: NSColor, appearance name: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                // Freeze components here; a converted dynamic color can still
                // resolve again under AppKit's selected drawing appearance.
                resolved = NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
            }
        }
        return resolved
    }

    // The NSStatusBarButton owns click handling and the complete accessibility label.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    static func text(_ rate: StatusRate, color: NSColor = .white) -> NSAttributedString {
        let text = NSMutableAttributedString(string: rate.number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: color
        ])
        text.append(NSAttributedString(string: rate.unit, attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: color
        ]))
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        // Center the two baselines in both standard and taller menu bars.
        let bottom = (bounds.height - 24) / 2 + 1
        for (arrow, rate, y) in [("↓", down, bottom + 11), ("↑", up, bottom)] {
            let color = NSColor.white
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: color]
            (arrow as NSString).draw(at: NSPoint(x: 3, y: y), withAttributes: attributes)
            let text = Self.text(rate, color: color)
            text.draw(at: NSPoint(x: Self.textRight - text.size().width, y: y))
        }
        Self.ink(health.nsColor, appearance: menuAppearanceName).setFill()
        NSBezierPath(ovalIn: NSRect(x: 57, y: bounds.midY - 2, width: 4, height: 4)).fill()
    }

    func update(_ model: MonitorModel) {
        if !model.popoverOpen { rememberUnselectedAppearance() }
        popoverOpen = model.popoverOpen
        let down = model.rateAvailable ? StatusRate(model.down) : .unobserved
        let up = model.rateAvailable ? StatusRate(model.up) : .unobserved
        if self.down != down || self.up != up || health != model.health {
            self.down = down; self.up = up; health = model.health; needsDisplay = true
        }
    }
}
