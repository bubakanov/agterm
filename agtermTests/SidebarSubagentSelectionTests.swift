import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarSubagentSelectionTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var store: AppStore!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var sessionID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-subagent-selection-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        store = try XCTUnwrap(library.activeStore)
        sessionID = try XCTUnwrap(store.selectedSessionID)
        GhosttyApp.shared.setShowSubagents(true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let transcript = stateDir.appendingPathComponent("agent-a1.jsonl")
        try Data().write(to: transcript)
        store.applySubagentChange(.start(Subagent(id: "a1", summary: "probe", startedAt: Date(),
                                                  transcriptPath: transcript.path)), forSession: sessionID)

        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: AppActions(library: library))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.rebuildAndReload()
        outline.expandItem(nil, expandChildren: true)
        coordinator.syncSelection()
    }

    override func tearDown() async throws {
        GhosttyApp.shared.setShowSubagents(false)
        window?.orderOut(nil)
        window = nil
        coordinator = nil
        outline = nil
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func row(of kind: SidebarNode.Kind) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.kind == kind })
    }

    private func openTranscript() throws {
        let node = try XCTUnwrap(outline.item(atRow: try row(of: .subagent)) as? SidebarNode)
        coordinator.openSubagent(node)
        let highlighted = expectation(for: NSPredicate { [unowned self] _, _ in
            (try? self.outline.selectedRowIndexes == [self.row(of: .subagent)]) ?? false
        }, evaluatedWith: nil)
        wait(for: [highlighted], timeout: 5)
    }

    func testClosingTheTranscriptHandsTheSelectionBackToTheSession() throws {
        try openTranscript()

        store.closeOverlay(sessionID)
        coordinator.syncSelection()

        XCTAssertEqual(outline.selectedRowIndexes, [try row(of: .session)])
    }

    func testVisitingASubagentAndComingBackKeepsTheParentsCompletedStatus() throws {
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: sessionID)
        try openTranscript()
        XCTAssertEqual(store.session(withID: sessionID)?.agentIndicator.status, .completed)

        outline.selectRowIndexes([try row(of: .session)], byExtendingSelection: false)

        XCTAssertEqual(store.session(withID: sessionID)?.agentIndicator.status, .completed)
        XCTAssertEqual(store.session(withID: sessionID)?.overlayActive, false, "going back to the session closes the transcript")
    }

    func testCollapsingTheSessionClosesTheTranscriptAndSelectsTheSession() throws {
        try openTranscript()

        outline.collapseItem(try XCTUnwrap(outline.item(atRow: try row(of: .session))))

        XCTAssertEqual(store.session(withID: sessionID)?.overlayActive, false)
        XCTAssertEqual(outline.selectedRowIndexes, [try row(of: .session)])
    }
}
