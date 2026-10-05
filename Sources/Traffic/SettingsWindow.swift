import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Sendable {
    case general, appearance, history, about
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .general: "switch.2"; case .appearance: "paintpalette"; case .history: "clock.arrow.circlepath"; case .about: "info.circle" }
    }
}

/// Settings has its own lifetime. Closing the transient status panel cannot
/// close this window, and closing Settings releases all hosted content.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: MonitorModel
    private let showHistory: () -> Void
    private let activate: () -> Void
    private let frameAutosaveName: String?
    private(set) var window: NSWindow?
    private(set) var tabs: NSTabViewController?
    static let contentSize = NSSize(width: 620, height: 600)
    private var lastTab = SettingsTab.general
    init(model: MonitorModel, showHistory: @escaping () -> Void, frameAutosaveName: String? = "TrafficSettings",
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.model = model; self.showHistory = showHistory; self.activate = activate
        self.frameAutosaveName = frameAutosaveName
    }
    func show(tab: SettingsTab? = nil) {
        guard NSApp.modalWindow == nil else { NSApp.modalWindow?.makeKeyAndOrderFront(nil); return }
        if window == nil { createWindow() }
        if let tab { select(tab) }
        guard let window else { return }
        window.appearance = model.appearance.mode.nsAppearance
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); activate()
    }
    var selectedTab: SettingsTab {
        guard let tabs else { return lastTab }
        return SettingsTab.allCases[tabs.selectedTabViewItemIndex]
    }
    func select(_ tab: SettingsTab) {
        lastTab = tab
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab)!
    }
    func applyAppearance() {
        window?.appearance = model.appearance.mode.nsAppearance
        window?.backgroundColor = .windowBackgroundColor
    }
    private func createWindow() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentSize.width, height: Self.contentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Current Settings"; window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.delegate = self; window.tabbingMode = .disallowed
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar; tabs.transitionOptions = []
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for tab in SettingsTab.allCases {
            let content = SettingsPane(model: model, tab: tab, showHistory: showHistory)
                .onExitCommand { [weak self] in
                    guard NSApp.modalWindow == nil else { return }
                    self?.window?.performClose(nil)
                }
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = []
            controller.preferredContentSize = NSSize(width: Self.contentSize.width, height: Self.contentSize.height)
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title; item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: lastTab)!
        self.tabs = tabs; self.window = window
        tabs.preferredContentSize = NSSize(width: Self.contentSize.width, height: Self.contentSize.height)
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: Self.contentSize.width, height: Self.contentSize.height))
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            if !window.setFrameUsingName(frameAutosaveName) { window.center() }
        } else { window.center() }
        let restored = window.contentRect(forFrameRect: window.frame).size
        if restored.width < window.contentMinSize.width || restored.height < window.contentMinSize.height {
            window.setContentSize(NSSize(width: max(restored.width, window.contentMinSize.width),
                                         height: max(restored.height, window.contentMinSize.height)))
        }
        window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: false)
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        lastTab = selectedTab
        window?.contentViewController = nil; window?.contentView = nil; window?.toolbar = nil
        window?.delegate = nil; window = nil; tabs = nil
    }
}

@MainActor private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        guard NSApp.modalWindow == nil else { return }
        performClose(sender)
    }
}

@MainActor enum TrafficApplicationMenu {
    static func make(target: AnyObject, settings: Selector, about: Selector) -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu(title: "Current")
        func action(_ title: String, _ selector: Selector, _ key: String = "", target receiver: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = receiver; return item
        }
        app.addItem(action("About Current", about, target: target))
        app.addItem(.separator())
        app.addItem(action("Settings…", settings, ",", target: target))
        app.addItem(.separator())
        app.addItem(action("Hide Current", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        let hideOthers = action("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]; app.addItem(hideOthers)
        app.addItem(action("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(action("Quit Current", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(action(title, NSSelectorFromString(selector), key))
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        let windows = NSMenu(title: "Window")
        windows.addItem(action("Close", #selector(NSWindow.performClose(_:)), "w"))
        windows.addItem(action("Minimize", #selector(NSWindow.miniaturize(_:)), "m"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowItem.submenu = windows; menu.addItem(windowItem)
        return menu
    }
}
