import AppKit
import SwiftUI
import TrafficCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = MonitorModel()
    private var status: NSStatusItem!
    private let face = StatusFace(frame: NSRect(x: 0, y: 0, width: StatusFace.width, height: 24))
    private let menuPopover = MenuPopover()
    private var historyWindow: NSWindow?
    private lazy var settings = SettingsWindowController(model: model, showHistory: { [weak self] in self?.showHistory() })
    private var appearanceObservation: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: StatusFace.width)
        if let button = status.button {
            face.frame = button.bounds; face.autoresizingMask = [.width, .height]
            button.addSubview(face); button.target = self; button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Current network monitor")
        }
        menuPopover.onClose = { [weak self] in
            guard let self else { return }
            self.model.popoverOpen = false
            self.updateStatus()
            self.profileUI("popover_closed")
        }
        model.onStatusChange = { [weak self] in self?.updateStatus() }
        model.onAppearanceChange = { [weak self] in
            // Finish the control's action before AppKit changes appearances.
            Task { @MainActor [weak self] in self?.applyAppearance() }
        }
        NSApp.mainMenu = TrafficApplicationMenu.make(target: self, settings: #selector(showSettings), about: #selector(showAbout))
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        applyAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateSystemAppearance() }
        }
        model.start(); updateStatus(); profileUI("started")
        if CommandLine.arguments.contains("--show") {
            Task { try? await Task.sleep(for: .seconds(2)); togglePopover() }
        }
        if CommandLine.arguments.contains("--settings") {
            Task { try? await Task.sleep(for: .seconds(2)); settings.show(tab: .appearance); profileUI("settings_shown") }
        }
        if let value = ProcessInfo.processInfo.environment["TRAFFIC_PROFILE_SETTINGS_CLOSE_AFTER"],
           let seconds = Double(value), seconds >= 5 {
            Task { try? await Task.sleep(for: .seconds(seconds)); settings.window?.performClose(nil); profileUI("settings_closed") }
        }
        if let value = ProcessInfo.processInfo.environment["TRAFFIC_PROFILE_CLOSE_AFTER"],
           let seconds = Double(value), seconds >= 5 {
            Task { try? await Task.sleep(for: .seconds(seconds)); menuPopover.close() }
        }
        if let value = ProcessInfo.processInfo.environment["TRAFFIC_PROFILE_REFRESH_AFTER"],
           let seconds = Double(value), seconds >= 5 {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                model.refreshConnectivity(); profileUI("refresh_requested")
                if let check = model.checkConnectivity() { await check.value; profileUI("refresh_completed") }
            }
        }
    }
    private func updateStatus() {
        face.update(model)
        let text = "Download \(model.rateAvailable ? Format.rate(model.down) : "unobserved"), upload \(model.rateAvailable ? Format.rate(model.up) : "unobserved"). \(model.health.label)."
        status.button?.toolTip = text
        status.button?.setAccessibilityLabel("Current. " + text)
    }
    private func applyAppearance() {
        TrafficPalette.apply(model.appearance)
        NSApp.appearance = model.appearance.mode.nsAppearance
        let resolved = model.appearance.mode.nsAppearance ?? NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        historyWindow?.appearance = model.appearance.mode.nsAppearance
        historyWindow?.backgroundColor = TrafficPalette.surface
        settings.applyAppearance()
        menuPopover.appearance = resolved
        updateStatus()
        face.needsDisplay = true
    }
    private func updateSystemAppearance() {
        guard model.appearance.mode == .system else { return }
        menuPopover.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        updateStatus()
    }
    @objc private func togglePopover() {
        guard NSApp.modalWindow == nil else { NSApp.modalWindow?.makeKeyAndOrderFront(nil); return }
        if menuPopover.isShown { menuPopover.close(); return }
        guard let button = status.button else { return }
        updateSystemAppearance()
        let view = PopoverView(model: model, showHistory: { [weak self] in self?.showHistory() },
            showSettings: { [weak self] in self?.showSettings() }, showAbout: { [weak self] in self?.showAbout() }, quit: { NSApp.terminate(nil) }, setPinned: { [weak self] in self?.menuPopover.setPinned($0) })
        model.popoverOpen = true
        updateStatus()
        menuPopover.show(view, relativeTo: button)
        profileUI("popover_shown")
        Task { _ = await model.flushAndWait(); if model.periodHistory == nil { await model.loadPeriod() } }
    }
    func applicationDidResignActive(_ notification: Notification) {
        menuPopover.applicationResignedActive(modalWindow: NSApp.modalWindow)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        // Activation is asynchronous when a status button belongs to an
        // inactive accessory app. Finish focus after AppKit activates it.
        menuPopover.focus()
        if status != nil { profileUI("activated") }
    }
    private func showHistory() {
        menuPopover.close()
        model.historyOpen = true
        if let historyWindow { historyWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 540), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Current History"; window.isReleasedWhenClosed = false; window.delegate = self
        window.appearance = model.appearance.mode.nsAppearance; window.backgroundColor = TrafficPalette.surface
        window.contentView = NSHostingView(rootView: HistoryView(model: model)); window.center()
        historyWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        profileUI("history_shown")
    }
    @objc private func showSettings() {
        menuPopover.close()
        settings.show(); profileUI("settings_shown")
    }
    @objc private func showAbout() {
        menuPopover.close()
        settings.show(tab: .about); profileUI("settings_about_shown")
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === historyWindow { historyWindow = nil; model.historyOpen = false; model.historyRows = []; model.recentEvents = [] }
        profileUI("window_closed")
    }
    private func profileUI(_ event: String) {
        guard ProcessInfo.processInfo.environment["TRAFFIC_PROFILE_UI"] == "1" else { return }
        // Observe only this app's own lifecycle. No screen capture or input automation.
        let time = ISO8601DateFormatter().string(from: Date())
        print("TRAFFIC_UI \(time) \(event) statusWidth=\(status.length) buttonWidth=\(status.button?.bounds.width ?? 0) popover=\(menuPopover.isShown) key=\(menuPopover.visibleWindow?.isKeyWindow ?? false) active=\(NSApp.isActive) history=\(historyWindow != nil) settings=\(settings.window != nil) settingsKey=\(settings.window?.isKeyWindow ?? false) menuAppearance=\(face.menuAppearanceName.rawValue) checking=\(model.checkInProgress) pending=\(model.checkPending) lastCheck=\(model.lastChecked.map { ISO8601DateFormatter().string(from: $0) } ?? "none") health=\(model.health.rawValue)")
        fflush(stdout)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never veto logout, restart or shutdown: save within a short bound, then quit regardless.
        let endingSession = Self.systemIsEndingSession()
        var replied = false
        let reply = { (allow: Bool) in
            guard !replied else { return }
            replied = true; sender.reply(toApplicationShouldTerminate: allow || endingSession)
        }
        model.prepareToQuit { saved in reply(saved) }
        if endingSession { Task { try? await Task.sleep(for: .seconds(3)); reply(true) } }
        return .terminateLater
    }
    private static func systemIsEndingSession() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = (event.attributeDescriptor(forKeyword: kAEQuitReason) ?? event.paramDescriptor(forKeyword: kAEQuitReason))?.enumCodeValue
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }
}

