import XCTest
@testable import omux

final class ProjectIdentityTests: XCTestCase {
    func testOlderProjectsAndUnknownAppearanceStillLoad() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(TabGroup.self, from: Data(#"{"name":"Legacy","tabs":[]}"#.utf8))
        XCTAssertEqual(legacy.icon, .folder)
        XCTAssertEqual(legacy.color, .none)
        let future = try decoder.decode(TabGroup.self, from: Data(#"{"name":"Future","icon":"future-icon","color":"future-color","tabs":[]}"#.utf8))
        XCTAssertEqual(future.icon, .folder)
        XCTAssertEqual(future.color, .none)
    }

    func testProjectAppearancePersistsWithoutChangingSessionsOrLayout() throws {
        var first = TabGroup(name: "Server", tabs: [TabItem(name: "Existing")])
        first.icon = .server
        first.color = .purple
        let other = TabGroup(name: "Other")
        var canvas = CanvasWorkspace()
        canvas.projectID = first.id
        canvas.pinnedProjects = [first.id]
        canvas.projectOrder = [other.id, first.id]
        let original = Workspace(groups: [first, other], selectedTabID: first.tabs[0].id, canvas: canvas)
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.groups[0], first)
        XCTAssertEqual(restored.groups[1].icon, .folder)
        XCTAssertEqual(restored.groups[1].color, .none)
        XCTAssertEqual(restored.selectedTabID, original.selectedTabID)
        XCTAssertEqual(restored.canvas, canvas)
    }
}
