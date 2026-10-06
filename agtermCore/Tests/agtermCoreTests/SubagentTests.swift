import Foundation
import Testing
@testable import agtermCore

struct SubagentHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func row(_ id: String, _ status: SubagentStatus = .active, path: String? = nil) -> Subagent {
        Subagent(id: id, status: status, startedAt: t0, transcriptPath: path)
    }

    @Test func startAppendsAndRestartReplacesInPlace() {
        var history = SubagentHistory()
        history.start(row("a"))
        history.start(row("b"))
        history.start(Subagent(id: "a", summary: "again", startedAt: t0))
        #expect(history.entries.map(\.id) == ["a", "b"])
        #expect(history.entry("a")?.summary == "again")
    }

    @Test func capEvictsTheOldestFinishedRowFirstAndCountsIt() {
        var history = SubagentHistory()
        history.start(row("running"))
        history.start(row("done", .completed))
        for index in 0..<(SubagentHistory.limit - 2) { history.start(row("r\(index)")) }
        #expect(history.droppedCount == 0)

        history.start(row("overflow"))

        #expect(history.entries.count == SubagentHistory.limit)
        #expect(history.entry("done") == nil)
        #expect(history.entry("running") != nil)
        #expect(history.droppedCount == 1)
    }

    @Test func capEvictsTheOldestRowWhenAllAreRunning() {
        var history = SubagentHistory()
        for index in 0...SubagentHistory.limit { history.start(row("r\(index)")) }
        #expect(history.entries.first?.id == "r1")
        #expect(history.droppedCount == 1)
    }

    @Test func finishingStampsEndAndDropsActivity() {
        var history = SubagentHistory()
        history.start(row("a"))
        history.update("a", activity: "npm test", at: t0)
        let end = t0.addingTimeInterval(5)

        let found = history.update("a", status: .completed, transcriptPath: "/t/a.jsonl", at: end)

        #expect(found)

        let entry = history.entry("a")
        #expect(entry?.status == .completed)
        #expect(entry?.endedAt == end)
        #expect(entry?.activity == nil)
        #expect(entry?.transcriptPath == "/t/a.jsonl")
    }

    @Test func activityOnAFinishedRowIsIgnoredUnlessItRunsAgain() {
        var history = SubagentHistory()
        history.start(row("a", .completed))
        history.update("a", activity: "late", at: t0)
        #expect(history.entry("a")?.activity == nil)

        history.update("a", status: .active, activity: "resumed", at: t0)
        #expect(history.entry("a")?.activity == "resumed")
        #expect(history.entry("a")?.endedAt == nil)
    }

    @Test func updateOfAnUnknownIDReportsFalse() {
        var history = SubagentHistory()
        let found = history.update("missing", status: .completed, at: t0)
        #expect(!found)
    }

    @Test func pruneDropsOnlyFinishedRowsWhoseSeenTranscriptVanished() {
        var history = SubagentHistory()
        history.start(row("deleted", .completed, path: "/deleted"))
        history.start(row("kept", .completed, path: "/kept"))
        history.start(row("running", path: "/running"))
        history.start(row("pathless", .completed))
        let marked = history.prune { _ in true }
        #expect(marked)

        let pruned = history.prune { $0 == "/kept" }

        #expect(pruned)
        #expect(history.entries.map(\.id) == ["kept", "running", "pathless"])
        let prunedAgain = history.prune { $0 == "/kept" }
        #expect(!prunedAgain)
    }

    @Test func aTranscriptNeverWrittenKeepsItsRow() {
        var history = SubagentHistory()
        history.start(row("unwritten", .completed, path: "/unwritten"))

        let pruned = history.prune { _ in false }

        #expect(!pruned)
        #expect(history.entry("unwritten")?.transcriptSeen == nil)
    }

    @Test func aNewTranscriptPathForgetsTheOldOneWasSeen() {
        var history = SubagentHistory()
        history.start(row("a", .completed, path: "/old"))
        history.prune { _ in true }

        history.update("a", transcriptPath: "/new", at: t0)

        #expect(history.entry("a")?.transcriptSeen == nil)
        let pruned = history.prune { _ in false }
        #expect(!pruned)
    }

    @Test func clearResetsTheTruncationCount() {
        var history = SubagentHistory()
        for index in 0...SubagentHistory.limit { history.start(row("r\(index)")) }
        history.clear()
        #expect(history.isEmpty)
        #expect(history.droppedCount == 0)
    }

    @Test func decodeDropsAMalformedRowAndKeepsTheRest() throws {
        let json = """
        {"entries":[{"id":"ok","status":"completed","startedAt":0},{"id":"bad","status":"bogus","startedAt":0}],
         "droppedCount":3}
        """
        let history = try JSONDecoder().decode(SubagentHistory.self, from: Data(json.utf8))
        #expect(history.entries.map(\.id) == ["ok"])
        #expect(history.droppedCount == 3)
    }

    @Test func deferredParentStatusIsNotPersisted() throws {
        var history = SubagentHistory()
        history.start(row("a"))
        history.deferredParentStatus = AgentIndicator(status: .completed)
        let decoded = try JSONDecoder().decode(SubagentHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded.deferredParentStatus == nil)
        #expect(decoded.entries == history.entries)
    }

    @Test func onlyTheCurrentConversationsRowsShowAndAResumeBringsOldOnesBack() {
        var history = SubagentHistory()
        history.start(Subagent(id: "old", startedAt: t0, conversationID: "c1"))
        history.start(Subagent(id: "untagged", startedAt: t0))

        history.setConversation("c2")
        #expect(history.visibleEntries.map(\.id) == ["untagged"])
        history.start(Subagent(id: "new", startedAt: t0, conversationID: "c2"))
        #expect(history.visibleEntries.map(\.id) == ["untagged", "new"])

        history.setConversation("c1")
        #expect(history.visibleEntries.map(\.id) == ["old", "untagged"])
        #expect(history.entries.count == 3)
    }

    @Test func aRelaunchKeepsTheRowsButNotTheConversation() throws {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, conversationID: "c1"))
        var decoded = try JSONDecoder().decode(SubagentHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded.currentConversation == nil)
        #expect(decoded.visibleEntries.isEmpty)

        decoded.setConversation("c1")
        #expect(decoded.visibleEntries.map(\.id) == ["a"])
    }

    @Test func anExitedAgentHidesItsConversationsRows() {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, conversationID: "c1"))
        history.start(Subagent(id: "untagged", startedAt: t0))

        history.endConversation(at: t0)

        #expect(history.visibleEntries.map(\.id) == ["untagged"])
        #expect(history.entries.allSatisfy { $0.status == .completed })
        #expect(history.entries.count == 2)
    }

    @Test func aFinishedTurnCompletesRowsButKeepsTheConversation() {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, conversationID: "c1"))

        history.finishAll(at: t0)

        #expect(history.visibleEntries.map(\.id) == ["a"])
        #expect(history.entry("a")?.status == .completed)
    }

    @Test func aStaleEndOfAnotherConversationLeavesTheCurrentOneShowing() {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, conversationID: "current"))

        history.endConversation("blank-start-session", at: t0)

        #expect(history.currentConversation == "current")
        #expect(history.visibleEntries.map(\.id) == ["a"])
        #expect(history.entry("a")?.status == .active)
    }

    @Test func theCurrentConversationsEndHidesItsRows() {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, conversationID: "current"))

        history.endConversation("current", at: t0)

        #expect(history.visibleEntries.isEmpty)
        #expect(history.entry("a")?.status == .completed)
    }

    @Test func aFinishedStartStampsItsEnd() {
        var history = SubagentHistory()

        history.start(Subagent(id: "a", status: .completed, startedAt: t0))

        #expect(history.entry("a")?.endedAt == t0)
    }

    @Test func reimportingAKnownRowRefreshesItButKeepsItsTimesAndSeenTranscript() {
        var history = SubagentHistory()
        history.start(Subagent(id: "a", startedAt: t0, transcriptPath: "/t/a.jsonl"))
        history.update("a", status: .completed, at: t0.addingTimeInterval(60))
        history.prune { _ in true }

        history.start(Subagent(id: "a", summary: "audit", status: .completed, startedAt: t0.addingTimeInterval(500),
                               transcriptPath: "/t/a.jsonl", conversationID: "c1"))

        let row = history.entry("a")
        #expect(row?.startedAt == t0)
        #expect(row?.endedAt == t0.addingTimeInterval(60))
        #expect(row?.transcriptSeen == true)
        #expect(row?.summary == "audit")
        #expect(row?.conversationID == "c1")
    }
}
