import Foundation
import Testing
@testable import agtermCore

@MainActor
private final class EventCollector {
    var drafts: [ControlEventDraft] = []
}

@MainActor
struct AppStoreSubagentTests {
    private func storeWithSession() throws -> (AppStore, Session, EventCollector) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let events = EventCollector()
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { events.drafts.append($0) })
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        events.drafts.removeAll()
        return (store, session, events)
    }

    private func start(_ id: String, path: String? = nil) -> SubagentChange {
        .start(Subagent(id: id, agentType: "general-purpose", summary: "probe \(id)", startedAt: Date(),
                        transcriptPath: path))
    }

    private func stop(_ id: String, path: String? = nil) -> SubagentChange {
        .update(id: id, status: .completed, activity: nil, summary: nil, agentType: nil, transcriptPath: path)
    }

    @Test func startAndStopEmitSubagentEventsWithTheirTransition() throws {
        let (store, session, events) = try storeWithSession()

        #expect(store.applySubagentChange(start("a"), forSession: session.id) == .applied)
        #expect(store.applySubagentChange(stop("a"), forSession: session.id) == .applied)

        let subagentEvents = events.drafts.filter { $0.kind == .subagent }.map(\.payload)
        #expect(subagentEvents.map(\.status) == ["active", "completed"])
        #expect(subagentEvents.map(\.previous) == [nil, "active"])
        #expect(subagentEvents.allSatisfy { $0.agent == "a" && $0.title == "probe a" })
    }

    @Test func anActivityOnlyUpdateEmitsNoEvent() throws {
        let (store, session, events) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)
        events.drafts.removeAll()

        store.applySubagentChange(.update(id: "a", status: nil, activity: "npm test", summary: nil, agentType: nil,
                                          transcriptPath: nil), forSession: session.id)

        #expect(session.subagents.entry("a")?.activity == "npm test")
        #expect(events.drafts.isEmpty)
    }

    @Test func unknownTargetsAreReported() throws {
        let (store, session, _) = try storeWithSession()
        #expect(store.applySubagentChange(stop("missing"), forSession: session.id) == .unknownSubagent)
        #expect(store.applySubagentChange(.remove(id: "missing"), forSession: session.id) == .unknownSubagent)
        #expect(store.applySubagentChange(start("a"), forSession: UUID()) == .unknownSession)
    }

    @Test func parentCompletionWaitsForItsRunningSubagent() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .completed, autoReset: true), forSession: session.id)
        #expect(session.agentIndicator.status == .active)
        #expect(!session.agentIndicator.autoReset)

        store.applySubagentChange(stop("a"), forSession: session.id)
        #expect(session.agentIndicator.status == .completed)
        #expect(session.agentIndicator.autoReset)
    }

    @Test func aNewParentStatusDropsTheHeldCompletion() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)
        store.applyControlStatus(AgentIndicator(status: .completed), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .blocked), forSession: session.id)
        store.applySubagentChange(stop("a"), forSession: session.id)

        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func parentCompletesAtOnceWithNoRunningSubagent() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)
        store.applySubagentChange(stop("a"), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .completed), forSession: session.id)

        #expect(session.agentIndicator.status == .completed)
    }

    @Test func finishAllReleasesTheHeldCompletion() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)
        store.applySubagentChange(start("b"), forSession: session.id)
        store.applyControlStatus(AgentIndicator(status: .completed), forSession: session.id)

        store.applySubagentChange(.finishAll, forSession: session.id)

        #expect(!session.subagents.hasRunning)
        #expect(session.agentIndicator.status == .completed)
    }

    @Test func clearReleasesTheHeldCompletion() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a"), forSession: session.id)
        store.applyControlStatus(AgentIndicator(status: .completed, autoReset: true), forSession: session.id)

        store.applySubagentChange(.clear, forSession: session.id)

        #expect(session.subagents.isEmpty)
        #expect(session.agentIndicator.status == .completed)
        #expect(session.agentIndicator.autoReset)
    }

    @Test func treeOmitsSubagentFieldsWhenThereAreNone() throws {
        let (store, _, _) = try storeWithSession()
        let tree = store.controlTree()
        let node = try #require(tree.workspaces.first?.sessions.first)
        #expect(node.subagents == nil)
        #expect(node.subagentsDropped == nil)
        #expect(tree.subagentRows == nil)
    }

    @Test func treeReportsRowsTheTruncationCountAndTheSetting() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a", path: "/t/a.jsonl"), forSession: session.id)
        store.applySubagentChange(.update(id: "a", status: nil, activity: "npm test", summary: nil, agentType: nil,
                                          transcriptPath: nil), forSession: session.id)
        for index in 0..<SubagentHistory.limit { store.applySubagentChange(start("r\(index)"), forSession: session.id) }

        let tree = store.controlTree(paneForeground: { _ in nil }, subagentRows: true)
        let node = try #require(tree.workspaces.first?.sessions.first)

        #expect(tree.subagentRows == true)
        #expect(node.subagents?.count == SubagentHistory.limit)
        #expect(node.subagentsDropped == 1)
        #expect(node.subagents?.contains { $0.id == "a" } == false)
        let first = try #require(node.subagents?.first)
        #expect(first.id == "r0" && first.type == "general-purpose" && first.description == "probe r0")
        #expect(first.status == "active" && first.endedAt == nil && first.transcript == nil)
    }

    @Test func treeReportsActivityAndTranscript() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("a", path: "/t/a.jsonl"), forSession: session.id)
        store.applySubagentChange(.update(id: "a", status: nil, activity: "npm test", summary: nil, agentType: nil,
                                          transcriptPath: nil), forSession: session.id)

        let row = try #require(store.controlTree().workspaces.first?.sessions.first?.subagents?.first)

        #expect(row.activity == "npm test")
        #expect(row.transcript == "/t/a.jsonl")
    }

    @Test func snapshotOmitsAnEmptyHistory() throws {
        let (store, _, _) = try storeWithSession()
        #expect(store.snapshot().workspaces[0].sessions[0].subagents == nil)
    }

    @Test func restoreFinishesRunningRowsAndDropsDeletedTranscripts() throws {
        let (store, session, _) = try storeWithSession()
        store.applySubagentChange(start("running"), forSession: session.id)
        store.applySubagentChange(start("gone", path: "/gone"), forSession: session.id)
        store.applySubagentChange(stop("gone", path: "/gone"), forSession: session.id)
        store.subagentTranscriptExists = { _ in true }
        store.pruneSubagents(forSession: session.id)
        let saved = try #require(store.snapshot().workspaces[0].sessions.first)
        store.subagentTranscriptExists = { _ in false }

        let restored = store.session(from: saved)

        #expect(restored.subagents.entries.map(\.id) == ["running"])
        #expect(restored.subagents.entry("running")?.status == .completed)
    }

    @Test func reopeningAClosedSessionDropsRowsWhoseTranscriptWasDeleted() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.applySubagentChange(start("kept", path: "/kept"), forSession: session.id)
        store.applySubagentChange(start("gone", path: "/gone"), forSession: session.id)
        store.applySubagentChange(.finishAll, forSession: session.id)
        store.subagentTranscriptExists = { _ in true }
        store.pruneSubagents(forSession: session.id)
        store.closeSession(session.id)
        store.subagentTranscriptExists = { $0 == "/kept" }

        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == session.id })
        #expect(store.restoreRecentClosed(item))

        let reopened = try #require(store.session(withID: session.id))
        #expect(reopened.subagents.entries.map(\.id) == ["kept"])
    }

    @Test func pruneRemovesRowsWhoseTranscriptVanished() throws {
        let (store, session, events) = try storeWithSession()
        store.applySubagentChange(start("a", path: "/a"), forSession: session.id)
        store.applySubagentChange(stop("a"), forSession: session.id)
        store.subagentTranscriptExists = { _ in true }
        store.pruneSubagents(forSession: session.id)
        events.drafts.removeAll()
        store.subagentTranscriptExists = { _ in false }

        store.pruneSubagents(forSession: session.id)

        #expect(session.subagents.isEmpty)
        #expect(events.drafts.map(\.kind) == [.treeChanged])
    }

    @Test func markingATranscriptSeenSavesWithoutATreeEvent() throws {
        let (store, session, events) = try storeWithSession()
        store.applySubagentChange(start("a", path: "/a"), forSession: session.id)
        events.drafts.removeAll()
        store.subagentTranscriptExists = { _ in true }

        store.pruneSubagents(forSession: session.id)

        #expect(session.subagents.entry("a")?.transcriptSeen == true)
        #expect(events.drafts.isEmpty)
    }

    @Test func aNewConversationHidesTheOldRowsFromTheTreeReadBackButKeepsThem() throws {
        let (store, session, events) = try storeWithSession()
        store.applySubagentChange(.start(Subagent(id: "a", startedAt: Date(), conversationID: "c1")), forSession: session.id)
        events.drafts.removeAll()

        #expect(store.applySubagentChange(.conversation("c2"), forSession: session.id) == .applied)

        #expect(session.subagents.visibleEntries.isEmpty)
        #expect(events.drafts.map(\.kind) == [.treeChanged])
        let node = try #require(store.controlTree().workspaces.first?.sessions.first)
        #expect(node.subagentConversation == "c2")
        #expect(node.subagents?.map(\.conversation) == ["c1"])
    }
}
