import AppKit
import SwiftUI

/// Owns only the ephemeral menu-bar panel. AppKit handles outside interactions,
/// including its native exceptions for menus and auxiliary panels.
@MainActor
final class MenuPopover: NSObject, NSPopoverDelegate, NSWindowDelegate {
    let popover = NSPopover()
    var onClose: (() -> Void)?
    private let activate: () -> Void
    private var activationObserver: NSObjectProtocol?
    private(set) var isPinned = false
    private weak var anchor: NSView?
    private var transferringContent = false
    private var floatingContent: FloatingContentController?
    private(set) var pinnedWindow: NSPanel?
    var contentController: NSViewController? { floatingContent?.content ?? popover.contentViewController }
    var visibleWindow: NSWindow? { pinnedWindow ?? popover.contentViewController?.view.window }
    var appearance: NSAppearance? { didSet { applyAppearance() } }
    private func applyAppearance() {
        contentController?.view.appearance = appearance
        visibleWindow?.appearance = appearance
    }

    init(activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.activate = activate
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    var isShown: Bool { pinnedWindow?.isVisible == true || popover.isShown }

    func show<Content: View>(_ content: Content, relativeTo anchor: NSView) {
        self.anchor = anchor
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.applicationActivated(processIdentifier: application.processIdentifier, modalWindow: NSApp.modalWindow)
                }
            }
        }
        activate()
        let content = content.focusable().focusEffectDisabled()
            .onExitCommand { [weak self] in self?.close() }
        popover.contentViewController = EscapeHostingController(rootView: content) { [weak self] in self?.close() }
        applyAppearance()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        applyAppearance()
        // A status button can be clicked while another app is active. Give this
        // panel keyboard focus so Escape reaches the normal responder chain.
        focus()
    }

    func focus() {
        guard isShown else { return }
        visibleWindow?.makeKeyAndOrderFront(nil)
    }

    func setPinned(_ pinned: Bool) {
        guard isShown, pinned != isPinned else { return }
        if pinned {
            guard let controller = popover.contentViewController, let source = controller.view.window else { return }
            let frame = source.convertToScreen(controller.view.convert(controller.view.bounds, to: nil))
            // Move the existing hosted content, preserving disclosure and pin
            // state. A regular panel has no positioning-view constraint.
            transferringContent = true
            popover.close()
            popover.contentViewController = nil
            let container = FloatingContentController(content: controller, size: frame.size)
            let window = PinnedTrafficPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.title = "Current"; window.isReleasedWhenClosed = false
            window.level = .floating; window.isFloatingPanel = true
            window.hidesOnDeactivate = false; window.isMovable = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true
            window.contentViewController = container; window.delegate = self
            window.setFrame(frame, display: false)
            floatingContent = container; pinnedWindow = window; isPinned = true
            transferringContent = false
            applyAppearance(); window.makeKeyAndOrderFront(nil)
        } else {
            guard let anchor, anchor.window != nil, let container = floatingContent else { close(); return }
            transferringContent = true
            let controller = container.releaseContent()
            pinnedWindow?.delegate = nil; pinnedWindow?.close()
            pinnedWindow?.contentViewController = nil
            pinnedWindow = nil; floatingContent = nil; isPinned = false
            popover.contentViewController = controller
            applyAppearance()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            transferringContent = false
            applyAppearance(); focus()
        }
    }

    func close() {
        guard isShown, NSApp.modalWindow == nil else { return }
        if let window = pinnedWindow {
            window.delegate = nil; window.close(); window.contentViewController = nil
            finishClose()
        } else { popover.performClose(nil) }
    }

    func applicationResignedActive(modalWindow: NSWindow?) {
        // A save dialog has its own lifetime and keyboard handling.
        guard modalWindow == nil, !isPinned else { return }
        close()
    }

    func applicationActivated(processIdentifier: pid_t, modalWindow: NSWindow?) {
        // Also covers app switches when an accessory panel opened before
        // Traffic finished activating. No mouse or keyboard capture is needed.
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        applicationResignedActive(modalWindow: modalWindow)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { !isPinned && NSApp.modalWindow == nil }

    func popoverDidClose(_ notification: Notification) {
        guard !transferringContent else { return }
        finishClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === pinnedWindow else { return }
        pinnedWindow?.contentViewController = nil
        finishClose()
    }

    private func finishClose() {
        isPinned = false; popover.behavior = .transient
        pinnedWindow = nil; floatingContent = nil; anchor = nil
        // Release SwiftUI content between opens, including the Escape closure.
        popover.contentViewController = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        onClose?()
    }
}

@MainActor private final class PinnedTrafficPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) {
        guard NSApp.modalWindow == nil else { return }
        close()
    }
}

/// Keeps the top edge and chosen screen position when Connections changes height.
@MainActor private final class FloatingContentController: NSViewController {
    let content: NSViewController
    init(content: NSViewController, size: NSSize) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true; view.layer?.cornerRadius = 12; view.layer?.masksToBounds = true
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.width, .height]
        view.addSubview(content.view)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === content, let window = view.window else { return }
        let size = content.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let top = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }
    func releaseContent() -> NSViewController {
        content.view.removeFromSuperview(); content.removeFromParent()
        return content
    }
}

@MainActor
final class EscapeHostingController<Content: View>: NSHostingController<Content> {
    private let dismiss: () -> Void
    init(rootView: Content, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        super.init(rootView: rootView)
        sizingOptions = [.preferredContentSize]
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("Not used") }

    // Menus, text controls and save dialogs get their normal first opportunity
    // to consume Escape. This handles cancellation that reaches the panel.
    override func cancelOperation(_ sender: Any?) { dismiss() }
}
