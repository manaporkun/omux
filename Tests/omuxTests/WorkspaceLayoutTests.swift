import XCTest
@testable import omux

final class WorkspaceLayoutTests: XCTestCase {
    func testProjectDragOrderPersistsAndPreservesHiddenSlots() throws {
        let groups = [TabGroup(name: "C"), TabGroup(name: "A"), TabGroup(name: "B")]
        var canvas = CanvasWorkspace()
        XCTAssertEqual(canvas.orderedProjects(groups).map(\.name), ["A", "B", "C"])
        XCTAssertTrue(canvas.moveProject(groups[1].id, before: nil, visibleProjects: groups.map(\.id), groups: groups))
        XCTAssertEqual(canvas.orderedProjects(groups).map(\.name), ["B", "C", "A"])
        let restored = try JSONDecoder().decode(CanvasWorkspace.self, from: JSONEncoder().encode(canvas))
        XCTAssertEqual(restored.orderedProjects(groups).map(\.name), ["B", "C", "A"])
        canvas.pinnedProjects.insert(groups[1].id)
        XCTAssertFalse(canvas.moveProject(groups[1].id, before: nil, visibleProjects: groups.map(\.id), groups: groups))
        XCTAssertFalse(canvas.moveProject(UUID(), before: groups[0].id, visibleProjects: groups.map(\.id), groups: groups))
        XCTAssertEqual(canvas.orderedProjects(groups).first?.name, "A")
        canvas.reconcile(groups: Array(groups.dropFirst()))
        XCTAssertFalse(canvas.projectOrder!.contains(groups[0].id))
    }

    func testProjectInsertionMovesNeighborsAndPreservesFilteredSlots() {
        let groups = ["A", "B", "C", "D"].map { TabGroup(name: $0) }
        var canvas = CanvasWorkspace()
        XCTAssertTrue(canvas.moveProject(groups[2].id, before: groups[0].id, visibleProjects: groups.map(\.id), groups: groups))
        XCTAssertEqual(canvas.orderedProjects(groups).map(\.name), ["C", "A", "B", "D"])
        canvas.projectOrder = nil
        XCTAssertTrue(canvas.moveProject(groups[0].id, before: nil, visibleProjects: [groups[0].id, groups[2].id, groups[3].id], groups: groups))
        XCTAssertEqual(canvas.orderedProjects(groups).map(\.name), ["C", "B", "D", "A"])
        canvas.pinnedProjects.insert(groups[0].id)
        XCTAssertFalse(canvas.moveProject(groups[0].id, before: groups[2].id, visibleProjects: groups.map(\.id), groups: groups))
    }

