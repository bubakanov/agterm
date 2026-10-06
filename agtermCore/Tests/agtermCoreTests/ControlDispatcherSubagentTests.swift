import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherSubagentTests {
    private func dispatch(_ args: ControlArgs, cmd: Command = .sessionSubagent,
                          target: String? = "s1") async -> (ControlResponse?, MockControlActions) {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: cmd, target: target,
                                                                                        args: args))
        return (response, actions)
    }

    @Test func startRoutesARunningRowWithItsFields() async throws {
        let (response, actions) = await dispatch(ControlArgs(mode: "start", window: "w", title: "probe child",
                                                             path: "/t/agent-a.jsonl", agent: "a",
                                                             agentType: "general-purpose"))

        #expect(response?.ok == true)
        guard case let .subagentChange(.start(row), target, window)? = actions.calls.first else {
            Issue.record("expected a start, got \(actions.calls)")
            return
        }
        #expect(target == "s1" && window == "w")
        #expect(row.id == "a" && row.agentType == "general-purpose" && row.summary == "probe child")
        #expect(row.status == .active && row.transcriptPath == "/t/agent-a.jsonl")
    }

    @Test func stopIsACompletingUpdate() async {
        let (_, actions) = await dispatch(ControlArgs(mode: "stop", path: "/t/a.jsonl", agent: "a"))
        #expect(actions.calls == [.subagentChange(.update(id: "a", status: .completed, activity: nil, summary: nil,
                                                          agentType: nil, transcriptPath: "/t/a.jsonl"),
                                                  target: "s1", window: nil)])
    }

    @Test func updateFlattensAndCapsTheActivity() async {
        let long = String(repeating: "x", count: ControlSubagentLimits.textLength + 10)
        let (_, actions) = await dispatch(ControlArgs(mode: "update", agent: "a", activity: "  npm\ntest  "))
        let (_, capped) = await dispatch(ControlArgs(mode: "update", agent: "a", activity: long))

        #expect(actions.calls == [.subagentChange(.update(id: "a", status: nil, activity: "npm test", summary: nil,
                                                          agentType: nil, transcriptPath: nil),
                                                  target: "s1", window: nil)])
        guard case let .subagentChange(.update(_, _, activity?, _, _, _), _, _)? = capped.calls.first else {
            Issue.record("expected an update")
            return
        }
        #expect(activity.count == ControlSubagentLimits.textLength)
        #expect(activity.hasSuffix("…"))
    }

    @Test func finishAndClearNeedNoAgent() async {
        let (_, finish) = await dispatch(ControlArgs(mode: "finish"))
        let (_, clear) = await dispatch(ControlArgs(mode: "clear"))
        let (_, end) = await dispatch(ControlArgs(mode: "end"))
        #expect(end.calls == [.subagentChange(.end(conversation: nil), target: "s1", window: nil)])
        #expect(finish.calls == [.subagentChange(.finishAll, target: "s1", window: nil)])
        #expect(clear.calls == [.subagentChange(.clear, target: "s1", window: nil)])
    }

    @Test func openRoutesToTheOpenAction() async {
        let (_, actions) = await dispatch(ControlArgs(mode: "open", window: "w", agent: "a"))
        #expect(actions.calls == [.subagentOpen("a", target: "s1", window: "w")])
    }

    @Test(arguments: [
        (ControlArgs(mode: "pause"), "invalid subagent action (start|update|stop|remove|finish|end|clear|open|conversation)"),
        (ControlArgs(mode: "conversation"), "session.subagent conversation requires a conversation id"),
        (ControlArgs(mode: "stop"), "session.subagent stop requires an agent id"),
        (ControlArgs(mode: "remove", agent: " \n"), "session.subagent remove requires an agent id"),
        (ControlArgs(mode: "update", status: "idle", agent: "a"),
         "invalid subagent status: idle (active|blocked|completed)"),
        (ControlArgs(mode: "start", path: "relative.jsonl", agent: "a"), "subagent transcript must be an absolute path"),
    ])
    func invalidRequestsAreRejectedWithoutCallingActions(_ args: ControlArgs, _ error: String) async {
        let (response, actions) = await dispatch(args)
        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [(nil, .read), ("on", .on), ("off", .off), ("toggle", .toggle)]
          as [(String?, ControlSubagentRowsMode)])
    func subagentsRoutesTheParsedMode(_ raw: String?, _ mode: ControlSubagentRowsMode) async {
        let (_, actions) = await dispatch(ControlArgs(mode: raw), cmd: .subagents, target: nil)
        #expect(actions.calls == [.subagentRows(mode)])
    }

    @Test func subagentsRejectsAnUnknownMode() async {
        let (response, actions) = await dispatch(ControlArgs(mode: "maybe"), cmd: .subagents, target: nil)
        #expect(response == ControlResponse(ok: false, error: "invalid subagents mode: maybe (read|on|off|toggle)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func conversationSwitchesTheShownConversation() async {
        let (_, actions) = await dispatch(ControlArgs(mode: "conversation", conversation: "c2"))
        #expect(actions.calls == [.subagentChange(.conversation("c2"), target: "s1", window: nil)])
    }

    @Test func startTagsTheRowWithItsConversation() async {
        let (_, actions) = await dispatch(ControlArgs(mode: "start", agent: "a", conversation: "c1"))
        guard case let .subagentChange(.start(row), _, _)? = actions.calls.first else {
            Issue.record("expected a start")
            return
        }
        #expect(row.conversationID == "c1")
    }

    @Test func endNamesTheConversationThatEnded() async {
        let (_, actions) = await dispatch(ControlArgs(mode: "end", conversation: "c1"))
        #expect(actions.calls == [.subagentChange(.end(conversation: "c1"), target: "s1", window: nil)])
    }
}
