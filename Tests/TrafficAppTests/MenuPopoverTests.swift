import XCTest
import AppKit
import SwiftUI
import TrafficCore
@testable import Traffic

@MainActor final class MenuPopoverTests: XCTestCase {
    private func fixture() throws -> (NSWindow, NSButton) {
        guard ProcessInfo.processInfo.environment["TRAFFIC_NATIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Set TRAFFIC_NATIVE_UI_TESTS=1 and run on the connected Mac window server.")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Traffic interaction test"
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 130, y: 80, width: 64, height: 24))
        window.contentView!.addSubview(anchor)
        window.orderFront(nil)
        return (window, anchor)
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    private func find(_ label: String, in root: Any) -> NSObject? {
        var queue: [Any] = [root], seen = Set<ObjectIdentifier>()
        while !queue.isEmpty && seen.count < 1024 {
            guard let object = queue.removeFirst() as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = object as? any NSAccessibilityProtocol
            if (node?.accessibilityLabel() ?? object.accessibilityAttributeValue(.description) as? String ?? object.accessibilityAttributeValue(.title) as? String) == label { return object }
            queue.append(contentsOf: node?.accessibilityChildren() ?? object.accessibilityAttributeValue(.children) as? [Any] ?? [])
            if let view = object as? NSView { queue.append(contentsOf: view.subviews) }
            if let window = object as? NSWindow, let view = window.contentView { queue.append(view) }
        }
        return nil
    }
    private func press(_ object: NSObject) {
        if let node = object as? any NSAccessibilityProtocol { _ = node.accessibilityPerformPress() }
        else { object.accessibilityPerformAction(.press) }
    }
    func testNativePinButtonPreservesPanelAcrossOutsideClickAndDeactivation() throws {
        let (window, anchor) = try fixture(); defer { window.close() }
        let name = "org.traffic.pin-test.\(UUID())", preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = MonitorModel(automatic: false, preferences: preferences)
        let now = Date()
        model.down = 842_000; model.up = 125_000; model.rateAvailable = true
        model.health = .online; model.lastChecked = now; model.connectedDuration = 1042
        var points: [GraphPoint] = []
        for index in 0..<30 {
            let start = now.addingTimeInterval(Double(index - 30) * 10)
            let end = now.addingTimeInterval(Double(index - 29) * 10)
            let peak: Double = 500_000 + Double(index % 7) * 100_000
            points.append(GraphPoint(start: start, end: end, peakDown: peak, peakUp: 125_000, hasMeasurements: true, hasGap: false))
        }
        model.graph = points
        var summary = HistorySummary(); summary.received = 1_500_000_000; summary.sent = 187_000_000; summary.peakDown = 1_100_000
        model.periodHistory = PeriodHistory(summary: summary, end: now, savedThrough: now, hasRecords: true)
        var settingsCalls = 0, aboutCalls = 0, quitCalls = 0
        let panel = MenuPopover(); defer { panel.close() }
        func open() {
            panel.show(PopoverView(model: model, showHistory: {}, showSettings: { settingsCalls += 1 }, showAbout: { aboutCalls += 1 },
                quit: { quitCalls += 1 }, setPinned: panel.setPinned), relativeTo: anchor)
            pump(); pump()
        }
        open()
        let popup = try XCTUnwrap(panel.popover.contentViewController?.view.window)
        let controller = try XCTUnwrap(panel.contentController)
        let ordinaryLevel = popup.level
        XCTAssertGreaterThan(popup.frame.width, 460)
        let settingsButton = try XCTUnwrap(find("Current settings", in: popup) as? NSPopUpButton)
        let menu = try XCTUnwrap(settingsButton.menu)
        for title in ["Settings…", "About Current", "Quit Current"] {
            menu.performActionForItem(at: menu.index(of: try XCTUnwrap(menu.item(withTitle: title))))
        }
        XCTAssertEqual(settingsCalls, 1); XCTAssertEqual(aboutCalls, 1); XCTAssertEqual(quitCalls, 1)
        XCTAssertNil(find("Refresh internet status", in: popup))
        func capture(_ suffix: String) throws {
            guard let path = ProcessInfo.processInfo.environment["TRAFFIC_PANEL_NATIVE_PREVIEW_DIR"] else { return }
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Capture our content; AppKit's compositor-owned popover shadow
            // cannot be reproduced reliably with cacheDisplay.
            let view = try XCTUnwrap(panel.contentController?.view)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("panel-native-\(suffix).png"))
        }
        try capture("unpinned")
        for _ in 0..<2 {
            press(try XCTUnwrap(find("Pin window", in: try XCTUnwrap(panel.visibleWindow)))); pump()
            XCTAssertTrue(panel.isPinned); XCTAssertFalse(panel.popover.isShown)
            XCTAssertEqual(panel.visibleWindow?.level, .floating)
            XCTAssertTrue(panel.contentController === controller)
            XCTAssertNotNil(find("Current settings", in: try XCTUnwrap(panel.visibleWindow)))
            var views = [controller.view]
            var dragHeader: PanelDragView?
            while let view = views.popLast() {
                if let header = view as? PanelDragView { dragHeader = header; break }
                views.append(contentsOf: view.subviews)
            }
            let header = try XCTUnwrap(dragHeader)
            XCTAssertTrue(header.enabled)
            XCTAssertTrue(header.window === panel.pinnedWindow)
            let point = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: panel.pinnedWindow?.contentView)
            XCTAssertTrue(panel.pinnedWindow?.contentView?.hitTest(point) === header, "Visible title area must receive dragging")
            try capture("pinned")
            panel.applicationActivated(processIdentifier: -1, modalWindow: nil); pump()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            pump(); XCTAssertTrue(panel.isShown, "Pinned panel must survive outside work")
            XCTAssertFalse(panel.popoverShouldClose(panel.popover))
            press(try XCTUnwrap(find("Unpin window", in: try XCTUnwrap(panel.visibleWindow)))); pump()
            XCTAssertFalse(panel.isPinned); XCTAssertEqual(panel.popover.behavior, .transient)
            XCTAssertEqual(panel.visibleWindow?.level, ordinaryLevel)
            XCTAssertTrue(panel.contentController === controller)
        }
        press(try XCTUnwrap(find("Pin window", in: try XCTUnwrap(panel.visibleWindow)))); pump()
        let floating = try XCTUnwrap(panel.visibleWindow)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: floating.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        floating.sendEvent(escape); pump()
        XCTAssertFalse(panel.isShown); XCTAssertFalse(panel.isPinned)
        open(); XCTAssertNotNil(find("Pin window", in: try XCTUnwrap(panel.popover.contentViewController?.view.window)))
        panel.applicationActivated(processIdentifier: -1, modalWindow: nil); pump(); XCTAssertFalse(panel.isShown)
        print("PIN_NATIVE presses=5 outside_click_preserved=true deactivation_preserved=true escape_closes=true reopen_unpinned=true")
    }

    func testPinnedWindowMovesAcrossConnectedScreensAndPreservesContentSizing() throws {
        let (window, anchor) = try fixture(); defer { window.close() }
        let state = DisclosureState(), panel = MenuPopover()
        var closes = 0; panel.onClose = { closes += 1 }
        panel.show(DisclosureContent(state: state), relativeTo: anchor); pump()
        let controller = try XCTUnwrap(panel.contentController)
        panel.setPinned(true); pump()
        let floating = try XCTUnwrap(panel.pinnedWindow)
        XCTAssertEqual(floating.title, "Current")
        XCTAssertTrue(floating.isMovable); XCTAssertFalse(floating.hidesOnDeactivate)
        XCTAssertTrue(floating.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(floating.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(closes, 0, "Pin transfer must retain the sampling/open lifetime")
        let screens = NSScreen.screens
        XCTAssertFalse(screens.isEmpty)
        for screen in screens {
            let origin = NSPoint(x: screen.visibleFrame.midX - floating.frame.width / 2,
                                 y: screen.visibleFrame.midY - floating.frame.height / 2)
            floating.setFrameOrigin(origin); pump()
            XCTAssertEqual(floating.frame.origin.x, origin.x, accuracy: 1)
            XCTAssertEqual(floating.frame.origin.y, origin.y, accuracy: 1)
            XCTAssertEqual(floating.screen, screen)
            let collapsed = floating.frame, top = floating.frame.maxY
            state.expanded = true; pump(); pump()
            XCTAssertGreaterThan(floating.frame.height, collapsed.height + 100)
            XCTAssertEqual(floating.frame.minX, origin.x, accuracy: 1)
            XCTAssertEqual(floating.frame.maxY, top, accuracy: 1)
            panel.appearance = NSAppearance(named: .darkAqua); pump()
            XCTAssertEqual(floating.frame.maxY, top, accuracy: 1)
            XCTAssertTrue(panel.contentController === controller)
            state.expanded = false; pump(); pump()
            XCTAssertEqual(floating.frame, collapsed)
        }
        panel.setPinned(false); pump()
        XCTAssertNil(panel.pinnedWindow); XCTAssertTrue(panel.popover.isShown)
        XCTAssertTrue(panel.contentController === controller); XCTAssertEqual(closes, 0)
        panel.setPinned(true); pump()
        panel.pinnedWindow?.performClose(nil); pump()
        XCTAssertFalse(panel.isShown); XCTAssertFalse(panel.isPinned); XCTAssertEqual(closes, 1)
        XCTAssertNil(panel.contentController); XCTAssertNil(panel.pinnedWindow)
        print("PIN_MOVE_NATIVE screens=\(screens.count) real_window_placement=true content_preserved=true disclosure_top_stable=true close_content_released=true")
    }

    func testTitleDragUsesNativeWindowDragOnlyWhenPinned() throws {
        _ = NSApplication.shared
        let window = DragRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                                         styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let header = PanelDragView(frame: NSRect(x: 0, y: 40, width: 150, height: 40))
        window.contentView!.addSubview(header)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 60),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNil(header.hitTest(NSPoint(x: 20, y: 60)))
        header.mouseDown(with: event); XCTAssertEqual(window.drags, 0)
        header.enabled = true
        XCTAssertNotNil(header.hitTest(NSPoint(x: 20, y: 60)))
        XCTAssertTrue(header.acceptsFirstMouse(for: event))
        header.mouseDown(with: event)
        XCTAssertEqual(window.drags, 1); XCTAssertTrue(window.dragEvent === event)
    }

    func testRepeatedShowEscapeAndReopen() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        var activations = 0, closes = 0
        let panel = MenuPopover(activate: { activations += 1; NSApp.activate(ignoringOtherApps: true) })
        panel.onClose = { closes += 1 }
        XCTAssertEqual(panel.popover.behavior, .transient)
        for _ in 0..<3 {
            panel.show(Text("Traffic test").frame(width: 200, height: 100), relativeTo: anchor)
            pump()
            XCTAssertTrue(panel.isShown)
            let popupWindow = try XCTUnwrap(panel.popover.contentViewController?.view.window)
            print("POPOVER_NATIVE shown=\(panel.isShown) key=\(popupWindow.isKeyWindow) active=\(NSApp.isActive)")
            // Exercise the native cancellation responder. Key-event delivery
            // has a separate test because an inactive test host cannot receive it.
            panel.popover.contentViewController?.cancelOperation(nil)
            pump()
            XCTAssertFalse(panel.isShown)
            XCTAssertNil(panel.popover.contentViewController)
        }
        XCTAssertEqual(activations, 3); XCTAssertEqual(closes, 3)
        panel.close(); XCTAssertEqual(closes, 3)
    }

    func testNativeEscapeKeyDeliveryWhenHostCanActivate() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let panel = MenuPopover()
        panel.show(Text("Traffic test").frame(width: 200, height: 100), relativeTo: anchor)
        defer { panel.close() }
        pump()
        let popupWindow = try XCTUnwrap(panel.popover.contentViewController?.view.window)
        guard NSApp.isActive, popupWindow.isKeyWindow else {
            throw XCTSkip("This execution host cannot activate/key its test application. Native Escape delivery is unverified.")
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popupWindow.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        popupWindow.sendEvent(escape); pump()
        XCTAssertFalse(panel.isShown)
    }

    func testProductionPanelKeepsFrameThroughRepeatedRangeLoadingAndDigitChanges() async throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-native-ranges-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("traffic.sqlite")), now = Date()
        try await store.record([Observation(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-1740), received: 100, peakDown: 102_000_000)], now: now)
        let model = MonitorModel(dataURL: directory.appendingPathComponent("traffic.sqlite"), repository: store,
            automatic: false, preferences: UserDefaults(suiteName: "org.traffic.native-ranges.\(UUID())")!, counters: { [] }, now: { now })
        await model.start().value; await model.loadPeriod()
        model.rateAvailable = true; model.down = 10; model.up = 10
        model.connectionDetails = [ConnectionDetail(kind: .wifi, interfaces: ["en0"], down: 0, up: 0)]
        let panel = MenuPopover()
        defer { panel.close() }
        panel.show(PopoverView(model: model, showHistory: {}, showSettings: {}, quit: {}), relativeTo: anchor)
        pump(); pump()
        let popup = try XCTUnwrap(panel.popover.contentViewController?.view.window)
        let baseline = popup.frame
        for iteration in 0..<3 {
            for period in HistoryPeriod.allCases {
                model.selectPeriod(period)
                model.down = iteration == 0 ? 1 : Double(UInt64.max); model.up = iteration == 2 ? 999_000_000 : 0
                pump()
                XCTAssertEqual(popup.frame.origin.x, baseline.origin.x, accuracy: 1)
                XCTAssertEqual(popup.frame.origin.y, baseline.origin.y, accuracy: 1)
                XCTAssertEqual(popup.frame.height, baseline.height, accuracy: 1)
                await model.loadPeriod(); pump(); pump()
                XCTAssertEqual(popup.frame, baseline, "\(period.rawValue) must not move or resize the native panel")
                XCTAssertTrue(panel.isShown)
            }
        }
        print("PERIOD_NATIVE_STABLE frame=\(baseline) switches=15 loading_and_loaded=true")
    }

    func testExplicitAppearanceReachesOpenPanelAndReopenedPanel() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let panel = MenuPopover()
        defer { panel.close() }
        panel.show(Text("Appearance fixture").frame(width: 240, height: 120), relativeTo: anchor)
        pump()
        for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua, .aqua] {
            panel.appearance = NSAppearance(named: name)
            pump()
            let controller = try XCTUnwrap(panel.popover.contentViewController)
            XCTAssertEqual(controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            XCTAssertEqual(controller.view.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            XCTAssertTrue(panel.isShown)
        }
        panel.close(); pump()
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.show(Text("Reopened appearance").frame(width: 240, height: 120), relativeTo: anchor)
        pump()
        XCTAssertEqual(panel.popover.contentViewController?.view.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    func testDisclosureResizesNativePanelAndReopens() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let panel = MenuPopover(), state = DisclosureState()
        defer { panel.close() }
        panel.show(DisclosureContent(state: state), relativeTo: anchor)
        pump()
        let collapsed = panel.popover.contentSize.height
        state.expanded = true
        pump(); pump()
        let expanded = panel.popover.contentSize.height
        print("DISCLOSURE_NATIVE collapsed=\(collapsed) expanded=\(expanded)")
        XCTAssertGreaterThan(expanded, collapsed + 100)
        XCTAssertTrue(panel.isShown)
        state.expanded = false
        pump(); pump()
        XCTAssertEqual(panel.popover.contentSize.height, collapsed, accuracy: 2)
        panel.close(); pump()
        state.expanded = true
        panel.show(DisclosureContent(state: state), relativeTo: anchor)
        pump(); pump()
        XCTAssertEqual(panel.popover.contentSize.height, expanded, accuracy: 2)
    }

    func testInsideControlAndOutsideNativeMouseEvent() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let panel = MenuPopover()
        let control = TestButton(frame: NSRect(x: 0, y: 0, width: 180, height: 36))
        panel.show(ButtonContent(button: control).frame(width: 220, height: 100), relativeTo: anchor)
        defer { panel.close() }
        pump()
        control.performClick(nil)
        XCTAssertEqual(control.clicks, 1)
        XCTAssertTrue(panel.isShown)
        // Deliver an outside click to the fixture window through AppKit's event
        // queue. This does not synthesize system-wide input or touch another app.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        pump()
        XCTAssertFalse(panel.isShown)
        XCTAssertTrue(window.isVisible, "The independent window must remain open")
    }

    func testDeactivationClosesOnlyPanelAndPreservesModalDialog() throws {
        let (window, anchor) = try fixture()
        defer { window.close() }
        let panel = MenuPopover()
        panel.show(Text("Traffic test").frame(width: 200, height: 100), relativeTo: anchor)
        pump()
        let dialog = NSPanel(contentRect: NSRect(x: 50, y: 50, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        dialog.isReleasedWhenClosed = false
        defer { dialog.close() }
        let session = NSApp.beginModalSession(for: dialog)
        _ = NSApp.runModalSession(session)
        XCTAssertTrue(NSApp.modalWindow === dialog)
        XCTAssertFalse(panel.popoverShouldClose(panel.popover))
        panel.applicationResignedActive(modalWindow: NSApp.modalWindow)
        XCTAssertTrue(panel.isShown)
        NSApp.endModalSession(session)
        panel.applicationResignedActive(modalWindow: dialog)
        XCTAssertTrue(panel.isShown, "A modal interaction must retain its parent panel")
        panel.applicationActivated(processIdentifier: ProcessInfo.processInfo.processIdentifier, modalWindow: nil)
        XCTAssertTrue(panel.isShown, "Traffic's own activation must preserve the panel")
        panel.applicationActivated(processIdentifier: -1, modalWindow: dialog)
        XCTAssertTrue(panel.isShown, "Switching apps must preserve an active modal interaction")
        panel.applicationActivated(processIdentifier: -1, modalWindow: nil)
        pump()
        XCTAssertFalse(panel.isShown)
        XCTAssertTrue(window.isVisible)
        panel.show(Text("Reopened").frame(width: 200, height: 100), relativeTo: anchor)
        pump(); XCTAssertTrue(panel.isShown)
        panel.close(); pump(); XCTAssertFalse(panel.isShown)
    }
}

@MainActor private final class DragRecordingWindow: NSWindow {
    var drags = 0
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { drags += 1; dragEvent = event }
}

@MainActor private final class DisclosureState: ObservableObject {
    @Published var expanded = false
}
private struct DisclosureContent: View {
    @ObservedObject var state: DisclosureState
    var body: some View {
        VStack {
            Text("Traffic connection fixture")
            DisclosureGroup("Connections", isExpanded: $state.expanded) {
                Text("Wi-Fi\nEthernet\nTailscale\nBluetooth PAN").frame(height: 180)
            }
        }.padding(20).frame(width: 320)
    }
}

@MainActor private final class TestButton: NSButton {
    var clicks = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Inside action"; target = self; action = #selector(clicked)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func clicked() { clicks += 1 }
}

private struct ButtonContent: NSViewRepresentable {
    let button: TestButton
    func makeNSView(context: Context) -> NSButton { button }
    func updateNSView(_ view: NSButton, context: Context) {}
}
