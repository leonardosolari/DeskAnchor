import Foundation
import AppKit
import WorkspaceCore

@main enum DeskAnchorCLI {
    static func main() {
        do { try execute() } catch { fputs("deskanchor: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func execute() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] || args == ["-h"] { print(help); return }
        let verb = args.removeFirst()
        let supported = ["--list", "--create", "--restore", "--restore-active", "--update", "--update-active", "--update-active-desktop", "--show", "--diagnostics", "--capture-diagnostics"]
        guard supported.contains(verb) else { throw WorkspaceError.invalid("Comando sconosciuto: \(verb). Usa --help.") }
        var name: String?, scope: LayoutScope?, destination: RestoreDestination?, launchApps = true
        if ["--restore", "--update"].contains(verb) {
            guard let first = args.first, !first.hasPrefix("--") else { throw WorkspaceError.invalid("Specifica il nome o UUID del layout.") }
            name = args.removeFirst()
        } else if verb == "--create", let first = args.first, !first.hasPrefix("--") { name = args.removeFirst() }
        for arg in args {
            if arg.hasPrefix("--launch-apps=") {
                let value = String(arg.dropFirst("--launch-apps=".count))
                guard value == "true" || value == "false" else { throw WorkspaceError.invalid("--launch-apps accetta true o false.") }
                launchApps = value == "true"
            } else if arg.hasPrefix("--scope=") {
                scope = LayoutScope(rawValue: String(arg.dropFirst("--scope=".count)))
                guard scope != nil else { throw WorkspaceError.invalid("Scope: workspace, visibleDesktops, desktop.") }
            } else if arg.hasPrefix("--destination=") {
                destination = RestoreDestination(rawValue: String(arg.dropFirst("--destination=".count)))
                guard destination != nil else { throw WorkspaceError.invalid("Destinazione: saved, visible, newDesktops.") }
            } else { throw WorkspaceError.invalid("Opzione sconosciuta: \(arg)") }
        }
        // Listing is read-only and works even with the app closed.
        if verb == "--list" {
            let library = try LibraryStore().load(fallbackURLs: AppPaths.legacyLibraries)
            print(library.layouts.map { "\($0.id.uuidString)\t\($0.name)\t\($0.scope.rawValue)\($0.id == library.activeLayoutID ? "\tactive" : "")" }.joined(separator: "\n"))
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty {
            throw WorkspaceError.unavailable("Avvia DeskAnchor.app prima di inviare comandi.")
        }
        let request = CommandRequest(command: String(verb.dropFirst(2)), name: name, scope: scope, destination: destination, launchApps: launchApps)
        try AppPaths.prepare(AppPaths.inbox)
        let requestURL = AppPaths.inbox.appendingPathComponent(request.id.uuidString + ".request.json")
        let responseURL = AppPaths.inbox.appendingPathComponent(request.id.uuidString + ".response.json")
        defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: responseURL) }
        try LibraryStore.encoder.encode(request).write(to: requestURL, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(AppPaths.notification), object: nil,
                                                                    userInfo: ["id": request.id.uuidString], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL) {
                let response = try LibraryStore.decoder.decode(CommandResponse.self, from: data)
                guard response.success else { throw WorkspaceError.unavailable(response.message) }
                print(response.message); return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw WorkspaceError.unavailable("Nessuna risposta entro 180 secondi. Controlla il gestore layout per l’esito dell’operazione.")
    }
    static let help = """
    DeskAnchor — workspace nativi macOS, open source

    deskanchor --list
    deskanchor --create ["Nome"] [--scope=workspace|visibleDesktops|desktop]
    deskanchor --restore "Nome o UUID" [--launch-apps=true|false] [--destination=saved|visible|newDesktops]
    deskanchor --restore-active [--launch-apps=true|false]
    deskanchor --update "Nome o UUID"
    deskanchor --update-active
    deskanchor --update-active-desktop
    deskanchor --show
    deskanchor --diagnostics
    deskanchor --capture-diagnostics
    deskanchor --help

    Il gestore deve essere in esecuzione per tutti i comandi tranne --list e --help.
    I comandi attendono l’esito dell’operazione. Exit code 1 in caso di errore.
    """
}
