import SwiftUI
import AppKit
import ServiceManagement
import Carbon
import WorkspaceCore

private let brandColor = Color(red: 0.25, green: 0.46, blue: 0.92)

struct MainView: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var started = false
    @State private var showingWarnings = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group.fill").font(.system(size: 25)).foregroundStyle(brandColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DeskAnchor").font(.headline)
                        Text("Il tuo spazio, ritrovato.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 22)
                List(selection: $store.navigation) {
                    Section {
                        ForEach(store.library.layouts) { layout in
                            HStack(spacing: 10) {
                                Image(systemName: layout.scope == .workspace ? "rectangle.3.group" : "macwindow")
                                    .symbolRenderingMode(.hierarchical).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(layout.name).fontWeight(.medium).lineLimit(1)
                                    Text("\(layout.windows.count) finestre · \(layout.displays.count) monitor").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if layout.id == store.library.activeLayoutID {
                                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).help("Layout attivo")
                                }
                            }.padding(.vertical, 5).tag(SidebarDestination.layout(layout.id))
                        }
                        if store.library.layouts.isEmpty {
                            Text("Nessun layout salvato").font(.callout).foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text("Layout salvati")
                            Spacer()
                            Text("\(store.library.layouts.count)").monospacedDigit()
                        }
                    }
                    Section("Impostazioni") {
                        ForEach(SettingsPage.allCases) { page in
                            Label(page.title, systemImage: page.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .padding(.vertical, 3)
                                .tag(SidebarDestination.settings(page))
                                .accessibilityIdentifier("settings.\(page.rawValue)")
                        }
                    }
                }.listStyle(.sidebar)
                Button { store.openNewLayout() } label: {
                    Label("Salva nuovo layout…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
                .buttonStyle(.bordered).controlSize(.large).disabled(store.busy).padding(.horizontal, 16).padding(.vertical, 14)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Label(store.hasAccessibility ? "Accessibilità attiva" : "Accessibilità richiesta", systemImage: store.hasAccessibility ? "checkmark.shield" : "lock.shield")
                        .font(.caption).foregroundStyle(store.hasAccessibility ? .green : .orange)
                    Text("Open source · solo sul tuo Mac").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }.navigationSplitViewColumnWidth(min: 250, ideal: 275, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if !store.hasAccessibility { PermissionBanner(store: store) }
                if case .settings(let page) = store.navigation { SettingsView(store: store, page: page).id(page) }
                else if let layout = store.selected { LayoutDetail(store: store, layout: layout).id(layout.id) }
                else {
                    VStack(spacing: 18) {
                        Image(systemName: "rectangle.3.group.bubble").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(brandColor)
                        Text("Ritrova il tuo workspace.").font(.largeTitle.weight(.semibold))
                        Text("Salva finestre, monitor e desktop.\nRiprendi il lavoro da dove lo avevi lasciato.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Salva il primo layout") { store.openNewLayout() }.buttonStyle(.borderedProminent).controlSize(.large).tint(brandColor)
                        Button("Importa layout…") { store.importLayouts() }.buttonStyle(.link)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    if store.busy { ProgressView().controlSize(.small); Button("Interrompi") { store.cancel() } }
                    Text(store.status.components(separatedBy: "\n").first ?? "Pronto").font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    Spacer()
                    if !store.operationWarnings.isEmpty {
                        Button("Avvisi (\(store.operationWarnings.count))") { showingWarnings = true }
                            .popover(isPresented: $showingWarnings) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Avvisi dell’operazione").font(.headline)
                                        ForEach(Array(store.operationWarnings.enumerated()), id: \.offset) { _, warning in
                                            Text(warning).font(.callout).textSelection(.enabled)
                                        }
                                    }.padding(20)
                                }.frame(width: 500, height: 320)
                            }
                    }
                    Menu { ForEach(Array(store.log.prefix(12).enumerated()), id: \.offset) { _, line in Text(line) } } label: { Image(systemName: "text.bubble") }.menuStyle(.borderlessButton).frame(width: 25).help("Esito e problemi delle operazioni")
                }.padding(12).background(.bar)
            }
        }.tint(brandColor)
        .toolbar {
            ToolbarItemGroup {
                Button { store.importLayouts() } label: { Label("Importa", systemImage: "square.and.arrow.down") }
                Button { store.exportLayouts() } label: { Label("Esporta archivio", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $store.isCreatingLayout) { NewLayoutView(store: store) }
        .alert("Operazione non completata", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onAppear {
            store.showWindow = { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
            if !started { started = true; store.start() }
        }
    }
}

struct PermissionBanner: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Consenti di gestire le finestre").font(.callout.weight(.semibold))
                Text("Attiva DeskAnchor in Privacy e sicurezza → Accessibilità.").font(.caption).foregroundStyle(.secondary)
                Text("Già attiva? Rimuovi la voce e aggiungi nuovamente questa copia dell’app.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Apri impostazioni") { store.openAccessibilitySettings() }
                HStack {
                    Button("Mostra questa app") { store.revealApplication() }
                    Button("Ricontrolla") { store.refreshAccessibility() }
                }.font(.caption)
            }
        }.padding(16).background(Color.orange.opacity(0.09))
    }
}

