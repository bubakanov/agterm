import ArgumentParser
import agtermCore

extension Session {
    struct SubagentCommand: RequestCommand {
        static let configuration = CommandConfiguration(
            commandName: "subagent",
            abstract: "Report or open a subagent row under a session.",
            discussion: """
            session subagent start ID --type T --description D   add a running row
            session subagent update ID --activity "npm test"     change any field
            session subagent stop ID --transcript PATH           mark it completed
            session subagent open ID                             show its transcript over the session
            session subagent remove ID | clear                   drop one, drop all
            session subagent finish | end [CONV]                 complete running rows; end also hides the conversation
            session subagent conversation CONV                   show only conversation CONV's rows

            Rows are recorded only while Settings ▸ Agent Status ▸ Show subagents is on (`agtermctl \
            subagents`); writes while it is off succeed and change nothing. A finished row is dropped once \
            its transcript is deleted. Rows read back on `tree` as each session's `subagents`.
            """)
        @Argument(help: "Action: \(ControlSubagentAction.validNamesList).") var action: String
        @Argument(help: "The subagent's id, or the conversation id for conversation; not taken by finish, end and clear.")
        var agent: String?
        @Option(name: .customLong("type"), help: "Agent type, such as general-purpose.") var agentType: String?
        @Option(name: .long, help: "What the subagent was asked to do.") var description: String?
        @Option(name: .long, help: "What it is doing now, such as the command it runs.") var activity: String?
        @Option(name: .long, help: "active, blocked, or completed (update only).") var status: String?
        @Option(name: .long, help: "Absolute path of the subagent's transcript file.") var transcript: String?
        @Option(name: .long, help: "The reporting agent's conversation id (start only).") var conversation: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard let parsed = ControlSubagentAction(rawValue: action) else {
                throw ValidationError("action must be one of: \(ControlSubagentAction.validNamesList)")
            }
            if agent == nil, parsed == .conversation { throw ValidationError("conversation requires the conversation id") }
            if agent == nil, ![ControlSubagentAction.finish, .end, .clear].contains(parsed) {
                throw ValidationError("\(action) requires the subagent id")
            }
            if let status, SubagentStatus(rawValue: status) == nil {
                throw ValidationError("status must be active, blocked, or completed")
            }
        }

        func makeRequest() throws -> ControlRequest {
            // conversation and end take a conversation id where the others take a subagent id
            let switching = [ControlSubagentAction.conversation.rawValue, ControlSubagentAction.end.rawValue].contains(action)
            return ControlRequest(cmd: .sessionSubagent, target: target.target,
                                  args: options.withWindow(ControlArgs(mode: action, title: description, status: status,
                                                                        path: transcript, agent: switching ? nil : agent,
                                                                        agentType: agentType, activity: activity,
                                                                        conversation: switching ? agent : conversation)))
        }
    }
}

/// `agtermctl subagents [on|off|toggle]`: the app-wide Show subagents setting; bare reads it.
struct Subagents: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Show subagent rows under sessions (on|off|toggle).")
    @Argument(help: "Mode: on, off, or toggle; omit to read the setting.") var mode: String?
    @OptionGroup var options: BasicOptions

    func validate() throws {
        if let mode, ![ControlSubagentRowsMode.on, .off, .toggle].map(\.rawValue).contains(mode) {
            throw ValidationError("mode must be on, off, or toggle")
        }
    }

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .subagents, args: ControlArgs(mode: mode))
    }
}