    func testLegacyWorkspaceLoadsWithoutCanvasState() throws {
        let json = Data(#"{"groups":[{"name":"Project","tabs":[{"name":"Existing","command":"codex","codexThreadID":"thread-123"}]}]}"#.utf8)
        let restored = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertEqual(restored.groups[0].tabs[0].codexThreadID, "thread-123")
        XCTAssertTrue(restored.canvas.projects.isEmpty)
        XCTAssertNil(restored.canvas.maximizedID)
    }

    func testCanvasRoundTripKeepsProviderIdentityOrderShelfAndFocus() throws {
        var group = TabGroup(name: "Project", tabs: [TabItem(name: "Review"), TabItem(name: "API")])
        group.tabs[1].codexThreadID = "original-thread"
        var layout = CanvasWorkspace()
        layout.projectID = group.id
        layout.maximizedID = group.tabs[1].id
        layout.pinnedProjects.insert(group.id)
        layout.projects[group.id] = ProjectCanvas(minimized: [group.tabs[0].id])
        let workspace = Workspace(groups: [group], selectedTabID: group.tabs[1].id, canvas: layout)
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(restored.canvas, layout)
        XCTAssertEqual(restored.groups[0].tabs.map(\.id), group.tabs.map(\.id))
        XCTAssertEqual(restored.groups[0].tabs[0].claudeSessionID, group.tabs[0].claudeSessionID)
        XCTAssertEqual(restored.groups[0].tabs[1].codexThreadID, "original-thread")
    }

    func testDeletedSessionsAndProjectsDoNotRemainInCanvas() {
        let group = TabGroup(name: "Survives", tabs: [TabItem(name: "A")])
        let deletedGroup = UUID(), deletedTab = UUID()
        var layout = CanvasWorkspace()
        layout.projectID = deletedGroup
        layout.maximizedID = deletedTab
        layout.pinnedProjects = [group.id, deletedGroup]
        layout.projects[group.id] = ProjectCanvas(minimized: [group.tabs[0].id, deletedTab])
        layout.projects[deletedGroup] = ProjectCanvas()
        layout.reconcile(groups: [group])
        XCTAssertEqual(layout.projectID, group.id)
        XCTAssertNil(layout.maximizedID)
        XCTAssertEqual(layout.pinnedProjects, [group.id])
        XCTAssertEqual(layout.projects.count, 1)
        XCTAssertEqual(layout.project(group.id).minimized, [group.tabs[0].id])
    }

    func testFourWindowsFitAsReadableLandscapeTerminals() {
        let grid = TerminalGridLayout(count: 4, available: CGSize(width: 900, height: 650))
        XCTAssertEqual(grid.columns, 2)
        XCTAssertGreaterThanOrEqual(grid.width, 300)
        XCTAssertGreaterThanOrEqual(grid.height, 170)
        XCTAssertLessThanOrEqual(2 * grid.height + 12, 650)
        XCTAssertGreaterThanOrEqual(grid.width / grid.height, 1.3)
        XCTAssertLessThanOrEqual(grid.width / grid.height, 2.8)
    }

    func testCrowdedProjectScrollsRatherThanShrinkingTerminals() {
        let grid = TerminalGridLayout(count: 16, available: CGSize(width: 810, height: 620))
        XCTAssertEqual(grid.columns, 2)
        XCTAssertGreaterThanOrEqual(grid.width, 300)
        XCTAssertGreaterThanOrEqual(grid.height, 170)
        XCTAssertGreaterThan(8 * grid.height + 7 * 12, 620)
    }

    func testNarrowWindowPreservesReadableMinimumWithHorizontalScrolling() {
        let grid = TerminalGridLayout(count: 2, available: CGSize(width: 200, height: 250))
        XCTAssertEqual(grid.columns, 1)
        XCTAssertGreaterThanOrEqual(grid.width, 300)
        XCTAssertGreaterThanOrEqual(grid.height, 170)
    }

    func testSingleTerminalDoesNotBecomePortraitOrExtremelyWide() {
        for available in [CGSize(width: 1500, height: 400), CGSize(width: 600, height: 1200)] {
            let grid = TerminalGridLayout(count: 1, available: available)
            XCTAssertGreaterThanOrEqual(grid.width / grid.height, 1.29)
            XCTAssertLessThanOrEqual(grid.width / grid.height, 2.81)
        }
    }

    func testAutomaticLayoutAdaptsColumnsToAvailableWidth() {
        let narrow = TerminalGridLayout(count: 6, available: CGSize(width: 450, height: 700))
        let wide = TerminalGridLayout(count: 6, available: CGSize(width: 1500, height: 700))
        XCTAssertEqual(narrow.columns, 1)
        XCTAssertGreaterThan(wide.columns, narrow.columns)
        XCTAssertLessThanOrEqual(CGFloat(wide.columns) * wide.width + CGFloat(wide.columns - 1) * 12, 1500)
    }

    func testLegacySizeOverridesAreIgnoredWithoutLosingShelfState() throws {
        let id = UUID()
        for size in ["small", "medium", "large", "unknown"] {
            let data = Data("{\"size\":\"\(size)\",\"minimized\":[\"\(id.uuidString)\"]}".utf8)
            let decoded = try JSONDecoder().decode(ProjectCanvas.self, from: data)
            XCTAssertEqual(decoded.minimized, [id])
            let encoded = try JSONEncoder().encode(decoded)
            XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["size"])
        }
    }

