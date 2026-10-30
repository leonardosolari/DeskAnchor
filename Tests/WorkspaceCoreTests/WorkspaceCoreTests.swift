import XCTest
@testable import WorkspaceCore

final class WorkspaceCoreTests: XCTestCase {
    let bounds = Rect(x: 0, y: 25, width: 1440, height: 850)
    func display(_ id: String = "internal", x: Double = 0, width: Double = 1440, builtin: Bool = true) -> DisplayRecord {
        DisplayRecord(id: id, name: id, frame: Rect(x: x, y: 0, width: width, height: 900),
                      visibleFrame: Rect(x: x, y: 25, width: width, height: 850), isBuiltin: builtin,
                      spaces: [SpaceRecord(id: 1, index: 1), SpaceRecord(id: 2, index: 2)], activeSpaceID: 1)
    }
    func window(title: String = "Document", ordinal: Int = 0, desktop: Int = 1, appID: String = "org.test.editor") -> WindowRecord {
        WindowRecord(appID: appID, title: title, windowID: 12, processID: 100,
                     launchDate: Date(timeIntervalSince1970: 1000), ordinal: ordinal,
                     displayID: "internal", spaceIndex: desktop, frame: Rect(x: 40, y: 50, width: 600, height: 400))
    }
    func layout(windows: [WindowRecord]) -> Layout {
        Layout(name: "Work", scope: .workspace, displays: [display()],
               apps: [AppRecord(id: "org.test.editor", name: "Editor", path: "/Applications/Editor.app", hidden: false)], windows: windows)
    }
    func testMonitorReorderingKeepsUUIDs() {
        let saved = [display(), display("external", x: 1440, width: 2560, builtin: false)]
        let current = [display("external", x: -2560, width: 2560, builtin: false), display()]
        let mapped = DisplayMapper.map(saved: saved, current: current)
        XCTAssertEqual(mapped["internal"]?.id, "internal")
        XCTAssertEqual(mapped["external"]?.frame.x, -2560)
    }
    func testDockedToLaptopKeepsAllWindowsOnscreen() {
        let external = display("external", x: -2560, width: 2560, builtin: false)
        let target = display()
        var w = window(); w.displayID = "external"; w.frame = Rect(x: -2400, y: 100, width: 2000, height: 700)
        let mapped = DisplayMapper.map(saved: [display(), external], current: [target])
        XCTAssertEqual(mapped["external"]?.id, target.id)
        let frame = DisplayMapper.frame(for: w, saved: external, target: target)
        XCTAssertGreaterThanOrEqual(frame.x, target.visibleFrame.x)
        XCTAssertLessThanOrEqual(frame.x + frame.width, target.visibleFrame.x + target.visibleFrame.width)
        XCTAssertLessThanOrEqual(frame.y + frame.height, target.visibleFrame.y + target.visibleFrame.height)
    }
    func testSameMonitorChangedPositionUsesTranslation() {
        let saved = display(), moved = display(x: -1440)
        let actual = DisplayMapper.frame(for: window(), saved: saved, target: moved)
        XCTAssertEqual(actual.x, -1400); XCTAssertEqual(actual.width, 600)
    }
    func testFullscreenUsesVisibleArea() {
        var w = window(); w.fullscreen = true
        XCTAssertEqual(DisplayMapper.frame(for: w, saved: display(), target: display()), display().visibleFrame)
    }
    func testMatchingIsOneToOneWithDuplicateTitles() {
        let first = window(), second = window(ordinal: 1)
        var a = window(), b = window(ordinal: 1)
        a.windowID = 200; a.processID = 200; a.launchDate = Date()
        b.windowID = 201; b.processID = 200; b.launchDate = a.launchDate
        let match = WindowMatcher.match(saved: [first, second], live: [a, b])
        XCTAssertEqual(match.count, 2); XCTAssertEqual(Set(match.values).count, 2)
    }
    func testRuntimeIDCannotOverrideTitleAfterRelaunch() {
        let saved = window(title: "Original")
        var reused = window(title: "Different", ordinal: 1); reused.launchDate = Date(timeIntervalSince1970: 2000)
        var correct = window(title: "Original"); correct.windowID = 90; correct.processID = 300; correct.launchDate = reused.launchDate
        XCTAssertEqual(WindowMatcher.match(saved: [saved], live: [reused, correct])[saved.id], correct.id)
    }
    func testMatchingNeverCrossesApplications() {
        let saved = window(), otherApp = window(appID: "org.other")
        XCTAssertTrue(WindowMatcher.match(saved: [saved], live: [otherApp]).isEmpty)
    }
    func testPersistentIdentifierHasPriorityOverTitle() {
        var saved = window(); saved.identifier = "document-123"
        var wrong = window(); wrong.windowID = 80
        var correct = window(title: "Renamed"); correct.identifier = saved.identifier; correct.windowID = 81
        XCTAssertEqual(WindowMatcher.match(saved: [saved], live: [wrong, correct])[saved.id], correct.id)
    }
    func testUpdateDesktopPreservesOtherDesktopsAndMetadata() throws {
        let first = window(), second = window(title: "Other desktop", ordinal: 1, desktop: 2)
        var original = layout(windows: [first, second]); original.excludedAppIDs = ["org.ignored"]
        var replacement = window(); replacement.frame.width = 900
        let updated = LayoutEditor.updateDesktop(in: original, snapshot: layout(windows: [replacement]), displayID: "internal", spaceIndex: 1)
        XCTAssertTrue(updated.windows.contains(second)); XCTAssertFalse(updated.windows.contains(first))
        XCTAssertTrue(updated.windows.contains(replacement)); XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.excludedAppIDs, original.excludedAppIDs)
        try updated.validate()
    }
    func testUpdateDoesNotLoseWindowsOfUnresponsiveApps() {
        let existing = window()
        let original = layout(windows: [existing])
        let updated = LayoutEditor.updateDesktop(in: original, snapshot: layout(windows: []), displayID: "internal", spaceIndex: 1, preservingAppIDs: [existing.appID])
        XCTAssertEqual(updated.windows, [existing])
    }
    func testDesktopUpdatePreservesWindowlessAppsElsewhereInWorkspace() {
        var original = layout(windows: [window()])
        let background = AppRecord(id: "org.test.background", name: "Background", path: "", hidden: true)
        original.apps.append(background)
        let updated = LayoutEditor.updateDesktop(in: original, snapshot: layout(windows: []), displayID: "internal", spaceIndex: 1)
        XCTAssertTrue(updated.apps.contains(background))
    }
    func testRuntimeIdentitySurvivesPersistenceWithFractionalLaunchTime() throws {
        var saved = window(); saved.launchDate = Date(timeIntervalSince1970: 1_700_000_000.321456)
        var archive = Library(); archive.layouts = [layout(windows: [saved])]
        let restored = try LibraryStore.decoder.decode(Library.self, from: LibraryStore.encoder.encode(archive)).layouts[0].windows[0]
        var live = saved; live.id = UUID(); live.title = "Changed title"; live.ordinal = 19
        XCTAssertEqual(WindowMatcher.match(saved: [restored], live: [live])[restored.id], live.id)
    }
    func testInvalidImportRejected() throws {
        var invalid = layout(windows: [window()]); invalid.windows[0].displayID = "missing"
        XCTAssertThrowsError(try invalid.validate())
        invalid = layout(windows: [window()]); invalid.windows[0].frame.width = -1
        XCTAssertThrowsError(try invalid.validate())
        invalid = layout(windows: [window()]); invalid.windows[0].spaceIndex = 0
        XCTAssertThrowsError(try invalid.validate())
    }
    func testArchiveRoundTripAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library(); library.layouts = [layout(windows: [window()])]
        library.preferences.excludedAppIDs = ["org.passwordmanager"]
        library.layouts[0].excludedAppIDs = ["org.video"]
        try store.save(library)
        let loaded = try store.load()
        XCTAssertEqual(loaded.layouts[0].windows[0].title, "Document")
        XCTAssertEqual(loaded.preferences.excludedAppIDs, ["org.passwordmanager"])
        XCTAssertEqual(loaded.layouts[0].excludedAppIDs, ["org.video"])
        library.layouts[0].name = "Changed"; try store.save(library)
        let backup = LibraryStore(url: store.url.appendingPathExtension("backup"))
        XCTAssertEqual(try backup.load().layouts[0].name, "Work")
    }
    func testUnsupportedSchemaCannotBeLoadedOrWritten() throws {
        var library = Library(); library.version = 999
        XCTAssertThrowsError(try library.validate())
    }
    func testInvalidArchiveDoesNotReplaceExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var valid = Library(); valid.layouts = [layout(windows: [window()])]; try store.save(valid)
        var invalid = valid; invalid.layouts[0].windows[0].frame.height = 0
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load().layouts[0].windows.count, 1)
    }
}
