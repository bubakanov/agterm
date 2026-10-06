import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSubagentTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-subagent-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setShowSubagents(false)
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func start(_ id: String) -> SubagentChange {
        .start(Subagent(id: id, startedAt: Date()))
    }

    func testRecordingIsIgnoredWhileTheSettingIsOff() throws {
        let store = try XCTUnwrap(library.activeStore)

        let response = server.applySubagentChange(start("a1"), target: "active", window: nil)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.text, ControlServer.subagentsOffNote)
        XCTAssertTrue(try XCTUnwrap(store.activeSession).subagents.isEmpty)
    }

    func testRecordsOnceTheSettingIsOnAndTreeReportsBoth() throws {
        let store = try XCTUnwrap(library.activeStore)
        XCTAssertEqual(server.setSubagentRows(.on).result?.text, "on")

        XCTAssertEqual(server.applySubagentChange(start("a1"), target: "active", window: nil),
                       ControlResponse(ok: true, result: ControlResult(id: try XCTUnwrap(store.selectedSessionID).uuidString)))

        let tree = server.buildTree(in: store)
        XCTAssertEqual(tree.subagentRows, true)
        XCTAssertEqual(tree.workspaces.first?.sessions.first?.subagents?.map(\.id), ["a1"])
        XCTAssertEqual(SettingsStore(directory: stateDir).load().showSubagents, true)
    }

    func testTidyingWritesRunWhileOff() throws {
        let store = try XCTUnwrap(library.activeStore)
        _ = server.setSubagentRows(.on)
        _ = server.applySubagentChange(start("a1"), target: "active", window: nil)
        _ = server.setSubagentRows(.off)

        XCTAssertTrue(server.applySubagentChange(.remove(id: "a1"), target: "active", window: nil).ok)
        XCTAssertTrue(try XCTUnwrap(store.activeSession).subagents.isEmpty)
    }

    func testBareModeReadsWithoutWritingAndToggleFlips() {
        XCTAssertEqual(server.setSubagentRows(.read).result?.text, "off")
        XCTAssertNil(SettingsStore(directory: stateDir).load().showSubagents)
        XCTAssertEqual(server.setSubagentRows(.toggle).result?.text, "on")
        XCTAssertEqual(server.setSubagentRows(.toggle).result?.text, "off")
    }

    func testOpeningAnotherSubagentReplacesTheViewer() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let id = try XCTUnwrap(store.selectedSessionID)
        _ = server.setSubagentRows(.on)
        for agent in ["a1", "a2"] {
            let path = stateDir.appendingPathComponent("agent-\(agent).jsonl")
            try Data().write(to: path)
            _ = server.applySubagentChange(.start(Subagent(id: agent, startedAt: Date(), transcriptPath: path.path)),
                                           target: "active", window: nil)
        }

        let first = await server.openSubagent("a1", target: "active", window: nil)
        let second = await server.openSubagent("a2", target: "active", window: nil)

        XCTAssertTrue(first.ok && second.ok, "\(first) \(second)")
        let command = try XCTUnwrap(store.session(withID: id)?.overlayCommand)
        XCTAssertTrue(command.contains("agent-a2.jsonl"), command)
        XCTAssertTrue(command.hasSuffix(" --follow"), "a running subagent's viewer follows its growing transcript: \(command)")
    }

    func testCommandWClosesTheTranscriptNotTheSession() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let id = try XCTUnwrap(store.selectedSessionID)
        _ = server.setSubagentRows(.on)
        let path = stateDir.appendingPathComponent("agent-a1.jsonl")
        try Data().write(to: path)
        _ = server.applySubagentChange(.start(Subagent(id: "a1", startedAt: Date(), transcriptPath: path.path)),
                                       target: "active", window: nil)
        store.selectSession(id)
        let opened = await server.actions.openSubagentTranscript("a1", session: id, in: store)
        XCTAssertNil(opened)
        XCTAssertEqual(store.activeSession?.id, id)
        XCTAssertEqual(store.activeSession?.overlayActive, true)

        XCTAssertTrue(server.actions.closeActiveSession())

        XCTAssertNotNil(store.session(withID: id), "⌘W must take the transcript down, not the session under it")
        XCTAssertEqual(store.session(withID: id)?.overlayActive, false)
    }

    func testCopiedTranscriptTextCarriesTheTurnsWithoutStyling() async throws {
        let transcript = stateDir.appendingPathComponent("agent-a1.jsonl")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try """
        {"message":{"role":"user","content":"List the files"}}
        {"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>Report back</system-reminder>"}]}}
        {"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let viewer = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("agent-status/\(AppActions.subagentViewerName)"))

        let rendered = await AppActions.renderTranscriptText(viewer: viewer.path, transcript: transcript.path, title: "probe")
        let text = try XCTUnwrap(rendered)

        XCTAssertTrue(text.hasPrefix("probe\n"), text)
        XCTAssertTrue(text.contains("── user ──\nList the files"), text)
        XCTAssertTrue(text.contains("▸ Bash ls"), text)
        XCTAssertFalse(text.contains("Report back"), text)
        XCTAssertFalse(text.contains("\u{1B}"), "the pasteboard copy must carry no terminal styling")
    }

    func testACodexSubagentTranscriptStartsAtItsTaskNotItsParentsCopiedHistory() async throws {
        let transcript = stateDir.appendingPathComponent("rollout-child.jsonl")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try """
        {"type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"parent prompt"}]}}
        {"type":"response_item","payload":{"type":"agent_message","content":[{"type":"input_text","text":"Task name: /root/count"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"161 lines"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let viewer = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("agent-status/\(AppActions.subagentViewerName)"))

        let rendered = await AppActions.renderTranscriptText(viewer: viewer.path, transcript: transcript.path, title: "count")
        let text = try XCTUnwrap(rendered)

        XCTAssertFalse(text.contains("parent prompt"), text)
        XCTAssertTrue(text.contains("── task ──\nTask name: /root/count"), text)
        XCTAssertTrue(text.contains("── assistant ──\n161 lines"), text)
    }

    func testClosingTheTranscriptLeavesAnyOtherOverlayAlone() throws {
        let store = try XCTUnwrap(library.activeStore)
        let id = try XCTUnwrap(store.selectedSessionID)
        XCTAssertTrue(store.openOverlay(id, command: "htop"))

        XCTAssertFalse(server.actions.closeSubagentTranscript(session: id, in: store))
        XCTAssertEqual(store.session(withID: id)?.overlayCommand, "htop")
    }

    func testOpenRefusesARowWithoutATranscript() async throws {
        _ = server.setSubagentRows(.on)
        _ = server.applySubagentChange(start("a1"), target: "active", window: nil)

        let response = await server.openSubagent("a1", target: "active", window: nil)

        XCTAssertEqual(response, ControlResponse(ok: false, error: "subagent a1 has no transcript"))
    }
}
