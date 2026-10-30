import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && abs(x) < 10_000_000 && abs(y) < 10_000_000 &&
        width > 0 && height > 0 && width < 1_000_000 && height < 1_000_000
    }
    public func relative(to bounds: Rect) -> Rect {
        Rect(x: (x - bounds.x) / bounds.width, y: (y - bounds.y) / bounds.height,
             width: width / bounds.width, height: height / bounds.height)
    }
    public func inBounds(_ bounds: Rect) -> Rect {
        Rect(x: bounds.x + x * bounds.width, y: bounds.y + y * bounds.height,
             width: width * bounds.width, height: height * bounds.height)
    }
    public func clamped(to bounds: Rect) -> Rect {
        let w = min(max(width, 80), bounds.width), h = min(max(height, 60), bounds.height)
        return Rect(x: min(max(x, bounds.x), bounds.x + bounds.width - w),
                    y: min(max(y, bounds.y), bounds.y + bounds.height - h), width: w, height: h)
    }
    public func overlap(with other: Rect) -> Double {
        max(0, min(x + width, other.x + other.width) - max(x, other.x)) *
        max(0, min(y + height, other.y + other.height) - max(y, other.y))
    }
}

public enum LayoutScope: String, Codable, CaseIterable, Sendable {
    case workspace, visibleDesktops, desktop
    public var label: String {
        switch self { case .workspace: return "Intero workspace"; case .visibleDesktops: return "Desktop visibili"; case .desktop: return "Desktop attivo" }
    }
}
public enum RestoreDestination: String, Codable, CaseIterable, Sendable {
    case saved, visible, newDesktops
    public var label: String {
        switch self { case .saved: return "Desktop salvati"; case .visible: return "Desktop visibili"; case .newDesktops: return "Nuovi desktop" }
    }
}
public struct SpaceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64
    /// One-based ordinal among ordinary desktops. Fullscreen spaces use an extra ordinal when restored.
    public var index: Int
    public var isFullscreen: Bool
    public init(id: UInt64, index: Int, isFullscreen: Bool = false) {
        self.id = id; self.index = index; self.isFullscreen = isFullscreen
    }
}
public struct DisplayRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var frame: Rect
    public var visibleFrame: Rect
    public var isBuiltin: Bool
    public var spaces: [SpaceRecord]
    public var activeSpaceID: UInt64
    public init(id: String, name: String, frame: Rect, visibleFrame: Rect, isBuiltin: Bool,
                spaces: [SpaceRecord], activeSpaceID: UInt64) {
        self.id = id; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
        self.isBuiltin = isBuiltin; self.spaces = spaces; self.activeSpaceID = activeSpaceID
    }
}
public struct AppRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String // bundle identifier
    public var name: String
    public var path: String
    public var hidden: Bool
    public init(id: String, name: String, path: String, hidden: Bool) {
        self.id = id; self.name = name; self.path = path; self.hidden = hidden
    }
}
public struct WindowRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var appID: String
    public var title: String
    public var identifier: String?
    public var windowID: UInt32
    public var processID: Int32
    public var launchDate: Date?
    public var ordinal: Int
    public var displayID: String
    public var spaceIndex: Int
    public var frame: Rect
    public var minimized: Bool
    public var fullscreen: Bool
    public var sticky: Bool
    public var stackingOrder: Int?
    public init(id: UUID = UUID(), appID: String, title: String, identifier: String? = nil,
                windowID: UInt32, processID: Int32, launchDate: Date? = nil, ordinal: Int,
                displayID: String, spaceIndex: Int, frame: Rect, minimized: Bool = false,
                fullscreen: Bool = false, sticky: Bool = false, stackingOrder: Int? = nil) {
        self.id = id; self.appID = appID; self.title = title; self.identifier = identifier
        self.windowID = windowID; self.processID = processID; self.launchDate = launchDate
        self.ordinal = ordinal; self.displayID = displayID; self.spaceIndex = spaceIndex
        self.frame = frame; self.minimized = minimized; self.fullscreen = fullscreen; self.sticky = sticky
        self.stackingOrder = stackingOrder
    }
}
public struct KeyBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var action: String
    public var layoutID: UUID?
    public var keyCode: UInt32
    public var modifiers: UInt32 // Carbon mask
    public init(id: UUID = UUID(), action: String, layoutID: UUID? = nil, keyCode: UInt32, modifiers: UInt32) {
        self.id = id; self.action = action; self.layoutID = layoutID; self.keyCode = keyCode; self.modifiers = modifiers
    }
}
public struct Layout: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var scope: LayoutScope
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRestoredAt: Date?
    public var displays: [DisplayRecord]
    public var apps: [AppRecord]
    public var windows: [WindowRecord]
    public var excludedAppIDs: Set<String>
    public init(id: UUID = UUID(), name: String, scope: LayoutScope, displays: [DisplayRecord],
                apps: [AppRecord], windows: [WindowRecord], excludedAppIDs: Set<String> = []) {
        self.id = id; self.name = name; self.scope = scope; createdAt = Date(); updatedAt = Date()
        self.displays = displays; self.apps = apps; self.windows = windows; self.excludedAppIDs = excludedAppIDs
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw WorkspaceError.invalid("Il nome deve contenere da 1 a 120 caratteri.")
        }
        guard Set(displays.map(\.id)).count == displays.count,
              Set(apps.map(\.id)).count == apps.count, Set(windows.map(\.id)).count == windows.count,
              displays.allSatisfy({ $0.frame.isValid && $0.visibleFrame.isValid && !$0.id.isEmpty &&
                  Set($0.spaces.map(\.index)).count == $0.spaces.count && $0.spaces.allSatisfy({ $0.index > 0 }) }),
              windows.allSatisfy({ w in w.frame.isValid && w.spaceIndex > 0 &&
                  displays.contains(where: { $0.id == w.displayID }) && apps.contains(where: { $0.id == w.appID }) }) else {
            throw WorkspaceError.invalid("Layout non valido: riferimenti o coordinate inconsistenti.")
        }
    }
}
public struct Preferences: Codable, Equatable, Sendable {
    public var excludedAppIDs: Set<String> = []
    public var hideOtherAppsForWorkspace = true
    public var hideOtherAppsForDesktop = true
    public var minimizeOtherWindows = true
    public var minimizeFinder = true
    public var returnToOriginalDesktop = true
    public var createMissingDesktops = true
    public var removeExtraDesktops = false
    public var adaptToDifferentDisplays = true
    public var restoreOnDisplayChange = false
    public var restoreOnWake = false
    public var notifySave = true
    public var notifyUpdate = true
    public var notifyRestore = true
    public var notifyWindow = false
    public var bindings: [KeyBinding] = []
    public init() {}
}
public struct Library: Codable, Equatable, Sendable {
    public var version = 1
    public var layouts: [Layout] = []
    public var activeLayoutID: UUID?
    public var preferences = Preferences()
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw WorkspaceError.invalid("Versione archivio non supportata: \(version).") }
        guard Set(layouts.map(\.id)).count == layouts.count else { throw WorkspaceError.invalid("ID layout duplicati.") }
        for layout in layouts { try layout.validate() }
    }
}
public enum WorkspaceError: LocalizedError {
    case invalid(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .unavailable(let s): return s }
    }
}
