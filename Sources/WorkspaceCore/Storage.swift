import Foundation

public enum AppPaths {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskAnchor", isDirectory: true)
    }
    public static var library: URL { directory.appendingPathComponent("library.json") }
    /// Read the most recent development identity first. Original archives are never changed.
    public static var legacyLibraries: [URL] {
        let support = directory.deletingLastPathComponent()
        return ["DeskCairn", "SpencerClone"].map {
            support.appendingPathComponent($0).appendingPathComponent("library.json")
        }
    }
    public static var inbox: URL { directory.appendingPathComponent("Commands", isDirectory: true) }
    public static let notification = "org.deskanchor.command"
    public static let bundleID = "org.deskanchor.app"
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
public struct LibraryStore {
    public let url: URL
    public init(url: URL = AppPaths.library) { self.url = url }
    public func load(fallbackURLs: [URL] = []) throws -> Library {
        guard let source = ([url] + fallbackURLs).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return Library() }
        let result = try Self.decoder.decode(Library.self, from: Data(contentsOf: source))
        try result.validate()
        return result
    }
    @discardableResult public func migrateIfNeeded(from legacyURLs: [URL]) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path),
              legacyURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        let previous = try load(fallbackURLs: legacyURLs)
        try save(previous)
        return true
    }
    public func save(_ library: Library) throws {
        try library.validate()
        try AppPaths.prepare(url.deletingLastPathComponent())
        let data = try Self.encoder.encode(library)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            try previous.write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .millisecondsSince1970; return e
    }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }
}
public struct CommandRequest: Codable {
    public var id: UUID
    public var command: String
    public var name: String?
    public var scope: LayoutScope?
    public var destination: RestoreDestination?
    public var launchApps: Bool?
    public init(command: String, name: String? = nil, scope: LayoutScope? = nil,
                destination: RestoreDestination? = nil, launchApps: Bool? = nil) {
        id = UUID(); self.command = command; self.name = name; self.scope = scope
        self.destination = destination; self.launchApps = launchApps
    }
}
public struct CommandResponse: Codable {
    public var success: Bool
    public var message: String
    public init(success: Bool, message: String) { self.success = success; self.message = message }
}
