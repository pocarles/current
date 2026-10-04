import XCTest
import AppKit
import SwiftUI
@testable import Traffic

@MainActor final class SettingsTests: XCTestCase {
    private func native() throws {
        guard ProcessInfo.processInfo.environment["TRAFFIC_NATIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Native Settings checks require the connected Mac window server.")
        }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    }
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
    private func model(_ name: String) -> MonitorModel {
        MonitorModel(automatic: false, preferences: UserDefaults(suiteName: name)!, probe: { .success })
    }
    // AppKit's reparenting proxies expose the legacy in-process accessibility
    // API rather than declaring the modern protocol. No external AX client or
    // system permission is used; every node belongs to this fixture window.
    private func find(_ label: String, in root: Any) -> NSObject? {
        var queue: [Any] = [root], seen = Set<ObjectIdentifier>(), inspected = 0
        while !queue.isEmpty && inspected < 1024 {
            let value = queue.removeFirst(); inspected += 1
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = object as? any NSAccessibilityProtocol
            let title = node?.accessibilityLabel() ?? object.accessibilityAttributeValue(.description) as? String
                ?? object.accessibilityAttributeValue(.title) as? String
            if title == label { return object }
            let children = node?.accessibilityChildren() ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
            queue.append(contentsOf: children)
            if let window = object as? NSWindow, let view = window.contentView { queue.append(view) }
            if let view = object as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }
    private func press(_ object: NSObject) {
        if let node = object as? any NSAccessibilityProtocol { _ = node.accessibilityPerformPress() }
        else { object.accessibilityPerformAction(.press) }
    }
    func testSettingsMenuHasStandardShortcutAndNoConfigurationSubmenus() {
        _ = NSApplication.shared
        let target = SettingsMenuTarget()
        let menu = TrafficApplicationMenu.make(target: target, settings: #selector(SettingsMenuTarget.settings), about: #selector(SettingsMenuTarget.about))
        let app = menu.items[0].submenu!
        XCTAssertEqual(app.title, "Current")
        XCTAssertNotNil(app.item(withTitle: "About Current"))
        XCTAssertNotNil(app.item(withTitle: "Quit Current"))
        let settings = app.item(withTitle: "Settings…")!
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertNil(settings.submenu)
        app.performActionForItem(at: app.index(of: settings))
        XCTAssertEqual(target.calls, 1)
    }
    func testNativeWindowReusesStableFrameAcrossTabsAndReleasesOnClose() throws {
        try native()
        let name = "org.traffic.settings-native.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let model = model(name), controller = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: nil)
        defer { controller.window?.close() }
        for _ in 0..<3 {
            weak var releasedContent: NSTabViewController?
            autoreleasepool {
                controller.show(); pump(); pump()
                let window = controller.window!, baseline = window.frame
                XCTAssertEqual(window.title, "Current Settings")
                releasedContent = controller.tabs
                XCTAssertNotNil(window.toolbar, "Preferences tabs must use a native toolbar")
                XCTAssertEqual(window.frame.width, 820, accuracy: 1)
                for tab in SettingsTab.allCases {
                    controller.select(tab); pump()
                    XCTAssertEqual(controller.selectedTab, tab)
                    XCTAssertEqual(window.frame, baseline, "Switching tabs must keep the window still")
                    controller.show(); pump()
                    XCTAssertTrue(controller.window === window, "Repeated Settings must reuse one window")
                }
                window.setContentSize(NSSize(width: 900, height: 750)); pump()
                let resized = window.frame
                for tab in SettingsTab.allCases { controller.select(tab); pump(); XCTAssertEqual(window.frame, resized) }
                print("SETTINGS_NATIVE frame=\(baseline) tabs=4 key=\(window.isKeyWindow) toolbar=\(window.toolbar?.items.map(\.label) ?? [])")
                window.performClose(nil); pump()
                XCTAssertNil(controller.window); XCTAssertNil(controller.tabs)
                XCTAssertFalse(window.isVisible)
            }
            pump()
            XCTAssertNil(releasedContent, "Closed hosted content must be released after AppKit's autorelease pool drains")
            controller.show(); pump()
            XCTAssertEqual(controller.selectedTab, .about, "Keep the last tab within the app session")
            controller.window?.close(); pump()
        }
        XCTAssertTrue(model.probesEnabled); XCTAssertFalse(model.noticesEnabled)
    }
    func testNativePalettePressesAndModeChangesPersistAndKeepWindowOpen() throws {
        try native()
        let name = "org.traffic.settings-controls.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let model = model(name), controller = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: nil)
        let previous = NSApp.appearance, previousPalette = TrafficPalette.settings
        defer { model.onAppearanceChange = nil; controller.window?.close(); NSApp.appearance = previous; TrafficPalette.apply(previousPalette) }
        model.onAppearanceChange = {
            Task { @MainActor in
                NSApp.appearance = model.appearance.mode.nsAppearance
                TrafficPalette.apply(model.appearance); controller.applyAppearance()
            }
        }
        controller.show(tab: .appearance); pump(); pump()
        let window = try XCTUnwrap(controller.window)
        for theme in TrafficColorTheme.allCases {
            for dark in [false, true] {
                let label = "\(dark ? "Dark" : "Light") colors, \(theme.title)"
                press(try XCTUnwrap(find(label, in: window))); pump()
                XCTAssertEqual(dark ? model.appearance.darkTheme : model.appearance.lightTheme, theme)
                XCTAssertTrue(window.isVisible)
            }
        }
        model.setAppearance(.defaults); pump()
        for _ in 0..<3 {
            for (label, light, dark) in [("Light colors, Matrix", TrafficColorTheme.forest, TrafficColorTheme.washed),
                                       ("Dark colors, Ember", .forest, .ember),
                                       ("Light colors, Washed", .washed, .ember),
                                       ("Dark colors, Washed", .washed, .washed)] {
                let control = try XCTUnwrap(find(label, in: window), "The visible color choice must be accessible: \(label)")
                press(control); pump()
                XCTAssertEqual(model.appearance.lightTheme, light); XCTAssertEqual(model.appearance.darkTheme, dark)
                XCTAssertTrue(window.isVisible)
            }
        }
        for mode in [TrafficAppearanceMode.dark, .light, .system, .dark, .system] {
            let control = try XCTUnwrap(find(mode.title, in: window), "Mode must be exposed to keyboard/accessibility")
            press(control); pump()
            XCTAssertEqual(model.appearance.mode, mode)
            XCTAssertEqual(window.appearance?.name, mode.nsAppearance?.name)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            XCTAssertTrue(window.isVisible)
        }
        let keyboardChoice = try XCTUnwrap(find("Light colors, Matrix", in: window) as? NSView)
        XCTAssertTrue(window.makeFirstResponder(keyboardChoice))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(space); pump()
        XCTAssertEqual(model.appearance.lightTheme, .forest)
        let relaunch = self.model(name)
        XCTAssertEqual(relaunch.appearance, model.appearance)
        XCTAssertTrue(model.probesEnabled); XCTAssertFalse(model.noticesEnabled)
        print("SETTINGS_CONTROLS palette_presses=22 mode_presses=5 keyboard_space=true persisted=true window_stayed_open=true")
    }
    func testNativeSettingsRetainsSavedSizeAcrossCloseAndNewController() throws {
        try native()
        let name = "org.traffic.settings-frame.\(UUID())", frameName = "TrafficSettingsTest-\(UUID())"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name); NSWindow.removeFrame(usingName: frameName) }
        let model = model(name), first = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: frameName)
        first.show(); pump(); pump()
        let window = try XCTUnwrap(first.window)
        window.setContentSize(NSSize(width: 940, height: 790)); pump()
        let frame = window.frame
        window.saveFrame(usingName: frameName)
        window.close(); pump()
        let reopened = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: frameName)
        defer { reopened.window?.close() }
        reopened.show(); pump(); pump()
        XCTAssertEqual(reopened.window?.frame.width ?? 0, frame.width, accuracy: 1)
        XCTAssertEqual(reopened.window?.frame.height ?? 0, frame.height, accuracy: 1)
    }
    func testCommandCommaEscapeAndPopoverDismissalPreserveOtherWindowsAndModal() throws {
        try native()
        let name = "org.traffic.settings-events.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let controller = SettingsWindowController(model: model(name), showHistory: {}, frameAutosaveName: nil)
        defer { controller.window?.close() }
        let target = SettingsMenuTarget(); target.onSettings = { controller.show() }
        let menu = TrafficApplicationMenu.make(target: target, settings: #selector(SettingsMenuTarget.settings), about: #selector(SettingsMenuTarget.about))
        for _ in 0..<3 {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0,
                context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
            XCTAssertTrue(menu.performKeyEquivalent(with: event)); pump()
            XCTAssertTrue(controller.window?.isVisible ?? false)
        }
        let window = try XCTUnwrap(controller.window)
        let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 64, height: 24))
        window.contentView?.addSubview(anchor)
        let panel = MenuPopover(); defer { panel.close() }
        panel.show(Text("Independent panel").frame(width: 180, height: 100), relativeTo: anchor); pump()
        panel.applicationActivated(processIdentifier: -1, modalWindow: nil); pump()
        XCTAssertFalse(panel.isShown); XCTAssertTrue(window.isVisible)
        let dialog = NSPanel(contentRect: NSRect(x: 20, y: 20, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        dialog.isReleasedWhenClosed = false
        defer { dialog.close() }
        let session = NSApp.beginModalSession(for: dialog); _ = NSApp.runModalSession(session)
        window.cancelOperation(nil)
        XCTAssertTrue(window.isVisible, "Escape must not close Settings behind a modal dialog")
        let previousTab = controller.selectedTab
        controller.show(tab: .appearance)
        XCTAssertEqual(controller.selectedTab, previousTab, "Settings must preserve the modal interaction instead of switching tabs")
        XCTAssertTrue(NSApp.modalWindow === dialog)
        NSApp.endModalSession(session); dialog.close()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); pump()
        guard NSApp.isActive, window.isKeyWindow else { throw XCTSkip("Execution host cannot deliver native keys") }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape); pump()
        XCTAssertNil(controller.window)
        controller.show(); pump(); XCTAssertTrue(controller.window?.isVisible ?? false)
        print("SETTINGS_EVENTS command_comma=3 escape=true reopened=true modal_preserved=true panel_independent=true")
    }
    func testGeneralCheckControlPersistsWithoutEnablingNotifications() throws {
        try native()
        let name = "org.traffic.settings-general.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let model = model(name), controller = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: nil)
        defer { controller.window?.close() }
        controller.show(tab: .general); pump(); pump()
        let window = try XCTUnwrap(controller.window)
        for enabled in [false, true, false, true] {
            let check = try XCTUnwrap(find("Internet checks", in: window))
            press(check); pump()
            XCTAssertEqual(model.probesEnabled, enabled)
            XCTAssertEqual(self.model(name).probesEnabled, enabled)
            XCTAssertFalse(model.noticesEnabled)
            XCTAssertTrue(window.isVisible)
        }
        print("SETTINGS_GENERAL check_toggles=4 persisted=true notifications_untouched=true mock_probe=true")
    }
    func testCaptureOwnNativeSettingsWindow() throws {
        try native()
        guard let path = ProcessInfo.processInfo.environment["TRAFFIC_SETTINGS_NATIVE_PREVIEW_DIR"] else { throw XCTSkip("Set TRAFFIC_SETTINGS_NATIVE_PREVIEW_DIR for own-window renders.") }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "org.traffic.settings-window-preview.\(UUID())", model = model(name)
        let previous = NSApp.appearance, previousPalette = TrafficPalette.settings
        let controller = SettingsWindowController(model: model, showHistory: {}, frameAutosaveName: nil)
        defer { controller.window?.close(); NSApp.appearance = previous; TrafficPalette.apply(previousPalette); UserDefaults.standard.removePersistentDomain(forName: name) }
        for dark in [false, true] {
            model.setAppearance(.init(mode: dark ? .dark : .light)); NSApp.appearance = model.appearance.mode.nsAppearance
            TrafficPalette.apply(model.appearance)
            for tab in SettingsTab.allCases {
                controller.show(tab: tab); controller.applyAppearance(); pump(); pump()
                let view = try XCTUnwrap(controller.window?.contentView?.superview)
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 820)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("settings-native-\(tab.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        for theme in TrafficColorTheme.allCases where theme != .washed {
            for dark in [false, true] {
                model.setAppearance(.init(mode: dark ? .dark : .light, lightTheme: theme, darkTheme: theme))
                NSApp.appearance = model.appearance.mode.nsAppearance; TrafficPalette.apply(model.appearance)
                controller.show(tab: .appearance); controller.applyAppearance(); pump(); pump()
                let view = try XCTUnwrap(controller.window?.contentView?.superview)
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("settings-native-appearance-\(dark ? "dark" : "light")-\(theme.rawValue).png"))
            }
        }
    }
}

@MainActor private final class SettingsMenuTarget: NSObject {
    var calls = 0
    var onSettings: (() -> Void)?
    @objc func settings() { calls += 1; onSettings?() }
    @objc func about() {}
}
