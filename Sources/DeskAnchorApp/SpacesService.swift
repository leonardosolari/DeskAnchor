import AppKit
import ApplicationServices
import ObjectiveC.runtime
import WorkspaceCore

/// Private APIs are optional and resolved at runtime; no scripting addition or SIP changes.
@MainActor final class SpacesService {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyMembership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let axHandle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private var connection: Int32 { symbol("SLSMainConnectionID", MainConnection.self)?() ?? 0 }
    var available: Bool { symbol("SLSCopyManagedDisplaySpaces", CopyDisplays.self) != nil }
    func windowID(_ element: AXUIElement) -> UInt32 {
        guard let axHandle, let pointer = dlsym(axHandle, "_AXUIElementGetWindow") else { return 0 }
        let function = unsafeBitCast(pointer, to: GetWindow.self)
        var result: UInt32 = 0
        guard function(element, &result) == 0 else { return 0 }
        return result
    }
    func memberships(_ window: UInt32) -> [UInt64] {
        guard window != 0, let copy = symbol("SLSCopySpacesForWindows", CopyMembership.self),
              let list = copy(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() else { return [] }
        return (list as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
    }
    func displays() throws -> [DisplayRecord] {
        guard let copy = symbol("SLSCopyManagedDisplaySpaces", CopyDisplays.self),
              let array = copy(connection)?.takeRetainedValue(), let managed = array as? [[String: Any]], !managed.isEmpty else {
            throw WorkspaceError.unavailable("macOS non espone l’elenco degli Spaces. Il salvataggio è stato interrotto per evitare un layout incompleto.")
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func rect(_ r: NSRect) -> Rect { Rect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid)! as String
            let data = managed.first { ($0["Display Identifier"] as? String) == id } ??
                managed.first { ($0["Display Identifier"] as? String) == "Main" }
            guard let data, let rawSpaces = data["Spaces"] as? [[String: Any]] else { return nil }
            var ordinary = 0
            let normalCount = rawSpaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.count
            var fullscreen = normalCount
            let spaces = rawSpaces.compactMap { raw -> SpaceRecord? in
                guard let sid = (raw["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (raw["id64"] as? NSNumber)?.uint64Value,
                      let type = (raw["type"] as? NSNumber)?.intValue, type == 0 || type == 4 else { return nil }
                if type == 0 { ordinary += 1 } else { fullscreen += 1 }
                return SpaceRecord(id: sid, index: type == 0 ? ordinary : fullscreen, isFullscreen: type == 4)
            }
            let active = data["Current Space"] as? [String: Any]
            let current = (active?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (active?["id64"] as? NSNumber)?.uint64Value ?? 0
            return DisplayRecord(id: id, name: screen.localizedName, frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame),
                                 isBuiltin: CGDisplayIsBuiltin(number.uint32Value) != 0, spaces: spaces, activeSpaceID: current)
        }
    }
    func focusedDisplay(_ displays: [DisplayRecord]) -> DisplayRecord? {
        guard let screen = NSScreen.main, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return displays.first }
        let id = CFUUIDCreateString(nil, uuid)! as String
        return displays.first { $0.id == id } ?? displays.first
    }
    func pause(_ seconds: Double = 0.25) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func missionRoot() -> AXUIElement? {
        for bundleID in ["com.apple.dock", "com.apple.WindowManager"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 1)
                if let root = AX.find(element, depth: 5, where: { (AX.value($0, "AXIdentifier") as String?) == "mc" }) { return root }
            }
        }
        return nil
    }
    private func openMissionControl() async throws -> AXUIElement {
        if let root = missionRoot() { try await pause(0.4); return root }
        // LaunchServices opens the system Mission Control application; no Apple Events permission needed.
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<20 {
            try await pause(0.1)
            if let root = missionRoot() {
                // The AX root exists before its buttons are ready. An early AXPress may return
                // success while the Dock is still animating, without selecting the desktop.
                try await pause(0.4)
                return root
            }
        }
        throw WorkspaceError.unavailable("Mission Control non è accessibile. Controlla il permesso Accessibilità.")
    }
    private func closeMissionControl() async {
        guard missionRoot() != nil else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        try? await pause(0.3)
    }
    private func displayGroup(_ root: AXUIElement, display: DisplayRecord) throws -> AXUIElement {
        let screen = NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid)! as String == display.id
        }
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { throw WorkspaceError.unavailable("Monitor scollegato durante l’operazione.") }
        if let found = AX.find(root, where: {
            let identifier: String? = AX.value($0, "AXIdentifier")
            let displayNumber: NSNumber? = AX.value($0, "AXDisplayID")
            return identifier == "mc.display" && displayNumber == number
        }) { return found }
        throw WorkspaceError.unavailable("Monitor \(display.name) non trovato in Mission Control.")
    }
    func setDesktopCount(_ count: Int, displayID: String, allowRemoval: Bool) async throws {
        guard (1...32).contains(count) else { throw WorkspaceError.invalid("Il numero di desktop deve essere tra 1 e 32.") }
        guard let before = try displays().first(where: { $0.id == displayID }) else { throw WorkspaceError.unavailable("Monitor scollegato.") }
        let currentCount = before.spaces.filter { !$0.isFullscreen }.count
        if currentCount == count || (currentCount > count && !allowRemoval) { return }
        do {
            let root = try await openMissionControl()
            for _ in 0..<32 {
                try Task.checkCancellation()
                guard let display = try displays().first(where: { $0.id == displayID }) else { break }
                let normalSpaces = display.spaces.filter { !$0.isFullscreen }
                if normalSpaces.count == count || (normalSpaces.count > count && !allowRemoval) { break }
                let group = try displayGroup(root, display: display)
                let actionResult: AXError
                if normalSpaces.count < count {
                    guard let add = AX.find(group, where: { (AX.value($0, "AXIdentifier") as String?) == "mc.spaces.add" }) else {
                        throw WorkspaceError.unavailable("Pulsante Aggiungi desktop non trovato.")
                    }
                    actionResult = AXUIElementPerformAction(add, kAXPressAction as CFString)
                } else {
                    guard let list = AX.find(group, where: { (AX.value($0, "AXIdentifier") as String?) == "mc.spaces.list" }),
                          let last = normalSpaces.last, let rawIndex = display.spaces.firstIndex(where: { $0.id == last.id }),
                          AX.children(list).indices.contains(rawIndex) else {
                        throw WorkspaceError.unavailable("Desktop da rimuovere non trovato.")
                    }
                    actionResult = AXUIElementPerformAction(AX.children(list)[rawIndex], "AXRemoveDesktop" as CFString)
                }
                guard actionResult == .success else { throw WorkspaceError.unavailable("macOS ha rifiutato la modifica dei desktop (\(actionResult.rawValue)).") }
                try await pause(0.55)
            }
            await closeMissionControl()
            let actual = try displays().first { $0.id == displayID }?.spaces.filter { !$0.isFullscreen }.count
            guard actual == count || (!allowRemoval && (actual ?? 0) >= count) else {
                throw WorkspaceError.unavailable("Numero di desktop non raggiunto: richiesti \(count), disponibili \(actual ?? 0).")
            }
        } catch { await closeMissionControl(); throw error }
    }
    func activate(spaceID: UInt64, displayID: String) async throws {
        guard let display = try displays().first(where: { $0.id == displayID }),
              let index = display.spaces.firstIndex(where: { $0.id == spaceID }) else { throw WorkspaceError.unavailable("Desktop non disponibile.") }
        if display.activeSpaceID == spaceID { return }
        do {
            let root = try await openMissionControl(), group = try displayGroup(root, display: display)
            guard let list = AX.find(group, where: { (AX.value($0, "AXIdentifier") as String?) == "mc.spaces.list" }),
                  AX.children(list).indices.contains(index) else { throw WorkspaceError.unavailable("Desktop non trovato in Mission Control.") }
            guard AXUIElementPerformAction(AX.children(list)[index], kAXPressAction as CFString) == .success else {
                throw WorkspaceError.unavailable("Cambio desktop rifiutato da macOS.")
            }
            // Selecting a desktop closes Mission Control itself. Sending Escape during that
            // transition can cancel it. Poll WindowServer and let the animation complete.
            let reached = try await AsyncPolling.until(timeout: 3) {
                try self.displays().first(where: { $0.id == displayID })?.activeSpaceID == spaceID
            }
            guard reached else {
                let actual = try displays().first(where: { $0.id == displayID })?.activeSpaceID ?? 0
                throw WorkspaceError.unavailable("Cambio al desktop \(index + 1) non riuscito (Space richiesto \(spaceID), attuale \(actual)).")
            }
            try await pause(0.25)
        } catch { await closeMissionControl(); throw error }
    }
    private func requestNativeMove(windowID: UInt32, target: UInt64) {
        if let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") {
            let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
            let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
            if let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
               allocated.responds(to: initSelector) {
                typealias Initializer = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject
                let initialize = unsafeBitCast(allocated.method(for: initSelector), to: Initializer.self)
                let operation = initialize(allocated, initSelector, [NSNumber(value: windowID)], target)
                if operation.responds(to: performSelector) {
                    typealias Perform = @convention(c) (AnyObject, Selector) -> Void
                    unsafeBitCast(operation.method(for: performSelector), to: Perform.self)(operation, performSelector)
                    return
                }
            }
        }
        symbol("SLSMoveWindowsToManagedSpace", MoveWindows.self)?(connection, [NSNumber(value: windowID)] as CFArray, target)
    }
    func move(_ window: LiveWindow, to target: SpaceRecord, display: DisplayRecord) async throws {
        if memberships(window.record.windowID).contains(target.id) { return }
        guard window.record.windowID != 0 else { throw WorkspaceError.unavailable("ID finestra non disponibile per \(window.record.title).") }
        requestNativeMove(windowID: window.record.windowID, target: target.id)
        for _ in 0..<4 {
            try await pause(0.1)
            if memberships(window.record.windowID).contains(target.id) { return }
        }
        // On systems denying direct moves, reproduce the native title-bar drag + Control-arrow gesture.
        // The mouse button is always released, including cancellation/errors.
        let sourceID = memberships(window.record.windowID).first
        guard let sourceDisplay = try displays().first(where: { d in d.spaces.contains { $0.id == sourceID } }),
              let sourceID else { throw WorkspaceError.unavailable("Desktop di origine della finestra sconosciuto.") }
        try await activate(spaceID: sourceID, displayID: sourceDisplay.id)
        _ = AX.set(window.element, "AXMinimized", kCFBooleanFalse)
        window.app.unhide(); window.app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        let safeFrame = Rect(x: display.visibleFrame.x + 40, y: display.visibleFrame.y + 40,
                             width: min(700, display.visibleFrame.width - 80), height: min(500, display.visibleFrame.height - 80))
        _ = AX.frame(window.element, safeFrame)
        try await pause(0.2)
        let frame = AX.frame(window.element) ?? safeFrame
        // Prefer the actual title bar when provided by Accessibility.
        let titleBar = AX.element(window.element, "AXTitleUIElement").flatMap { AX.frame($0) }
        let point = CGPoint(x: titleBar.map { $0.x + $0.width / 2 } ?? (frame.x + frame.width / 2), y: frame.y + 12)
        let originalMouse = CGEvent(source: nil)?.location
        mouse(.leftMouseDown, point)
        defer {
            mouse(.leftMouseUp, point)
            if let originalMouse { CGWarpMouseCursorPosition(originalMouse) }
        }
        mouse(.leftMouseDragged, CGPoint(x: point.x + 2, y: point.y + 2))
        try await pause(0.2)
        guard let now = try displays().first(where: { $0.id == display.id }),
              let currentIndex = now.spaces.firstIndex(where: { $0.id == now.activeSpaceID }),
              let targetIndex = now.spaces.firstIndex(where: { $0.id == target.id }) else { throw WorkspaceError.unavailable("Desktop cambiati durante lo spostamento.") }
        let steps = targetIndex - currentIndex
        for _ in 0..<abs(steps) {
            try Task.checkCancellation()
            key(steps > 0 ? 124 : 123, flags: .maskControl)
            try await pause(0.6)
            mouse(.leftMouseDragged, CGPoint(x: point.x + 2, y: point.y + 2))
        }
        mouse(.leftMouseUp, point)
        try await pause(0.25)
        guard memberships(window.record.windowID).contains(target.id) else {
            throw WorkspaceError.unavailable("\(window.app.localizedName ?? "App"): spostamento al desktop \(target.index) non riuscito. Abilita Ctrl+←/→ in Tastiera → Abbreviazioni → Mission Control; verifica che il titolo della finestra sia trascinabile.")
        }
    }
    private func mouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
    }
}
