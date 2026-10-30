import AppKit
import WorkspaceCore

struct RestoreReport {
    var restored = 0
    var missing = 0
    var failed = 0
    var warnings: [String] = []
    var summary: String {
        let base = "\(restored) finestre ripristinate, \(missing) non trovate, \(failed) non riuscite."
        return warnings.isEmpty ? base : base + "\n" + warnings.joined(separator: "\n")
    }
}
@MainActor final class RestoreEngine {
    let spaces: SpacesService
    let capture: WindowCapture
    var progress: (String) -> Void = { _ in }
    init(spaces: SpacesService, capture: WindowCapture) { self.spaces = spaces; self.capture = capture }

    func restore(_ layout: Layout, preferences: Preferences, destination: RestoreDestination = .saved,
                 launchApps: Bool = true, focusedOnly: AXUIElement? = nil) async throws -> RestoreReport {
        try AX.requirePermission(); try layout.validate()
        let excluded = preferences.excludedAppIDs.union(layout.excludedAppIDs)
        let savedWindows = layout.windows.filter { !excluded.contains($0.appID) }
        let beforeDisplays = try spaces.displays()
        let initialFront = NSWorkspace.shared.frontmostApplication
        let mapping = DisplayMapper.map(saved: layout.displays, current: beforeDisplays)
        guard !mapping.isEmpty else { throw WorkspaceError.unavailable("Nessun monitor disponibile.") }
        let sameSetup = Set(layout.displays.map(\.id)) == Set(beforeDisplays.map(\.id))
        if !sameSetup && !preferences.adaptToDifferentDisplays {
            throw WorkspaceError.unavailable("Monitor diversi da quelli salvati. Collega i monitor originali o abilita l’adattamento nelle impostazioni.")
        }
        var report = RestoreReport()
        if !sameSetup { report.warnings.append("Configurazione monitor diversa: finestre adattate ai monitor disponibili.") }
        if !NSScreen.screensHaveSeparateSpaces && beforeDisplays.count > 1 {
            report.warnings.append("I monitor condividono gli Spaces: il numero di desktop è comune ai display.")
        }
        if launchApps && focusedOnly == nil {
            try await launch(layout.apps.filter { !excluded.contains($0.id) }, expectedWindowApps: Set(savedWindows.map(\.appID)), report: &report)
        }
        try Task.checkCancellation()
        let snapshot = try await capture.captureComplete(name: layout.name, scope: .workspace, excluded: excluded, progress: progress)
        report.warnings += snapshot.warnings
        let matches = WindowMatcher.match(saved: savedWindows, live: snapshot.windows.map(\.record))
        var selected = savedWindows
        if let focusedOnly {
            let focusedID = snapshot.windows.first { CFEqual($0.element, focusedOnly) }?.record.id
            selected = savedWindows.filter { matches[$0.id] == focusedID && focusedID != nil }
            if selected.isEmpty {
                if let live = snapshot.windows.first(where: { CFEqual($0.element, focusedOnly) }), !excluded.contains(live.record.appID) {
                    if live.record.appID == "com.apple.finder" { _ = AX.set(live.element, "AXMinimized", kCFBooleanTrue) }
                    else { live.app.hide() }
                }
                report.warnings.append("La finestra attiva non è presente in questo layout: è stata nascosta, se gestibile.")
                return report
            }
        }
        // Key is saved display UUID + saved ordinal; values are current ordinary desktop ordinals.
        var targetIndices: [String: Int] = [:], neededCounts: [String: Int] = [:]
        func key(_ display: String, _ index: Int) -> String { "\(display):\(index)" }
        var nextNew: [String: Int] = [:]
        for display in beforeDisplays { nextNew[display.id] = display.spaces.filter { !$0.isFullscreen }.count }
        for saved in layout.displays {
            guard let target = mapping[saved.id] else { continue }
            let indices = Set(selected.filter { $0.displayID == saved.id }.map(\.spaceIndex)).sorted()
            for index in indices {
                let actual: Int
                switch destination {
                case .saved: actual = index
                case .visible:
                    actual = target.spaces.first { $0.id == target.activeSpaceID && !$0.isFullscreen }?.index ?? 1
                case .newDesktops:
                    nextNew[target.id, default: 0] += 1; actual = nextNew[target.id]!
                }
                targetIndices[key(saved.id, index)] = actual
                neededCounts[target.id] = max(neededCounts[target.id] ?? 1, actual)
            }
            if layout.scope == .workspace && destination == .saved && focusedOnly == nil {
                neededCounts[target.id] = max(neededCounts[target.id] ?? 1, saved.spaces.count)
            }
        }
        for (displayID, count) in neededCounts.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let current = try spaces.displays().first { $0.id == displayID }?.spaces.filter { !$0.isFullscreen }.count ?? 0
            let removal = preferences.removeExtraDesktops && layout.scope == .workspace && destination == .saved && focusedOnly == nil
            if (preferences.createMissingDesktops && current < count) || (removal && current > count) {
                progress("Preparo \(count) desktop…")
                try await spaces.setDesktopCount(count, displayID: displayID, allowRemoval: removal)
            }
        }
        let currentDisplays = try spaces.displays()
        var matchedLive = Set<UUID>(), affectedSpaces = Set<UInt64>()
        // AX window lists are front-to-back: raise in reverse to preserve stacking.
        do {
            for saved in selected.reversed() {
                try Task.checkCancellation()
                guard let liveID = matches[saved.id], let live = snapshot.windows.first(where: { $0.record.id == liveID }) else {
                    report.missing += 1; report.warnings.append("\(saved.appID) — \(saved.title): finestra chiusa o non disponibile."); continue
                }
                matchedLive.insert(liveID)
                guard let mapped = mapping[saved.displayID], let targetDisplay = currentDisplays.first(where: { $0.id == mapped.id }),
                      let index = targetIndices[key(saved.displayID, saved.spaceIndex)],
                      let targetSpace = targetDisplay.spaces.first(where: { $0.index == index && !$0.isFullscreen }),
                      let savedDisplay = layout.displays.first(where: { $0.id == saved.displayID }) else {
                    report.failed += 1; report.warnings.append("\(saved.title): desktop di destinazione non disponibile."); continue
                }
                affectedSpaces.insert(targetSpace.id)
                progress("Ripristino \(live.app.localizedName ?? saved.appID) · desktop \(targetSpace.index)…")
                do {
                    if live.record.fullscreen {
                        guard AX.set(live.element, "AXFullScreen", kCFBooleanFalse) else { throw WorkspaceError.unavailable("Impossibile uscire da schermo intero.") }
                        try await spaces.pause(0.7)
                    }
                    _ = AX.set(live.element, "AXMinimized", kCFBooleanFalse)
                    live.app.unhide()
                    if !saved.sticky { try await spaces.move(live, to: targetSpace, display: targetDisplay) }
                    let frame = DisplayMapper.frame(for: saved, saved: savedDisplay, target: targetDisplay)
                    guard AX.frame(live.element, frame) else { throw WorkspaceError.unavailable("L’app ha rifiutato posizione o dimensioni.") }
                    _ = AXUIElementPerformAction(live.element, kAXRaiseAction as CFString)
                    _ = AX.set(live.element, "AXMinimized", saved.minimized ? kCFBooleanTrue : kCFBooleanFalse)
                    if let actual = AX.frame(live.element), abs(actual.x-frame.x) > 8 || abs(actual.y-frame.y) > 8 ||
                        abs(actual.width-frame.width) > 8 || abs(actual.height-frame.height) > 8 {
                        report.warnings.append("\(saved.title): l’app impone vincoli alle dimensioni o alla posizione.")
                    }
                    report.restored += 1
                } catch is CancellationError { throw CancellationError() }
                  catch { report.failed += 1; report.warnings.append("\(saved.title): \(error.localizedDescription)") }
            }
            if focusedOnly == nil {
                applyVisibility(layout, preferences: preferences, live: snapshot.windows, matched: matchedLive,
                                affectedSpaces: affectedSpaces, excluded: excluded)
                // Restore each display's saved active desktop for a complete workspace.
                if layout.scope == .workspace && destination == .saved {
                    for saved in layout.displays {
                        guard let target = mapping[saved.id],
                              let index = saved.spaces.first(where: { $0.id == saved.activeSpaceID })?.index,
                              let sid = try spaces.displays().first(where: { $0.id == target.id })?.spaces.first(where: { $0.index == index && !$0.isFullscreen })?.id else { continue }
                        do { try await spaces.activate(spaceID: sid, displayID: target.id) }
                        catch { report.warnings.append(error.localizedDescription) }
                    }
                } else if let display = currentDisplays.first(where: { $0.spaces.contains { affectedSpaces.contains($0.id) } }),
                          let target = display.spaces.first(where: { affectedSpaces.contains($0.id) }) {
                    try await spaces.activate(spaceID: target.id, displayID: display.id)
                }
            }
        } catch {
            if preferences.returnToOriginalDesktop { await restoreInitial(beforeDisplays) }
            throw error
        }
        if focusedOnly != nil && preferences.returnToOriginalDesktop { await restoreInitial(beforeDisplays); initialFront?.activate(options: []) }
        return report
    }
    private func launch(_ apps: [AppRecord], expectedWindowApps: Set<String>, report: inout RestoreReport) async throws {
        let closed = apps.filter { NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty }
        guard !closed.isEmpty else { return }
        progress("Avvio \(closed.count) applicazioni…")
        for app in closed {
            try Task.checkCancellation()
            let fallbackURL = URL(fileURLWithPath: app.path)
            let validatedFallback = Bundle(url: fallbackURL)?.bundleIdentifier == app.id ? fallbackURL : nil
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) ?? validatedFallback else {
                report.warnings.append("\(app.name) non è installata."); continue
            }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
            catch { report.warnings.append("\(app.name): \(error.localizedDescription)") }
        }
        // Wait for accessible windows, bounded and cancellable; launching alone does not imply windows are ready.
        let deadline = Date().addingTimeInterval(min(45, 8 + Double(closed.count) * 2))
        while Date() < deadline {
            try Task.checkCancellation()
            let ready = closed.allSatisfy { app in
                guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first,
                      running.isFinishedLaunching else { return false }
                if !expectedWindowApps.contains(app.id) { return true }
                let root = AXUIElementCreateApplication(running.processIdentifier)
                let windows: [AXUIElement] = AX.value(root, "AXWindows") ?? []
                return !windows.isEmpty
            }
            if ready { try await spaces.pause(0.5); break }
            try await spaces.pause(0.25)
        }
    }
    private func applyVisibility(_ layout: Layout, preferences: Preferences, live: [LiveWindow], matched: Set<UUID>,
                                 affectedSpaces: Set<UInt64>, excluded: Set<String>) {
        let savedApps = Set(layout.apps.map(\.id)).subtracting(excluded)
        let hide = layout.scope == .workspace ? preferences.hideOtherAppsForWorkspace : preferences.hideOtherAppsForDesktop
        var hidden = Set<String>()
        for window in live where !excluded.contains(window.record.appID) {
            let relevant = layout.scope == .workspace || !Set(spaces.memberships(window.record.windowID)).isDisjoint(with: affectedSpaces)
            guard relevant else { continue }
            if !savedApps.contains(window.record.appID) && hide {
                if window.record.appID == "com.apple.finder" && preferences.minimizeFinder { _ = AX.set(window.element, "AXMinimized", kCFBooleanTrue) }
                else if window.record.appID != "com.apple.finder" { window.app.hide(); hidden.insert(window.record.appID) }
            } else if savedApps.contains(window.record.appID) && !matched.contains(window.record.id) && preferences.minimizeOtherWindows {
                _ = AX.set(window.element, "AXMinimized", kCFBooleanTrue)
            }
        }
        if layout.scope == .workspace && hide {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, id != AppPaths.bundleID, id != "com.apple.finder",
                      !excluded.contains(id), !savedApps.contains(id), !hidden.contains(id) else { continue }
                app.hide()
            }
        }
        for app in layout.apps where app.hidden && !excluded.contains(app.id) {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.id).forEach { $0.hide() }
        }
    }
    private func restoreInitial(_ displays: [DisplayRecord]) async {
        await Task { @MainActor [spaces] in
            for display in displays { try? await spaces.activate(spaceID: display.activeSpaceID, displayID: display.id) }
        }.value
    }
}
