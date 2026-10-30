import AppKit
import ApplicationServices
import WorkspaceCore

enum AX {
    static func value<T>(_ element: AXUIElement, _ name: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result as? T
    }
    static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    @discardableResult static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, "AXChildren") ?? [] }
    static func find(_ element: AXUIElement, depth: Int = 12, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(element) { return element }
        guard depth > 0 else { return nil }
        for child in children(element) { if let found = find(child, depth: depth - 1, where: predicate) { return found } }
        return nil
    }
    static func frame(_ element: AXUIElement) -> Rect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos: AXValue = value(element, "AXPosition"), let size: AXValue = value(element, "AXSize"),
              AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return Rect(x: p.x, y: p.y, width: s.width, height: s.height)
    }
    @discardableResult static func frame(_ element: AXUIElement, _ frame: Rect) -> Bool {
        var p = CGPoint(x: frame.x, y: frame.y), s = CGSize(width: frame.width, height: frame.height)
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return false }
        // Some apps constrain size against the current screen; applying size twice handles a screen move.
        _ = set(element, "AXSize", size)
        let positionOK = set(element, "AXPosition", pos)
        let sizeOK = set(element, "AXSize", size)
        return positionOK && sizeOK
    }
    static func requirePermission() throws {
        guard AXIsProcessTrusted() else {
            // Prompt only from the explicit permission button. Repeating a native prompt on every
            // save does not repair a TCC entry belonging to an older ad-hoc signed build.
            throw WorkspaceError.unavailable("macOS non riconosce il permesso Accessibilità per questa copia di DeskAnchor. Se l’interruttore è già attivo, rimuovi DeskAnchor dall’elenco con −, aggiungi di nuovo questa app con + e riaprila. Usa «Mostra questa app» per individuare la copia corretta.")
        }
    }
}

struct LiveWindow {
    var record: WindowRecord
    var element: AXUIElement
    var app: NSRunningApplication
}
struct CaptureResult {
    var layout: Layout
    var windows: [LiveWindow]
    var warnings: [String]
    var inaccessibleAppIDs: Set<String> = []
    var unreadSpaceIDs: Set<UInt64> = []
}

