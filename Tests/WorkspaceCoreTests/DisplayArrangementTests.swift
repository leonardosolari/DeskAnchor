import XCTest
@testable import WorkspaceCore

final class DisplayArrangementTests: XCTestCase {
    private func display(_ id: String, x: Double = 0, y: Double = 0,
                         width: Double = 1440, height: Double = 900) -> DisplayRecord {
        DisplayRecord(id: id, name: id, frame: Rect(x: x, y: y, width: width, height: height),
                      visibleFrame: Rect(x: x, y: y + 25, width: width, height: height - 25),
                      isBuiltin: id == "mac", spaces: [SpaceRecord(id: 1, index: 1)], activeSpaceID: 1)
    }
    private func layout(_ displays: [DisplayRecord]) throws -> Layout {
        var layout = Layout(name: "Office", scope: .workspace, displays: displays, apps: [], windows: [])
        layout.displayArrangement = try DisplayArrangement(displays: displays)
        return layout
    }

    func testRestoresOfficeMonitorFromAboveToTheRight() throws {
        let saved = [display("mac"), display("office", x: 1440)]
        let arrangement = try DisplayArrangement(displays: saved)
        let plan = try arrangement.plan(current: [display("office", y: -900), display("mac")])
        XCTAssertEqual(plan.first?.id, "mac")
        XCTAssertEqual(plan.first(where: { $0.id == "office" })?.frame.x, 1440)
        XCTAssertEqual(plan.first(where: { $0.id == "office" })?.frame.y, 0)
    }

    func testNegativeCoordinatesAndExternalPrimaryArePreserved() throws {
        let arrangement = try DisplayArrangement(displays: [display("mac", x: -1440, y: 200), display("office")])
        let plan = try arrangement.plan(current: [display("mac"), display("office", x: 1440)])
        XCTAssertEqual(plan.first?.id, "office")
        XCTAssertEqual(plan.first(where: { $0.id == "mac" })?.frame.x, -1440)
        XCTAssertEqual(plan.first(where: { $0.id == "mac" })?.frame.y, 200)
    }

    func testAlreadyCorrectArrangementDoesNotReconfigureDisplays() throws {
        let displays = [display("mac"), display("office", y: -900)]
        XCTAssertTrue(try DisplayArrangement(displays: displays).plan(current: displays.reversed()).isEmpty)
    }

    func testDisabledArrangementDoesNotReconfigureAnotherSetup() throws {
        let arrangement = try DisplayArrangement(displays: [display("mac"), display("office", x: 1440)], enabled: false)
        XCTAssertTrue(try arrangement.plan(current: [display("mac")]).isEmpty)
    }

    func testDifferentMissingAndAdditionalDisplaysAreNeverRearranged() throws {
        let arrangement = try DisplayArrangement(displays: [display("mac"), display("office", x: 1440)])
        XCTAssertThrowsError(try arrangement.plan(current: [display("mac")]))
        XCTAssertThrowsError(try arrangement.plan(current: [display("mac"), display("home", x: 1440)]))
        XCTAssertThrowsError(try arrangement.plan(current: [display("mac"), display("office", x: 1440), display("extra", x: -1440)]))
        XCTAssertThrowsError(try arrangement.plan(current: []))
    }

    func testResolutionAndRotationChangesNeedANewArrangement() throws {
        let arrangement = try DisplayArrangement(displays: [display("mac"), display("office", x: 1440)])
        XCTAssertThrowsError(try arrangement.plan(current: [display("mac"), display("office", x: 1440, width: 1920)]))
        XCTAssertThrowsError(try arrangement.plan(current: [display("mac"), display("office", x: 1440, width: 900, height: 1440)]))
    }

    func testRejectsMirroredOverlappingAndDisconnectedDisplays() {
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("office")]))
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("office", x: 100)]))
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("office", x: 2000)]))
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("mac", x: 1440)]))
        XCTAssertThrowsError(try DisplayArrangement(displays: []))
    }

    func testRejectsInvalidPrimaryAndFractionalOrigins() {
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac", x: 100)]))
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("office", x: 1440, y: 0.5)]))
        XCTAssertThrowsError(try DisplayArrangement(displays: [display("mac"), display("office", x: .infinity)]))
    }

    func testConnectedThreeMonitorArrangementCanBeCapturedInAnyOrder() throws {
        let displays = [display("third", x: 2880), display("mac"), display("office", x: 1440)]
        XCTAssertNoThrow(try DisplayArrangement(displays: displays))
    }

    func testOldLayoutWithoutArrangementStillLoadsAndValidates() throws {
        let layout = Layout(name: "Legacy", scope: .workspace, displays: [display("mac")], apps: [], windows: [])
        let data = try LibraryStore.encoder.encode(layout)
        let restored = try LibraryStore.decoder.decode(Layout.self, from: data)
        XCTAssertNil(restored.displayArrangement)
        try restored.validate()
    }

    func testArrangementAndDisabledPreferenceSurviveExport() throws {
        var original = try layout([display("mac"), display("office", x: 1440)])
        original.displayArrangement?.enabled = false
        let restored = try LibraryStore.decoder.decode(Layout.self, from: LibraryStore.encoder.encode(original))
        XCTAssertEqual(restored.displayArrangement, original.displayArrangement)
        try restored.validate()
    }

    func testDesktopOnlyUpdatePreservesTheEntireSavedArrangement() throws {
        let original = try layout([display("mac"), display("office", x: 1440)])
        let snapshot = try layout([display("mac"), display("office", y: -900)])
        let updated = LayoutEditor.updateDesktop(in: original, snapshot: snapshot, displayID: "mac", spaceIndex: 1)
        XCTAssertEqual(updated.displayArrangement, original.displayArrangement)
    }

    func testInvalidImportedArrangementIsRejectedByLayoutValidation() throws {
        var original = try layout([display("mac"), display("office", x: 1440)])
        original.displayArrangement?.displays[1].frame.x = 1
        let imported = try LibraryStore.decoder.decode(Layout.self, from: LibraryStore.encoder.encode(original))
        XCTAssertThrowsError(try imported.validate())
    }
}