    func testErrorAndApprovalBothNeedAttentionAndShellWorkRemainsDistinct() {
        let blocked = CanvasSessionState(TabRuntime(statusState: .blocked))
        let error = CanvasSessionState(TabRuntime(statusState: .error))
        XCTAssertTrue(blocked.needsAttention)
        XCTAssertTrue(error.needsAttention)
        XCTAssertTrue(CanvasFilter.needsYou.includes(error))
        XCTAssertFalse(CanvasFilter.working.includes(blocked))
        XCTAssertEqual(CanvasSessionState(TabRuntime(provider: .shell, busy: true)), .running)
        XCTAssertEqual(CanvasSessionState(TabRuntime(provider: .codex, busy: true)), .working)
        XCTAssertEqual(CanvasSessionState(TabRuntime(exited: true, statusState: .working)), .ended)
        XCTAssertTrue(CanvasFilter.idle.includes(.ended))
    }
    func testInterruptedProcessNeedsAttentionWithoutBeingReportedAsWorking() {
        let state = CanvasSessionState(TabRuntime(exited: true, interrupted: true))
        XCTAssertEqual(state, .interrupted)
        XCTAssertTrue(state.needsAttention)
        XCTAssertTrue(CanvasFilter.needsYou.includes(state))
        XCTAssertFalse(CanvasFilter.idle.includes(state))
        XCTAssertFalse(CanvasFilter.working.includes(state))
    }

    func testFilterPartitionsMatchesBetweenGridAndShelfWithoutHidingOtherShelfSessions() {
        let tabs = [
            TabItem(name: "Visible work"), TabItem(name: "Shelved work"),
            TabItem(name: "Shelved idle"), TabItem(name: "Visible idle")
        ]
        let states: [UUID: CanvasSessionState] = [
            tabs[0].id: .working, tabs[1].id: .running,
            tabs[2].id: .idle, tabs[3].id: .idle
        ]
        let result = CanvasFilterResult(
            tabs: tabs, minimized: [tabs[1].id, tabs[2].id], filter: .working,
            state: { states[$0.id]! }
        )
        XCTAssertEqual(result.visible.map(\.id), [tabs[0].id])
        XCTAssertEqual(result.shelf.map(\.id), [tabs[1].id, tabs[2].id])
        XCTAssertEqual(result.matchingShelf.map(\.id), [tabs[1].id])
        XCTAssertEqual(result.matchingCount, 2)

        // The same matching subset drives Restore matching: unrelated sessions stay shelved.
        var minimized: Set<UUID> = [tabs[1].id, tabs[2].id]
        minimized.subtract(result.matchingShelf.map(\.id))
        let restored = CanvasFilterResult(tabs: tabs, minimized: minimized, filter: .working, state: { states[$0.id]! })
        XCTAssertEqual(restored.visible.map(\.id), [tabs[0].id, tabs[1].id])
        XCTAssertEqual(restored.shelf.map(\.id), [tabs[2].id])
        XCTAssertTrue(restored.matchingShelf.isEmpty)
        XCTAssertEqual(restored.matchingCount, result.matchingCount)
    }

    func testNoMatchingShelfSessionsDoesNotHideShelfOrOfferUnrelatedRestoreTargets() {
        let tabs = [TabItem(name: "Interrupted"), TabItem(name: "Ended")]
        let states: [UUID: CanvasSessionState] = [tabs[0].id: .interrupted, tabs[1].id: .ended]
        let minimized = Set(tabs.map(\.id))
        let working = CanvasFilterResult(tabs: tabs, minimized: minimized, filter: .working, state: { states[$0.id]! })
        XCTAssertTrue(working.visible.isEmpty)
        XCTAssertEqual(working.shelf.map(\.id), tabs.map(\.id))
        XCTAssertTrue(working.matchingShelf.isEmpty)
        XCTAssertEqual(working.matchingCount, 0)

        let attention = CanvasFilterResult(tabs: tabs, minimized: minimized, filter: .needsYou, state: { states[$0.id]! })
        XCTAssertEqual(attention.matchingShelf.map(\.id), [tabs[0].id])
        let idle = CanvasFilterResult(tabs: tabs, minimized: minimized, filter: .idle, state: { states[$0.id]! })
        XCTAssertEqual(idle.matchingShelf.map(\.id), [tabs[1].id])
        let all = CanvasFilterResult(tabs: tabs, minimized: minimized, filter: .all, state: { states[$0.id]! })
        XCTAssertEqual(all.matchingShelf.map(\.id), tabs.map(\.id))
        XCTAssertEqual(all.matchingCount, tabs.count)
    }

}
