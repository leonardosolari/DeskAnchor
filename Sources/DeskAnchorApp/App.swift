import SwiftUI
import AppKit
import WorkspaceCore

@main @MainActor struct DeskAnchorApplication: App {
    @StateObject private var store: AppStore
    init() {
        _store = StateObject(wrappedValue: AppStore(preview: CommandLine.arguments.contains("--preview")))
        if CommandLine.arguments.contains("--diagnostics-only") {
            let spaces = SpacesService()
            do {
                let displays = try spaces.displays()
                print("SkyLight: \(spaces.available); Accessibilità: \(AXIsProcessTrusted()); monitor: \(displays.count)")
                for d in displays { print("\(d.name): \(d.spaces.count) Spaces, attivo \(d.activeSpaceID)") }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApplication.shared.terminate(nil) }
        }
    }
    var body: some Scene {
        Window("DeskAnchor", id: "manager") {
            MainView(store: store).frame(minWidth: 940, minHeight: 640)
        }.defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Salva nuovo layout…") { store.openNewLayout() }.keyboardShortcut("n")
                Button("Importa layout…") { store.importLayouts() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Impostazioni…") { store.openSettings() }.keyboardShortcut(",")
            }
        }
        MenuBarExtra("DeskAnchor", systemImage: "rectangle.3.group") { WorkspaceMenu(store: store) }
    }
}

struct WorkspaceMenu: View {
    @ObservedObject var store: AppStore
    private var otherLayouts: [WorkspaceCore.Layout] { store.library.layouts.filter { $0.id != store.library.activeLayoutID } }
    var body: some View {
        if store.busy {
            Text(store.status.prefix(90))
            Button { store.cancel() } label: { Label("Interrompi operazione", systemImage: "stop.circle") }
        } else {
            if let active = store.active {
                Text("Attivo: \(active.name)")
                Button { store.restore(active) } label: { Label("Ripristina layout", systemImage: "arrow.counterclockwise") }
                    .help("Riporta le finestre nelle posizioni salvate in «\(active.name)».")
                Button { store.update(active) } label: { Label("Aggiorna salvataggio", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Sostituisce «\(active.name)» con le posizioni attuali delle finestre.")
                Menu {
                    Section("Ripristino") {
                        Button { store.restore(active, launchApps: false) } label: { Label("Senza avviare applicazioni", systemImage: "app.dashed") }
                        Button { store.restore(active, destination: .visible) } label: { Label("Sui desktop visibili", systemImage: "rectangle.on.rectangle") }
                        Button { store.restore(active, destination: .newDesktops) } label: { Label("Su nuovi desktop", systemImage: "rectangle.badge.plus") }
                    }
                    Section("Aggiornamento") {
                        Button { store.update(active, desktopOnly: true) } label: { Label("Salva solo il desktop attivo", systemImage: "desktopcomputer") }
                    }
                    Section("Finestra in primo piano") {
                        Button { store.restoreFocused(allLayouts: false) } label: { Label("Posizione nel layout attivo", systemImage: "macwindow") }
                        Button { store.restoreFocused(allLayouts: true) } label: { Label("Ultima posizione tra tutti i layout", systemImage: "clock.arrow.circlepath") }
                    }
                } label: { Label("Altre azioni", systemImage: "ellipsis.circle") }
                Divider()
            }
            if !otherLayouts.isEmpty {
                Menu {
                    ForEach(otherLayouts) { layout in
                        Button { store.restore(layout) } label: {
                            Label(layout.name, systemImage: layout.scope == .workspace ? "rectangle.3.group" : "macwindow")
                        }
                    }
                } label: { Label(store.active == nil ? "Ripristina un layout" : "Passa a un altro layout", systemImage: "rectangle.3.group") }
            }
            Button { store.openNewLayout() } label: { Label("Salva nuovo layout…", systemImage: "plus.rectangle.on.rectangle") }
            if store.active == nil && !store.library.layouts.isEmpty {
                Button { store.restoreFocused(allLayouts: true) } label: {
                    Label("Ripristina finestra dall’ultimo layout", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        Divider()
        Button { store.openLayouts() } label: { Label("Apri gestore layout", systemImage: "sidebar.left") }
        Button { store.openSettings() } label: { Label("Impostazioni…", systemImage: "gearshape") }.keyboardShortcut(",")
        Divider()
        Button { NSApp.terminate(nil) } label: { Label("Esci da DeskAnchor", systemImage: "power") }.keyboardShortcut("q")
    }
}