@MainActor final class WindowCapture {
    let spaces: SpacesService
    init(spaces: SpacesService) { self.spaces = spaces }
    func capture(name: String, scope: LayoutScope, excluded: Set<String>, requireAccess: Bool = true) throws -> CaptureResult {
        if requireAccess { try AX.requirePermission() }
        let displays = try spaces.displays()
        guard !displays.isEmpty else { throw WorkspaceError.unavailable("Nessun monitor disponibile.") }
        let focusedDisplay = spaces.focusedDisplay(displays)
        let orderedWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let stacking = Dictionary(orderedWindows.enumerated().compactMap { index, raw -> (UInt32, Int)? in
            guard let id = (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return (id, index)
        }, uniquingKeysWith: { first, _ in first })
        var windows: [LiveWindow] = [], apps: [AppRecord] = [], warnings: [String] = [], inaccessible = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != AppPaths.bundleID,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !excluded.contains(bundleID) else { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 1)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &raw)
            guard status == .success, let elements = raw as? [AXUIElement] else {
                inaccessible.insert(bundleID)
                if !app.isHidden { warnings.append("\(app.localizedName ?? bundleID): elenco finestre non accessibile (\(status.rawValue)).") }
                continue
            }
            let appRecord = AppRecord(id: bundleID, name: app.localizedName ?? bundleID,
                                      path: app.bundleURL?.path ?? "", hidden: app.isHidden)
            var ordinal = 0
            for element in elements {
                let role: String? = AX.value(element, "AXRole")
                let subrole: String? = AX.value(element, "AXSubrole")
                guard role == "AXWindow", subrole != "AXSystemDialog", let frame = AX.frame(element),
                      frame.isValid, frame.width > 30, frame.height > 30 else { continue }
                let windowID = spaces.windowID(element)
                let memberships = spaces.memberships(windowID)
                let display = displays.max { $0.frame.overlap(with: frame) < $1.frame.overlap(with: frame) } ?? displays[0]
                let space = display.spaces.first { memberships.contains($0.id) } ??
                    display.spaces.first { $0.id == display.activeSpaceID }
                guard let space else { warnings.append("\(appRecord.name): desktop della finestra non identificato."); continue }
                let isVisibleSpace = memberships.contains(display.activeSpaceID) || (memberships.isEmpty && space.id == display.activeSpaceID)
                let include = scope == .workspace || (isVisibleSpace && (scope == .visibleDesktops || display.id == focusedDisplay?.id))
                let record = WindowRecord(appID: bundleID, title: AX.value(element, "AXTitle") ?? "",
                    identifier: AX.value(element, "AXIdentifier"), windowID: windowID,
                    processID: app.processIdentifier, launchDate: app.launchDate, ordinal: ordinal,
                    displayID: display.id, spaceIndex: space.index, frame: frame,
                    minimized: AX.value(element, "AXMinimized") ?? false,
                    fullscreen: AX.value(element, "AXFullScreen") ?? false,
                    sticky: memberships.filter { id in display.spaces.contains { $0.id == id && !$0.isFullscreen } }.count > 1,
                    stackingOrder: stacking[windowID])
                ordinal += 1
                if include { windows.append(LiveWindow(record: record, element: element, app: app)) }
            }
            // Also retain normal apps with no windows for workspace launch/visibility restoration.
            if scope == .workspace || windows.contains(where: { $0.record.appID == bundleID }) { apps.append(appRecord) }
        }
        windows.sort { ($0.record.stackingOrder ?? Int.max) < ($1.record.stackingOrder ?? Int.max) }
        let layout = Layout(name: name, scope: scope, displays: displays, apps: apps,
                            windows: windows.map(\.record), excludedAppIDs: [])
        return CaptureResult(layout: layout, windows: windows, warnings: warnings, inaccessibleAppIDs: inaccessible)
    }
    /// A few applications expose only the windows on the current Space. Visit the missing windows' Spaces
    /// only when WindowServer reports ordinary windows absent from the first AX inventory.
    func captureComplete(name: String, scope: LayoutScope, excluded: Set<String>, progress: (String) -> Void) async throws -> CaptureResult {
        var result = try capture(name: name, scope: scope, excluded: excluded)
        guard scope == .workspace else { return result }
        let initialDisplays = result.layout.displays
        let front = NSWorkspace.shared.frontmostApplication
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != AppPaths.bundleID,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !excluded.contains(id) else { return nil }
            return (app.processIdentifier, id)
        })
        let rawWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let initialStacking = Dictionary(rawWindows.enumerated().compactMap { index, raw -> (UInt32, Int)? in
            guard let id = (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }; return (id, index)
        }, uniquingKeysWith: { first, _ in first })
        let expected: [UInt32] = rawWindows.compactMap { raw in
            guard let pid = raw[kCGWindowOwnerPID as String] as? NSNumber, appsByPID[pid.int32Value] != nil,
                  (raw[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = raw[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 30, frame.height > 30 else { return nil }
            return id
        }
        let known = Set(result.windows.map { $0.record.windowID })
        let missing = expected.filter { !known.contains($0) }
        let missingSpaces = Set(missing.flatMap { spaces.memberships($0) })
        guard !missingSpaces.isEmpty else { return result }
        func identity(_ window: LiveWindow) -> String {
            window.record.windowID == 0 ? "\(window.record.processID):\(window.record.ordinal):\(window.record.title)" : "\(window.record.processID):\(window.record.windowID)"
        }
        var collected = Dictionary(result.windows.map { (identity($0), $0) }, uniquingKeysWith: { a, _ in a })
        var apps = Dictionary(uniqueKeysWithValues: result.layout.apps.map { ($0.id, $0) })
        do {
            for display in initialDisplays {
                for space in display.spaces where missingSpaces.contains(space.id) {
                    try Task.checkCancellation(); progress("Leggo \(display.name) · desktop \(space.index)…")
                    do { try await spaces.activate(spaceID: space.id, displayID: display.id) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        result.unreadSpaceIDs.insert(space.id)
                        result.warnings.append("\(display.name), desktop \(space.index): scansione aggiuntiva non completata. \(error.localizedDescription)")
                        continue
                    }
                    let extra = try capture(name: name, scope: .workspace, excluded: excluded)
                    for var window in extra.windows where collected[identity(window)] == nil {
                        window.record.stackingOrder = initialStacking[window.record.windowID]
                        collected[identity(window)] = window
                    }
                    for app in extra.layout.apps { apps[app.id] = app; result.inaccessibleAppIDs.remove(app.id) }
                }
            }
        } catch {
            await returnToInitial(initialDisplays); front?.activate(options: [])
            throw error
        }
        await returnToInitial(initialDisplays); front?.activate(options: [])
        result.windows = collected.values.sorted { ($0.record.stackingOrder ?? Int.max) < ($1.record.stackingOrder ?? Int.max) }
        result.layout.windows = result.windows.map(\.record)
        result.layout.apps = apps.values.sorted { $0.name < $1.name }
        let stillMissing = missing.filter { id in !result.windows.contains { $0.record.windowID == id } }
        if !stillMissing.isEmpty { result.warnings.append("\(stillMissing.count) finestre di sistema non sono accessibili tramite AX; potrebbero essere pannelli o finestre non supportate.") }
        return result
    }
    private func returnToInitial(_ displays: [DisplayRecord]) async {
        // A detached cleanup task can restore the desktop even when the caller was cancelled.
        await Task { @MainActor [spaces] in
            for display in displays { try? await spaces.activate(spaceID: display.activeSpaceID, displayID: display.id) }
        }.value
    }
    func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let app = AX.element(system, "AXFocusedApplication") else { return nil }
        return AX.element(app, "AXFocusedWindow")
    }
}