if CommandLine.arguments.contains("--notification-status") {
    // UNUserNotificationCenter traps outside an app bundle (for example `swift run`).
    guard Bundle.main.bundleIdentifier != nil else { fputs("Run --notification-status from Current.app.\n", stderr); exit(1) }
    // Read authorization only. This never requests permission or delivers a notification.
    let finished = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        let status: String
        switch settings.authorizationStatus {
        case .notDetermined: status = "not determined"
        case .denied: status = "denied"
        case .authorized: status = "authorized"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        print("authorization=\(status) alerts=\(settings.alertSetting.rawValue) notificationCenter=\(settings.notificationCenterSetting.rawValue)")
        finished.signal()
    }
    if finished.wait(timeout: .now() + 5) == .timedOut { fputs("Notification settings read timed out.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--connections") {
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        let inventory = await NetworkInventory.read(includeTailscale: true)
        do {
            let counters = try CounterReader.read()
            for detail in ConnectionDetail.make(counters: counters, rates: [], inventory: inventory) {
                print("\(detail.kind.label): \(detail.interfaces.joined(separator: ", ")) — \(detail.status)")
            }
        } catch { fputs("Cannot read connections: \(error)\n", stderr) }
        finished.signal()
    }
    if finished.wait(timeout: .now() + 5) == .timedOut { fputs("Connection inventory timed out.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--counters") {
    do {
        for counter in try CounterReader.read() {
            print("\(counter.name) \(counter.included ? "included" : "excluded") rx=\(counter.received) tx=\(counter.sent)")
        }
    } catch { fputs("Cannot read counters: \(error)\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
