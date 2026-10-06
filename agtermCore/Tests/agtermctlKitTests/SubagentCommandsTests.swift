import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct SubagentCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        guard let command = try Agtermctl.parseAsRoot(argv) as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func startCarriesEveryField() throws {
        let argv = ["session", "subagent", "start", "a825", "--type", "general-purpose", "--description", "probe",
                    "--transcript", "/t/agent-a825.jsonl", "--target", "s1", "--window", "w1"]
        #expect(try request(argv) == ControlRequest(
            cmd: .sessionSubagent, target: "s1",
            args: ControlArgs(mode: "start", window: "w1", title: "probe", path: "/t/agent-a825.jsonl",
                              agent: "a825", agentType: "general-purpose")))
    }

    @Test func updateCarriesActivityAndStatus() throws {
        #expect(try request(["session", "subagent", "update", "a", "--activity", "npm test", "--status", "blocked"])
            == ControlRequest(cmd: .sessionSubagent, target: "active",
                              args: ControlArgs(mode: "update", status: "blocked", agent: "a", activity: "npm test")))
    }

    @Test func finishAndClearTakeNoAgent() throws {
        #expect(try request(["session", "subagent", "finish"])
            == ControlRequest(cmd: .sessionSubagent, target: "active", args: ControlArgs(mode: "finish")))
        #expect(try request(["session", "subagent", "clear"])
            == ControlRequest(cmd: .sessionSubagent, target: "active", args: ControlArgs(mode: "clear")))
    }

    @Test(arguments: [
        (["session", "subagent", "pause", "a"], "action must be one of: start|update|stop|remove|finish|end|clear|open|conversation"),
        (["session", "subagent", "conversation"], "conversation requires the conversation id"),
        (["session", "subagent", "stop"], "stop requires the subagent id"),
        (["session", "subagent", "update", "a", "--status", "idle"], "status must be active, blocked, or completed"),
        (["subagents", "maybe"], "mode must be on, off, or toggle"),
    ])
    func invalidInvocationsFailValidation(_ argv: [String], _ message: String) {
        #expect(validationMessage(argv)?.contains(message) == true)
    }

    @Test func subagentsReadsBareAndSetsWithAMode() throws {
        #expect(try request(["subagents"]) == ControlRequest(cmd: .subagents, args: ControlArgs()))
        #expect(try request(["subagents", "on"]) == ControlRequest(cmd: .subagents, args: ControlArgs(mode: "on")))
    }

    @Test func conversationTakesItsIDPositionally() throws {
        #expect(try request(["session", "subagent", "conversation", "c2"])
            == ControlRequest(cmd: .sessionSubagent, target: "active", args: ControlArgs(mode: "conversation", conversation: "c2")))
    }

    @Test func endTakesTheConversationPositionally() throws {
        #expect(try request(["session", "subagent", "end", "c1"])
            == ControlRequest(cmd: .sessionSubagent, target: "active", args: ControlArgs(mode: "end", conversation: "c1")))
        #expect(try request(["session", "subagent", "end"])
            == ControlRequest(cmd: .sessionSubagent, target: "active", args: ControlArgs(mode: "end")))
    }
}
