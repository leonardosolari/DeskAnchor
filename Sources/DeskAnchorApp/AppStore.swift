import AppKit
import SwiftUI
import ServiceManagement
@preconcurrency import UserNotifications
import WorkspaceCore

@MainActor final class AppStore: ObservableObject {
    @Published var library = Library()
    @Published var navigation: SidebarDestination? {
        didSet {
            if case .layout(let id) = navigation { lastSelectedLayoutID = id }
        }
    }
    @Published var isCreatingLayout = false
    private var lastSelectedLayoutID: UUID?
    var selectedID: UUID? {
        get { if case .layout(let id) = navigation { return id }; return nil }
        set { navigation = newValue.map(SidebarDestination.layout) }
    }
    @Published var busy = false
    @Published var status = "Pronto"
    @Published var error: String?
    @Published var log: [String] = []
    @Published var operationWarnings: [String] = []
    @Published var hasAccessibility = AXIsProcessTrusted()
    let preview: Bool
    let spaces = SpacesService()
    lazy var capture = WindowCapture(spaces: spaces)
    lazy var engine: RestoreEngine = {
        let engine = RestoreEngine(spaces: spaces, capture: capture)
        engine.progress = { [weak self] in self?.status = $0 }
        return engine
    }()
    private let storage = LibraryStore()
    private var operation: Task<Void, Never>?
    private var autoRestore: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var didStart = false
    private var archiveLoadFailed = false
    private var lastRestoreHadFailures = false
    let shortcuts = ShortcutManager()
    var showWindow: () -> Void = {}
    var active: WorkspaceCore.Layout? { library.layouts.first { $0.id == library.activeLayoutID } }
    var selected: WorkspaceCore.Layout? { library.layouts.first { $0.id == selectedID } }
    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            library = Self.previewLibrary(); selectedID = library.layouts.first?.id
            status = "Anteprima dimostrativa · nessuna modifica a finestre o archivio"
            return
        }
        do {
            try storage.migrateIfNeeded(from: AppPaths.legacyLibraries)
            library = try storage.load()
            selectedID = library.activeLayoutID ?? library.layouts.first?.id
        }
        catch { archiveLoadFailed = true; self.error = "Impossibile leggere l’archivio. Il file originale è conservato. \(error.localizedDescription)" }
    }
    func start() {
        guard !didStart else { return }; didStart = true
        guard !preview else { return }
        shortcuts.action = { [weak self] in self?.performBinding($0) }
        configureShortcuts()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.library.preferences.restoreOnDisplayChange == true { self?.scheduleRestore() } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.library.preferences.restoreOnWake == true { self?.scheduleRestore() } }
        })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveCommand(_:)), name: NSNotification.Name(AppPaths.notification), object: nil)
        try? AppPaths.prepare(AppPaths.inbox)
        // Remove stale command files, never follow client-provided paths.
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: file) }
        }
    }
    func persist() throws {
        if preview { return }
        guard !archiveLoadFailed else { throw WorkspaceError.invalid("Archivio illeggibile: ripristina library.json.backup dal Finder e riavvia l’app. Il file originale non è stato modificato.") }
        try storage.save(library)
    }
    func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        // @Published emits even when the value is unchanged. A polling tick must not
        // rebuild the status menu and dismiss the submenu the user is navigating.
        guard granted != hasAccessibility else { return }
        if granted && !hasAccessibility {
            status = "Accessibilità attiva. Puoi salvare e ripristinare i layout."
        }
        hasAccessibility = granted
    }
    func openAccessibilitySettings() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func openLayouts() {
        let candidate = selectedID ?? lastSelectedLayoutID ?? library.activeLayoutID
        selectedID = candidate.flatMap { id in library.layouts.first { $0.id == id }?.id } ?? library.layouts.first?.id
        showWindow()
    }
    func openSettings(_ page: SettingsPage = .general) {
        navigation = .settings(page)
        showWindow()
    }
    func openNewLayout() {
        openLayouts()
        isCreatingLayout = true
    }
    func savePreferences() {
        do { try persist(); configureShortcuts() } catch { self.error = error.localizedDescription }
    }
    func configureShortcuts() {
        let failures = shortcuts.configure(library.preferences.bindings)
        if !failures.isEmpty { record(failures.joined(separator: "\n")) }
    }
    private func scheduleRestore() {
        autoRestore?.cancel()
        autoRestore = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, !self.busy, self.hasAccessibility, let layout = self.active else { return }
            self.restore(layout, launchApps: false)
        }
    }
    func record(_ message: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) · \(message)", at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }
    func cancel() { operation?.cancel(); status = "Interruzione in corso…" }
    func run(_ task: @escaping () async throws -> String) {
        guard !preview else { status = "Anteprima: apri l’app senza --preview per gestire finestre reali."; return }
        guard !busy else { return }
        operationWarnings = []
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do { let result = try await task(); status = result; record(result) }
            catch is CancellationError { status = "Operazione interrotta"; record(status) }
            catch { self.error = error.localizedDescription; status = "Operazione non completata"; record(error.localizedDescription) }
        }
    }
    func create(name: String, scope: WorkspaceCore.LayoutScope) {
        run { try await self.createNow(name: name, scope: scope) }
    }
    private func checkName(_ name: String, except id: UUID? = nil) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120 else { throw WorkspaceError.invalid("Il nome deve contenere da 1 a 120 caratteri.") }
        guard !library.layouts.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
            throw WorkspaceError.invalid("Esiste già un layout con questo nome.")
        }
        return clean
    }
    func createNow(name: String, scope: WorkspaceCore.LayoutScope) async throws -> String {
        let name = try checkName(name)
        status = "Salvo \(scope.label.lowercased())…"
        let snapshot = try await capture.captureComplete(name: name, scope: scope, excluded: library.preferences.excludedAppIDs) { self.status = $0 }
        operationWarnings = snapshot.warnings
        guard !snapshot.layout.apps.isEmpty else { throw WorkspaceError.invalid("Nessuna applicazione da salvare. Apri almeno un’app non esclusa.") }
        library.layouts.append(snapshot.layout); library.activeLayoutID = snapshot.layout.id; selectedID = snapshot.layout.id
        try persist()
        let qualifier = snapshot.unreadSpaceIDs.isEmpty ? "salvato" : "salvato parzialmente"
        let message = "Layout «\(name)» \(qualifier) · \(snapshot.layout.windows.count) finestre" +
            (snapshot.warnings.isEmpty ? "." : " · \(snapshot.warnings.count) avvisi.") + warningSuffix(snapshot.warnings)
        notify("Layout salvato", message, enabled: library.preferences.notifySave)
        return message
    }
    func update(_ layout: WorkspaceCore.Layout, desktopOnly: Bool = false) { run { try await self.updateNow(layout, desktopOnly: desktopOnly) } }
    func updateNow(_ layout: WorkspaceCore.Layout, desktopOnly: Bool = false) async throws -> String {
        let excluded = library.preferences.excludedAppIDs.union(layout.excludedAppIDs)
        let snapshot = try await capture.captureComplete(name: layout.name, scope: desktopOnly ? .desktop : layout.scope, excluded: excluded) { self.status = $0 }
        operationWarnings = snapshot.warnings
        guard snapshot.unreadSpaceIDs.isEmpty else {
            throw WorkspaceError.unavailable("Scansione incompleta: il layout precedente è stato conservato. Consulta gli avvisi per i desktop non letti.")
        }
        guard let index = library.layouts.firstIndex(where: { $0.id == layout.id }) else { throw WorkspaceError.invalid("Layout non trovato.") }
        if desktopOnly {
            guard let display = spaces.focusedDisplay(snapshot.layout.displays),
                  let space = display.spaces.first(where: { $0.id == display.activeSpaceID }) else { throw WorkspaceError.unavailable("Desktop attivo non disponibile.") }
            library.layouts[index] = LayoutEditor.updateDesktop(in: layout, snapshot: snapshot.layout, displayID: display.id, spaceIndex: space.index, preservingAppIDs: snapshot.inaccessibleAppIDs.subtracting(excluded))
        } else {
            var updated = snapshot.layout
            // An unresponsive running app must not silently disappear from an update.
            let inaccessible = snapshot.inaccessibleAppIDs.subtracting(excluded)
            updated.apps += layout.apps.filter { previous in inaccessible.contains(previous.id) && !updated.apps.contains(where: { $0.id == previous.id }) }
            updated.windows += layout.windows.filter { inaccessible.contains($0.appID) }
            let referencedDisplays = Set(updated.windows.map(\.displayID))
            updated.displays += layout.displays.filter { previous in referencedDisplays.contains(previous.id) && !updated.displays.contains(where: { $0.id == previous.id }) }
            updated.id = layout.id; updated.createdAt = layout.createdAt; updated.updatedAt = Date()
            updated.lastRestoredAt = layout.lastRestoredAt; updated.excludedAppIDs = layout.excludedAppIDs
            library.layouts[index] = updated
        }
        library.activeLayoutID = layout.id; try persist()
        let message = "«\(layout.name)» aggiornato" + (desktopOnly ? " (solo desktop attivo)." : ".") + warningSuffix(snapshot.warnings)
        notify("Layout aggiornato", message, enabled: library.preferences.notifyUpdate)
        return message
    }
    func restore(_ layout: WorkspaceCore.Layout, destination: RestoreDestination = .saved, launchApps: Bool = true) {
        run { try await self.restoreNow(layout, destination: destination, launchApps: launchApps) }
    }
    func restoreNow(_ layout: WorkspaceCore.Layout, destination: RestoreDestination, launchApps: Bool) async throws -> String {
        let report = try await engine.restore(layout, preferences: library.preferences, destination: destination, launchApps: launchApps)
        lastRestoreHadFailures = report.failed > 0 || report.missing > 0
        // Even a partial restore becomes active, but its issues remain explicit in the report.
        library.activeLayoutID = layout.id; selectedID = layout.id
        if let index = library.layouts.firstIndex(where: { $0.id == layout.id }) { library.layouts[index].lastRestoredAt = Date() }
        try persist()
        notify("Ripristino «\(layout.name)»", report.summary, enabled: library.preferences.notifyRestore)
        return report.summary
    }
    func restoreFocused(allLayouts: Bool) {
        run {
            guard let focused = self.capture.focusedWindow() else { throw WorkspaceError.unavailable("Nessuna finestra attiva.") }
            var layout = self.active
            if allLayouts {
                let current = try self.capture.capture(name: "Ricerca", scope: .workspace, excluded: self.library.preferences.excludedAppIDs)
                guard let window = current.windows.first(where: { CFEqual($0.element, focused) }) else { return "Finestra esclusa o non accessibile." }
                layout = self.library.layouts.sorted { $0.updatedAt > $1.updatedAt }.first {
                    !$0.excludedAppIDs.contains(window.record.appID) &&
                    !WindowMatcher.match(saved: $0.windows, live: [window.record]).isEmpty
                }
                guard layout != nil else { return "La finestra non è presente in alcun layout." }
            }
            guard let layout else { throw WorkspaceError.invalid("Nessun layout attivo.") }
            let report = try await self.engine.restore(layout, preferences: self.library.preferences, launchApps: false, focusedOnly: focused)
            self.notify("Finestra ripristinata", report.summary, enabled: self.library.preferences.notifyWindow)
            return report.summary
        }
    }
    func rename(_ layout: WorkspaceCore.Layout, to name: String) {
        do {
            let name = try checkName(name, except: layout.id)
            guard let index = library.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
            library.layouts[index].name = name; try persist()
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ layout: WorkspaceCore.Layout) {
        library.layouts.removeAll { $0.id == layout.id }
        library.preferences.bindings.removeAll { $0.layoutID == layout.id }
        if library.activeLayoutID == layout.id { library.activeLayoutID = nil }
        selectedID = library.layouts.first?.id; savePreferences()
    }
    func duplicate(_ layout: WorkspaceCore.Layout) {
        var copy = layout; copy.id = UUID(); copy.createdAt = Date(); copy.updatedAt = Date(); copy.lastRestoredAt = nil
        var n = 1; var name = "\(layout.name) (copia)"
        while library.layouts.contains(where: { $0.name == name }) { n += 1; name = "\(layout.name) (copia \(n))" }
        copy.name = name; library.layouts.append(copy); selectedID = copy.id; savePreferences()
    }
    func removeApp(_ appID: String, from layout: WorkspaceCore.Layout) {
        guard let i = library.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        library.layouts[i].apps.removeAll { $0.id == appID }; library.layouts[i].windows.removeAll { $0.appID == appID }
        library.layouts[i].updatedAt = Date(); savePreferences()
    }
    func excludeApp(_ appID: String, in layout: WorkspaceCore.Layout) {
        guard let i = library.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        if !library.layouts[i].excludedAppIDs.insert(appID).inserted { library.layouts[i].excludedAppIDs.remove(appID) }
        savePreferences()
    }
    func editWindow(_ window: WindowRecord, in layout: WorkspaceCore.Layout) {
        guard let i = library.layouts.firstIndex(where: { $0.id == layout.id }),
              let j = library.layouts[i].windows.firstIndex(where: { $0.id == window.id }) else { return }
        library.layouts[i].windows[j] = window; library.layouts[i].updatedAt = Date(); savePreferences()
    }
    func exportLayouts(selected: WorkspaceCore.Layout? = nil) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = (selected?.name ?? "DeskAnchor") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let selected { try LibraryStore.encoder.encode(selected).write(to: url, options: .atomic) }
            else { try LibraryStore.encoder.encode(library).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
    func importLayouts() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 20_000_000 else { throw WorkspaceError.invalid("Archivio troppo grande (massimo 20 MB).") }
            let layouts: [WorkspaceCore.Layout]
            if let archive = try? LibraryStore.decoder.decode(Library.self, from: data) { try archive.validate(); layouts = archive.layouts }
            else { let layout = try LibraryStore.decoder.decode(WorkspaceCore.Layout.self, from: data); try layout.validate(); layouts = [layout] }
            for var layout in layouts {
                layout.id = UUID(); var name = layout.name, n = 1
                while library.layouts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { n += 1; name = "\(layout.name) (\(n))" }
                layout.name = name; library.layouts.append(layout); selectedID = layout.id
            }
            try persist(); record("Importati \(layouts.count) layout. Le preferenze locali sono conservate.")
        } catch { self.error = error.localizedDescription }
    }
    func addExcludedApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { library.preferences.excludedAppIDs.insert(id) } }
        savePreferences()
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !preview else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }
    func enableNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    private func notify(_ title: String, _ body: String, enabled: Bool) {
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    private func warningSuffix(_ warnings: [String]) -> String { warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n") }
    func performBinding(_ binding: KeyBinding) {
        let layout = binding.layoutID.flatMap { id in library.layouts.first { $0.id == id } } ?? active
        switch binding.action {
        case "show": showWindow()
        case "restore-window": restoreFocused(allLayouts: false)
        case "restore-window-all": restoreFocused(allLayouts: true)
        case "save": create(name: "Workspace \(Date().formatted())", scope: .workspace)
        default:
            guard let layout else { error = "Nessun layout attivo."; return }
            switch binding.action {
            case "update": update(layout)
            case "update-desktop": update(layout, desktopOnly: true)
            case "restore-no-launch": restore(layout, launchApps: false)
            case "restore-visible": restore(layout, destination: .visible)
            case "restore-new": restore(layout, destination: .newDesktops)
            default: restore(layout)
            }
        }
    }
    @objc private func receiveCommand(_ notification: Notification) {
        guard let text = notification.userInfo?["id"] as? String, let id = UUID(uuidString: text) else { return }
        let requestURL = AppPaths.inbox.appendingPathComponent(id.uuidString + ".request.json")
        guard let data = try? Data(contentsOf: requestURL), data.count < 65536,
              let request = try? LibraryStore.decoder.decode(CommandRequest.self, from: data), request.id == id else { return }
        try? FileManager.default.removeItem(at: requestURL)
        if busy { respond(id, success: false, message: "Un’operazione è già in corso."); return }
        busy = true
        operationWarnings = []
        operation = Task {
            defer { busy = false; operation = nil }
            do { lastRestoreHadFailures = false; let result = try await execute(request); respond(id, success: !lastRestoreHadFailures, message: result); status = result; record(result) }
            catch { respond(id, success: false, message: error.localizedDescription); record(error.localizedDescription) }
        }
    }
    private func respond(_ id: UUID, success: Bool, message: String) {
        let url = AppPaths.inbox.appendingPathComponent(id.uuidString + ".response.json")
        try? LibraryStore.encoder.encode(CommandResponse(success: success, message: message)).write(to: url, options: .atomic)
    }
    private func execute(_ request: CommandRequest) async throws -> String {
        let layout = request.name.flatMap { name in library.layouts.first { $0.name == name || $0.id.uuidString == name } } ?? (request.name == nil ? active : nil)
        switch request.command {
        case "list": return library.layouts.map { "\($0.id.uuidString)\t\($0.name)\t\($0.scope.rawValue)\($0.id == library.activeLayoutID ? "\tactive" : "")" }.joined(separator: "\n")
        case "create": return try await createNow(name: request.name ?? "Workspace \(Date().formatted())", scope: request.scope ?? .workspace)
        case "restore", "restore-active":
            guard let layout else { throw WorkspaceError.invalid("Layout non trovato o nessun layout attivo.") }
            return try await restoreNow(layout, destination: request.destination ?? .saved, launchApps: request.launchApps ?? true)
        case "update", "update-active", "update-active-desktop":
            guard let layout else { throw WorkspaceError.invalid("Layout non trovato o nessun layout attivo.") }
            return try await updateNow(layout, desktopOnly: request.command == "update-active-desktop")
        case "show": showWindow(); return "Gestore layout aperto."
        case "diagnostics": return try diagnostics()
        case "capture-diagnostics":
            let snapshot = try capture.capture(name: "Diagnostica", scope: .workspace, excluded: library.preferences.excludedAppIDs)
            let known = Set(snapshot.windows.map { $0.record.windowID })
            let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let counts = snapshot.layout.apps.map { app in
                let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first?.processIdentifier
                let server = raw.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
                let extra = server.filter { !known.contains(($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0) }.count
                return "\(app.name): \(snapshot.windows.filter { $0.record.appID == app.id }.count) finestre AX, \(extra) superfici aggiuntive WindowServer"
            }
            return "Inventario in sola lettura, senza cambio desktop: \(snapshot.windows.count) finestre, \(snapshot.layout.apps.count) app.\n" + counts.joined(separator: "\n") + warningSuffix(snapshot.warnings)
        default: throw WorkspaceError.invalid("Comando non supportato: \(request.command)")
        }
    }
    func diagnostics() throws -> String {
        let displays = try spaces.displays()
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nApp: \(Bundle.main.bundleURL.path)\nBundle ID: \(Bundle.main.bundleIdentifier ?? "eseguibile senza bundle")\nPID: \(ProcessInfo.processInfo.processIdentifier)\nAccessibilità: \(AXIsProcessTrusted())\nSkyLight: \(spaces.available)\nMonitor con Spaces separati: \(NSScreen.screensHaveSeparateSpaces)\n" +
            displays.map { "\($0.name) [\($0.id)] \($0.spaces.count) Spaces, attivo \($0.activeSpaceID)" }.joined(separator: "\n")
    }
    private static func previewLibrary() -> Library {
        let frame = Rect(x: 0, y: 0, width: 1512, height: 982)
        let display = DisplayRecord(id: "preview-display", name: "MacBook Pro", frame: frame,
            visibleFrame: Rect(x: 0, y: 38, width: 1512, height: 900), isBuiltin: true,
            spaces: [SpaceRecord(id: 1, index: 1), SpaceRecord(id: 2, index: 2), SpaceRecord(id: 3, index: 3)], activeSpaceID: 1)
        let apps = [AppRecord(id: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app", hidden: false),
                    AppRecord(id: "com.apple.TextEdit", name: "TextEdit", path: "/System/Applications/TextEdit.app", hidden: false),
                    AppRecord(id: "com.apple.finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app", hidden: false)]
        let windows = [WindowRecord(appID: apps[0].id, title: "Documentazione del progetto", windowID: 1, processID: 1, ordinal: 0, displayID: display.id, spaceIndex: 1, frame: Rect(x: 20, y: 50, width: 740, height: 850)),
                       WindowRecord(appID: apps[1].id, title: "Idee per il prossimo rilascio", windowID: 2, processID: 1, ordinal: 0, displayID: display.id, spaceIndex: 1, frame: Rect(x: 780, y: 50, width: 700, height: 850)),
                       WindowRecord(appID: apps[2].id, title: "Progetti", windowID: 3, processID: 1, ordinal: 0, displayID: display.id, spaceIndex: 2, frame: Rect(x: 220, y: 120, width: 950, height: 700))]
        var result = Library()
        result.layouts = [WorkspaceCore.Layout(name: "Sviluppo", scope: .workspace, displays: [display], apps: apps, windows: windows),
                          WorkspaceCore.Layout(name: "Scrittura", scope: .desktop, displays: [display], apps: [apps[1]], windows: [windows[1]])]
        result.activeLayoutID = result.layouts[0].id
        return result
    }
}
