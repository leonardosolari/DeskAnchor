import AppKit
import WorkspaceCore

/// Uses public Quartz APIs; resolution, rotation and mirroring are never changed.
@MainActor enum DisplayArrangementService {
    static func capture(_ displays: [DisplayRecord]) throws -> DisplayArrangement {
        let connected = try connectedDisplays()
        guard Set(connected.keys) == Set(displays.map(\.id)) else {
            throw WorkspaceError.unavailable("Impossibile leggere tutti i monitor. Attendi il completamento del collegamento e riprova.")
        }
        return try DisplayArrangement(displays: displays)
    }

    /// Returns false for a disabled or already applied arrangement.
    static func restore(_ arrangement: DisplayArrangement, spaces: SpacesService) async throws -> Bool {
        let targets = try arrangement.plan(current: spaces.displays())
        guard !targets.isEmpty else { return false }
        try Task.checkCancellation()
        let connected = try connectedDisplays()
        guard Set(connected.keys) == Set(targets.map(\.id)) else {
            throw WorkspaceError.unavailable("Monitor cambiati durante il ripristino della disposizione. Riprova dopo il collegamento.")
        }

        var configuration: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&configuration), action: "iniziare la configurazione")
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(configuration) } }
        for target in targets {
            try Task.checkCancellation()
            guard let displayID = connected[target.id],
                  let x = Int32(exactly: target.frame.x), let y = Int32(exactly: target.frame.y) else {
                throw WorkspaceError.invalid("Coordinate monitor non valide.")
            }
            try check(CGConfigureDisplayOrigin(configuration, displayID, x, y), action: "posizionare un monitor")
        }
        // Complete consumes the configuration even on failure. Session scope survives quitting the app.
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        completed = true
        try check(result, action: "applicare la disposizione")

        // Both AppKit geometry and Spaces must reflect the transaction before any window moves.
        let ready = try await AsyncPolling.until(timeout: 5, interval: 0.15) {
            guard let displays = try? spaces.displays(), arrangement.isApplied(to: displays) else { return false }
            return targets.allSatisfy { target in
                guard let displayID = connected[target.id] else { return false }
                let bounds = CGDisplayBounds(displayID)
                return bounds.origin.x == target.frame.x && bounds.origin.y == target.frame.y
            }
        }
        guard ready else {
            throw WorkspaceError.unavailable("macOS non ha confermato la disposizione richiesta. Le finestre saranno adattate alla disposizione effettiva.")
        }
        return true
    }

    private static func connectedDisplays() throws -> [String: CGDirectDisplayID] {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), action: "leggere i monitor")
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetOnlineDisplayList(count, &ids, &count), action: "leggere i monitor")
        var result: [String: CGDirectDisplayID] = [:]
        for id in ids.prefix(Int(count)) {
            guard CGDisplayIsInMirrorSet(id) == 0 else {
                throw WorkspaceError.unavailable("Disposizione monitor non disponibile con Duplica schermo attivo. Usa i monitor come schermi estesi.")
            }
            guard CGDisplayIsActive(id) != 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let key = CFUUIDCreateString(nil, uuid) else { continue }
            result[key as String] = id
        }
        return result
    }

    private static func check(_ error: CGError, action: String) throws {
        guard error == .success else {
            throw WorkspaceError.unavailable("Impossibile \(action) (errore macOS \(error.rawValue)).")
        }
    }
}
