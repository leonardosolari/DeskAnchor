import XCTest
@testable import WorkspaceCore

final class MigrationTests: XCTestCase {
    func testCopiesLegacyLibraryWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LibraryStore(url: root.appendingPathComponent("old/library.json"))
        var original = Library()
        let bounds = Rect(x: 0, y: 0, width: 1440, height: 900)
        let display = DisplayRecord(id: "display", name: "Display", frame: bounds, visibleFrame: bounds,
                                    isBuiltin: true, spaces: [SpaceRecord(id: 1, index: 1)], activeSpaceID: 1)
        let app = AppRecord(id: "org.example.editor", name: "Editor", path: "/Applications/Editor.app", hidden: false)
        let window = WindowRecord(appID: app.id, title: "Document", windowID: 42, processID: 100,
                                  ordinal: 0, displayID: display.id, spaceIndex: 1,
                                  frame: Rect(x: 40, y: 50, width: 700, height: 500))
        var layout = Layout(name: "Development", scope: .workspace, displays: [display], apps: [app], windows: [window])
        layout.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        layout.updatedAt = layout.createdAt
        original.layouts = [layout]
        original.activeLayoutID = layout.id
        original.preferences.excludedAppIDs = ["org.example.passwordmanager"]
        original.preferences.bindings = [KeyBinding(action: "restore", keyCode: 15, modifiers: 256)]
        try legacy.save(original)
        let originalBytes = try Data(contentsOf: legacy.url)
        let current = LibraryStore(url: root.appendingPathComponent("new/library.json"))
        XCTAssertTrue(try current.migrateIfNeeded(from: [legacy.url]))
        XCTAssertEqual(try current.load(), original)
        XCTAssertEqual(try Data(contentsOf: legacy.url), originalBytes)
        XCTAssertFalse(try current.migrateIfNeeded(from: [legacy.url]))
    }

    func testCurrentLibraryAlwaysTakesPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LibraryStore(url: root.appendingPathComponent("old.json"))
        let current = LibraryStore(url: root.appendingPathComponent("new.json"))
        var oldLibrary = Library(); oldLibrary.preferences.excludedAppIDs = ["old"]
        var newLibrary = Library(); newLibrary.preferences.excludedAppIDs = ["new"]
        try legacy.save(oldLibrary); try current.save(newLibrary)
        XCTAssertFalse(try current.migrateIfNeeded(from: [legacy.url]))
        XCTAssertEqual(try current.load(fallbackURLs: [legacy.url]), newLibrary)
    }

    func testMigrationPrefersTheFirstExistingLegacyArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing/library.json")
        let recent = LibraryStore(url: root.appendingPathComponent("recent/library.json"))
        let earlier = LibraryStore(url: root.appendingPathComponent("earlier/library.json"))
        let current = LibraryStore(url: root.appendingPathComponent("current/library.json"))
        var recentLibrary = Library(); recentLibrary.preferences.excludedAppIDs = ["recent"]
        var earlierLibrary = Library(); earlierLibrary.preferences.excludedAppIDs = ["earlier"]
        try recent.save(recentLibrary); try earlier.save(earlierLibrary)
        let recentBytes = try Data(contentsOf: recent.url)
        let earlierBytes = try Data(contentsOf: earlier.url)

        XCTAssertTrue(try current.migrateIfNeeded(from: [missing, recent.url, earlier.url]))
        XCTAssertEqual(try current.load(), recentLibrary)
        XCTAssertEqual(try Data(contentsOf: recent.url), recentBytes)
        XCTAssertEqual(try Data(contentsOf: earlier.url), earlierBytes)
    }

    func testInvalidLegacyLibraryDoesNotCreateNewArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppPaths.prepare(root)
        let legacy = root.appendingPathComponent("invalid.json")
        try Data("invalid data".utf8).write(to: legacy)
        let current = LibraryStore(url: root.appendingPathComponent("new/library.json"))
        XCTAssertThrowsError(try current.migrateIfNeeded(from: [legacy]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.url.path))
    }

    func testReadOnlyFallbackDoesNotMigrateOrCreateDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LibraryStore(url: root.appendingPathComponent("old.json"))
        var original = Library(); original.preferences.restoreOnWake = true
        try legacy.save(original)
        let current = LibraryStore(url: root.appendingPathComponent("new/library.json"))
        XCTAssertEqual(try current.load(fallbackURLs: [legacy.url]), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.url.deletingLastPathComponent().path))
    }
}