struct NewLayoutView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope: WorkspaceCore.LayoutScope = .workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Salva una configurazione", systemImage: "rectangle.stack.badge.plus").font(.title2.weight(.semibold))
            TextField("Nome, per esempio Sviluppo o Riunioni", text: $name).textFieldStyle(.roundedBorder)
            Picker("Cosa salvare", selection: $scope) { ForEach(LayoutScope.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.radioGroup)
            Text("Saranno salvati posizione, dimensioni, stato delle finestre, monitor e desktop. Le app escluse verranno ignorate.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salva") { store.create(name: name, scope: scope); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 470)
    }
}

struct LayoutDetail: View {
    @ObservedObject var store: AppStore
    var layout: WorkspaceCore.Layout
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var editingWindow: WindowRecord?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nome layout", text: $name, onCommit: { store.rename(layout, to: name) }).textFieldStyle(.plain).font(.largeTitle.weight(.semibold))
                        HStack { Text(layout.scope.label); if layout.id == store.library.activeLayoutID { Label("Attivo", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }.font(.callout).foregroundStyle(.secondary)
                        Text("Aggiornato \(layout.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Menu {
                        Button("Rinomina") { store.rename(layout, to: name) }
                        Button("Duplica") { store.duplicate(layout) }
                        Button("Esporta…") { store.exportLayouts(selected: layout) }
                        Divider(); Button("Elimina layout…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }.menuStyle(.borderlessButton).frame(width: 30)
                }
                HStack(spacing: 10) {
                    Button { store.restore(layout) } label: { Label("Ripristina", systemImage: "arrow.counterclockwise") }.buttonStyle(.borderedProminent).controlSize(.large)
                    Menu("Altre opzioni") {
                        Button("Senza avviare applicazioni") { store.restore(layout, launchApps: false) }
                        Button("Sui desktop visibili") { store.restore(layout, destination: .visible) }
                        Button("Su nuovi desktop") { store.restore(layout, destination: .newDesktops) }
                    }.controlSize(.large).fixedSize()
                    Spacer()
                    Menu {
                        Button("Aggiorna tutto il layout") { store.update(layout) }
                        Button("Aggiorna solo il desktop attivo") { store.update(layout, desktopOnly: true) }
                    } label: { Label("Aggiorna", systemImage: "arrow.triangle.2.circlepath") }.controlSize(.large).fixedSize()
                }
                HStack(spacing: 20) {
                    Metric(value: layout.apps.count, label: "app", icon: "app.dashed")
                    Metric(value: layout.windows.count, label: "finestre", icon: "macwindow")
                    Metric(value: layout.displays.count, label: "monitor", icon: "display")
                    Metric(value: layout.displays.reduce(0) { $0 + $1.spaces.count }, label: "desktop", icon: "rectangle.3.group")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("MONITOR E DESKTOP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(layout.displays) { display in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display").font(.headline); Spacer(); Text("\(Int(display.frame.width)) × \(Int(display.frame.height))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            ScrollView(.horizontal, showsIndicators: true) { HStack(alignment: .top, spacing: 12) {
                                ForEach(display.spaces) { space in
                                    VStack(spacing: 6) {
                                        DesktopPreview(display: display, windows: layout.windows.filter { $0.displayID == display.id && $0.spaceIndex == space.index })
                                            .frame(width: 110, height: 70)
                                        Text("\(space.isFullscreen ? "Schermo intero" : "Desktop") \(space.index)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(.bottom, 4) }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("APPLICAZIONI E FINESTRE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(layout.apps) { app in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 30, height: 30)
                                Text(app.name).font(.headline)
                                if layout.excludedAppIDs.contains(app.id) { Text("Esclusa da questo layout").font(.caption).foregroundStyle(.orange) }
                                Spacer()
                                Menu {
                                    Button(layout.excludedAppIDs.contains(app.id) ? "Includi in questo layout" : "Escludi da questo layout") { store.excludeApp(app.id, in: layout) }
                                    Button("Escludi globalmente") { store.library.preferences.excludedAppIDs.insert(app.id); store.savePreferences() }
                                    Divider(); Button("Rimuovi dal layout", role: .destructive) { store.removeApp(app.id, from: layout) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                            }
                            ForEach(layout.windows.filter { $0.appID == app.id }) { window in
                                HStack {
                                    Image(systemName: window.minimized ? "minus.rectangle" : "macwindow").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(window.title.isEmpty ? "Finestra senza titolo" : window.title).lineLimit(1)
                                        Text("Desktop \(window.spaceIndex) · \(Int(window.frame.width)) × \(Int(window.frame.height)) · x \(Int(window.frame.x)), y \(Int(window.frame.y))\(window.sticky ? " · tutti i desktop" : "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { editingWindow = window } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Modifica posizione, dimensioni e desktop")
                                }.padding(.leading, 40)
                            }
                        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if layout.apps.isEmpty { Text("Nessuna app salvata.").foregroundStyle(.secondary) }
                }
                if !layout.excludedAppIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ESCLUSIONI DEL LAYOUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(layout.excludedAppIDs.sorted(), id: \.self) { id in
                            HStack {
                                Text(layout.apps.first { $0.id == id }?.name ?? id).font(.callout)
                                Spacer(); Button("Includi di nuovo") { store.excludeApp(id, in: layout) }
                            }
                        }
                    }
                }
            }.padding(30).disabled(store.busy)
        }
        .onAppear { name = layout.name }.onChange(of: layout.name) { name = $0 }
        .confirmationDialog("Eliminare «\(layout.name)»?", isPresented: $confirmDelete) { Button("Elimina", role: .destructive) { store.delete(layout) } }
        .sheet(item: $editingWindow) { window in EditWindowView(window: window, displays: layout.displays) { store.editWindow($0, in: layout) } }
    }
}
struct Metric: View {
    let value: Int; let label: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(brandColor)
            HStack(alignment: .firstTextBaseline, spacing: 5) { Text("\(value)").font(.title2.weight(.semibold)); Text(label).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(brandColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct DesktopPreview: View {
    let display: DisplayRecord; let windows: [WindowRecord]
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [brandColor.opacity(0.2), .indigo.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(Array(windows.reversed().enumerated()), id: \.element.id) { index, window in
                    let r = window.frame.relative(to: display.frame)
                    RoundedRectangle(cornerRadius: 2).fill(window.minimized ? Color.gray.opacity(0.2) : Color.white.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(brandColor.opacity(0.5), lineWidth: 0.6))
                        .frame(width: max(4, r.width * proxy.size.width), height: max(4, r.height * proxy.size.height))
                        .offset(x: r.x * proxy.size.width, y: r.y * proxy.size.height)
                }
            }.clipped().clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
struct EditWindowView: View {
    @State var window: WindowRecord
    let displays: [DisplayRecord]
    let save: (WindowRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Modifica finestra salvata").font(.title2.weight(.semibold))
            Text(window.title).lineLimit(2).foregroundStyle(.secondary)
            Form {
                Picker("Monitor", selection: $window.displayID) { ForEach(displays) { Text($0.name).tag($0.id) } }
                Stepper("Desktop \(window.spaceIndex)", value: $window.spaceIndex, in: 1...32)
                HStack { TextField("X", value: $window.frame.x, format: .number); TextField("Y", value: $window.frame.y, format: .number) }
                HStack { TextField("Larghezza", value: $window.frame.width, format: .number); TextField("Altezza", value: $window.frame.height, format: .number) }
                Toggle("Minimizzata", isOn: $window.minimized)
                Toggle("Schermo intero simulato", isOn: $window.fullscreen)
            }.textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Annulla") { dismiss() }; Button("Salva") { save(window); dismiss() }.buttonStyle(.borderedProminent).disabled(!window.frame.isValid) }
        }.padding(28).frame(width: 440)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    let page: SettingsPage
    @State private var recordingAction = "restore"
    @State private var recordingLayout: UUID?
    @State private var recording = false
    @State private var diagnostics = ""
    private var prefs: Binding<Preferences> { $store.library.preferences }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(brandColor)
                    .frame(width: 48, height: 48).background(brandColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.largeTitle.weight(.semibold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general:
                        GroupBox("Ripristino e visibilità") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Nascondi app non salvate nei workspace", isOn: prefs.hideOtherAppsForWorkspace)
                                Toggle("Nascondi app non salvate nei layout desktop", isOn: prefs.hideOtherAppsForDesktop)
                                Toggle("Minimizza finestre non presenti nel layout", isOn: prefs.minimizeOtherWindows)
                                Toggle("Minimizza Finder quando non è nel layout", isOn: prefs.minimizeFinder)
                                Toggle("Ritorna al desktop iniziale dopo il ripristino di una finestra", isOn: prefs.returnToOriginalDesktop)
                            }.padding(10)
                        }
                        GroupBox("Monitor e desktop") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Crea i desktop mancanti", isOn: prefs.createMissingDesktops)
                                Toggle("Rimuovi desktop in eccesso nel ripristino di workspace", isOn: prefs.removeExtraDesktops)
                                Text("Rimuovere un desktop sposta le sue finestre su un altro desktop; le app restano aperte.").font(.caption).foregroundStyle(.secondary)
                                Toggle("Adatta il layout ai monitor disponibili", isOn: prefs.adaptToDifferentDisplays)
                                Text("Per mantenere l’ordine dei desktop disattiva “Riorganizza automaticamente gli Spaces” in Scrivania e Dock. Per il trascinamento servono Ctrl+←/→ nelle abbreviazioni di Mission Control.").font(.caption).foregroundStyle(.secondary)
                            }.padding(10)
                        }
                        GroupBox("Automazioni") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Avvia al login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: store.setLaunchAtLogin))
                                Toggle("Ripristina il layout attivo quando cambiano i monitor", isOn: prefs.restoreOnDisplayChange)
                                Toggle("Ripristina il layout attivo al risveglio", isOn: prefs.restoreOnWake)
                                Text("I ripristini automatici non avviano applicazioni chiuse.").font(.caption).foregroundStyle(.secondary)
                            }.padding(10)
                        }
                        GroupBox("Notifiche") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Salvataggio", isOn: prefs.notifySave); Toggle("Aggiornamento", isOn: prefs.notifyUpdate)
                                Toggle("Fine ripristino", isOn: prefs.notifyRestore); Toggle("Ripristino finestra", isOn: prefs.notifyWindow)
                                Button("Consenti notifiche di sistema…") { store.enableNotifications() }
                            }.padding(10)
                        }
                    case .exclusions:
                        Text("Le app escluse vengono ignorate durante salvataggio, avvio, ripristino, occultamento e minimizzazione. Le esclusioni valgono anche per i vecchi layout.").foregroundStyle(.secondary)
                        ForEach(store.library.preferences.excludedAppIDs.sorted(), id: \.self) { id in
                            HStack {
                                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url?.path ?? "")).resizable().frame(width: 28, height: 28)
                                Text(url?.deletingPathExtension().lastPathComponent ?? id); Spacer()
                                Button { store.library.preferences.excludedAppIDs.remove(id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Button { store.addExcludedApp() } label: { Label("Aggiungi applicazioni…", systemImage: "plus") }
                    case .shortcuts:
                        Text("Registra una combinazione con ⌘, ⌥ o ⌃. Puoi assegnarla al layout attivo o a un layout specifico.").foregroundStyle(.secondary)
                        ForEach(store.library.preferences.bindings) { binding in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(ShortcutActions.label(binding.action))
                                    Text(binding.layoutID.flatMap { id in store.library.layouts.first { $0.id == id }?.name } ?? "Layout attivo").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Text(ShortcutManager.description(binding)).font(.system(.body, design: .monospaced)).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                Button { store.library.preferences.bindings.removeAll { $0.id == binding.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }.padding(10)
                        }
                        Divider()
                        Picker("Azione", selection: $recordingAction) { ForEach(ShortcutActions.all, id: \.0) { Text($0.1).tag($0.0) } }
                        Picker("Layout", selection: $recordingLayout) {
                            Text("Layout attivo").tag(nil as UUID?)
                            ForEach(store.library.layouts) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if recording {
                            KeyRecorder { code, modifiers in
                                recording = false
                                guard modifiers != 0 else { return }
                                let binding = KeyBinding(action: recordingAction, layoutID: recordingLayout, keyCode: code, modifiers: modifiers)
                                if store.library.preferences.bindings.contains(where: { $0.keyCode == code && $0.modifiers == modifiers }) { store.error = "Combinazione già assegnata." }
                                else { store.library.preferences.bindings.append(binding) }
                            }.frame(height: 45)
                            Text("Premi la combinazione. Esc per annullare.").foregroundStyle(.secondary)
                        } else { Button("Registra scorciatoia…") { recording = true } }
                    case .diagnostics:
                        Text("Archivio locale").font(.headline)
                        Text(AppPaths.library.path).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Mostra archivio nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.library]) }
                        Button("Aggiorna diagnostica (sola lettura)") { diagnostics = (try? store.diagnostics()) ?? "Spaces non disponibili" }
                        Text(diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                        Divider(); Text("Ultime operazioni").font(.headline)
                        ForEach(Array(store.log.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        Divider()
                        Text("DeskAnchor · MIT\nImplementazione indipendente. Nessuna telemetria o servizio cloud. Il ripristino riutilizza le finestre aperte; non ricrea schede, documenti o progetti chiusi. Stage Manager non è supportato. Le finestre a schermo intero sono ripristinate in modalità simulata.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: 780, alignment: .leading).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).disabled(store.busy)
            }
        }.padding(30).onChange(of: store.library.preferences) { _ in store.savePreferences() }
    }
}
enum ShortcutActions {
    static let all = [("restore", "Ripristina layout"), ("restore-no-launch", "Ripristina senza avviare app"), ("restore-visible", "Ripristina sui desktop visibili"), ("restore-new", "Ripristina su nuovi desktop"), ("update", "Aggiorna layout"), ("update-desktop", "Aggiorna desktop attivo"), ("restore-window", "Ripristina finestra attiva"), ("restore-window-all", "Ripristina finestra da tutti i layout"), ("save", "Salva workspace"), ("show", "Apri gestore layout")]
    static func label(_ action: String) -> String { all.first { $0.0 == action }?.1 ?? action }
}
struct KeyRecorder: NSViewRepresentable {
    let onKey: (UInt32, UInt32) -> Void
    func makeNSView(context: Context) -> RecorderView { let view = RecorderView(); view.onKey = onKey; DispatchQueue.main.async { view.window?.makeFirstResponder(view) }; return view }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.onKey = onKey }
    final class RecorderView: NSView {
        var onKey: (UInt32, UInt32) -> Void = { _, _ in }
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onKey(0, 0); return }
            let flags = event.modifierFlags
            guard !flags.intersection([.command, .control, .option]).isEmpty else { return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            onKey(UInt32(event.keyCode), modifiers)
        }
    }
}
