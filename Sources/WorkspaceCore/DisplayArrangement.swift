import Foundation

public struct DisplayPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Quartz coordinates: the primary display starts at (0, 0), and Y grows downwards.
    public var frame: Rect
    public var isPrimary: Bool { frame.x == 0 && frame.y == 0 }
}

/// Kept separate from window geometry so updating one desktop cannot change the saved setup.
public struct DisplayArrangement: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var displays: [DisplayPlacement]

    public init(displays: [DisplayRecord], enabled: Bool = true) throws {
        self.enabled = enabled
        self.displays = displays.map { DisplayPlacement(id: $0.id, name: $0.name, frame: $0.frame) }
        try validate()
    }

    public func validate() throws {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.filter(\.isPrimary).count == 1,
              displays.allSatisfy({ !$0.id.isEmpty && $0.frame.isValid &&
                  Int32(exactly: $0.frame.x) != nil && Int32(exactly: $0.frame.y) != nil }) else {
            throw WorkspaceError.invalid("Disposizione monitor non valida: coordinate, identificatori o schermo principale inconsistenti.")
        }
        for (index, display) in displays.enumerated() {
            guard displays.dropFirst(index + 1).allSatisfy({ display.frame.overlap(with: $0.frame) == 0 }) else {
                throw WorkspaceError.invalid("Disposizione monitor non valida: gli schermi si sovrappongono o sono duplicati.")
            }
        }
        // Quartz adjusts disconnected arrangements. Reject them rather than silently moving screens elsewhere.
        var connected = Set([displays[0].id])
        while true {
            let adjacent = displays.filter { candidate in
                !connected.contains(candidate.id) && displays.contains { existing in
                    connected.contains(existing.id) && Self.touches(candidate.frame, existing.frame)
                }
            }
            if adjacent.isEmpty { break }
            connected.formUnion(adjacent.map(\.id))
        }
        guard connected.count == displays.count else {
            throw WorkspaceError.invalid("Disposizione monitor non valida: gli schermi devono essere adiacenti.")
        }
    }

    /// Physical displays must match exactly. Window fallback matching must never rearrange other hardware.
    /// Changing resolution/rotation needs a new capture, since the old origins can leave gaps or overlaps.
    public func plan(current: [DisplayRecord]) throws -> [DisplayPlacement] {
        try validate()
        guard enabled else { return [] }
        guard Set(displays.map(\.id)) == Set(current.map(\.id)), displays.count == current.count else {
            throw WorkspaceError.unavailable("Disposizione monitor non ripristinata: collega tutti e soli i monitor del setup salvato.")
        }
        guard displays.allSatisfy({ saved in
            current.contains { $0.id == saved.id && $0.frame.width == saved.frame.width && $0.frame.height == saved.frame.height }
        }) else {
            throw WorkspaceError.unavailable("Disposizione monitor non ripristinata: risoluzione o rotazione diversa. Salva di nuovo la disposizione attuale.")
        }
        guard !isApplied(to: current) else { return [] }
        return displays.sorted { $0.isPrimary && !$1.isPrimary }
    }

    public func isApplied(to current: [DisplayRecord]) -> Bool {
        displays.count == current.count && displays.allSatisfy { saved in
            current.contains { $0.id == saved.id && $0.frame == saved.frame }
        }
    }

    private static func touches(_ a: Rect, _ b: Rect) -> Bool {
        let horizontal = (a.x + a.width == b.x || b.x + b.width == a.x) &&
            max(a.y, b.y) <= min(a.y + a.height, b.y + b.height)
        let vertical = (a.y + a.height == b.y || b.y + b.height == a.y) &&
            max(a.x, b.x) <= min(a.x + a.width, b.x + b.width)
        return horizontal || vertical
    }
}
