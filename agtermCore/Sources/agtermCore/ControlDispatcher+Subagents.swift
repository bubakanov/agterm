import Foundation

/// The `subagents` setting command's mode; `read` answers the current state without changing it.
public enum ControlSubagentRowsMode: String, CaseIterable, Equatable, Sendable {
    case read, on, off, toggle

    public static func parse(_ mode: String?) -> ControlSubagentRowsMode? {
        mode.map { ControlSubagentRowsMode(rawValue: $0) } ?? .read
    }

    /// The setting after this mode applies to `current`.
    public func resolve(_ current: Bool) -> Bool {
        switch self {
        case .read: return current
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }
}

/// The `session.subagent` actions, as the wire spells them.
public enum ControlSubagentAction: String, CaseIterable, Equatable, Sendable {
    case start, update, stop, remove, finish, end, clear, open, conversation

    public static var validNamesList: String { allCases.map(\.rawValue).joined(separator: "|") }

    var needsAgent: Bool { ![.finish, .end, .clear, .conversation].contains(self) }
}

public enum ControlSubagentLimits {
    public static let idLength = 128
    public static let textLength = 200
}

extension ControlDispatcher {
    func dispatchSubagentCommand(_ request: ControlRequest) async -> ControlResponse {
        let args = request.args
        if request.cmd == .subagents {
            guard let mode = ControlSubagentRowsMode.parse(args?.mode) else {
                return ControlResponse(ok: false, error: "invalid subagents mode: \(args?.mode ?? "")"
                                           + " (\(ControlSubagentRowsMode.allCases.map(\.rawValue).joined(separator: "|")))")
            }
            return actions.setSubagentRows(mode)
        }
        guard let action = ControlSubagentAction(rawValue: args?.mode ?? "") else {
            return ControlResponse(ok: false, error: "invalid subagent action (\(ControlSubagentAction.validNamesList))")
        }
        let agent = Self.subagentText(args?.agent, limit: ControlSubagentLimits.idLength)
        if action.needsAgent, agent == nil {
            return ControlResponse(ok: false, error: "session.subagent \(action.rawValue) requires an agent id")
        }
        var status: SubagentStatus?
        if let raw = args?.status {
            guard let parsed = SubagentStatus(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid subagent status: \(raw) (active|blocked|completed)")
            }
            status = parsed
        }
        var transcript: String?
        if let path = args?.path {
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { return ControlResponse(ok: false, error: "subagent transcript must be an absolute path") }
            transcript = path
        }
        let summary = Self.subagentText(args?.title, limit: ControlSubagentLimits.textLength)
        let agentType = Self.subagentText(args?.agentType, limit: ControlSubagentLimits.textLength)
        let activity = Self.subagentText(args?.activity, limit: ControlSubagentLimits.textLength)
        let conversation = Self.subagentText(args?.conversation, limit: ControlSubagentLimits.idLength)
        if action == .conversation, conversation == nil {
            return ControlResponse(ok: false, error: "session.subagent conversation requires a conversation id")
        }
        let change: SubagentChange
        switch action {
        case .open:
            return await actions.openSubagent(agent ?? "", target: request.target, window: args?.window)
        case .start:
            change = .start(Subagent(id: agent ?? "", agentType: agentType, summary: summary, status: status ?? .active,
                                     activity: activity, startedAt: Date(), transcriptPath: transcript,
                                     conversationID: conversation))
        case .update:
            change = .update(id: agent ?? "", status: status, activity: activity, summary: summary,
                             agentType: agentType, transcriptPath: transcript)
        case .stop:
            change = .update(id: agent ?? "", status: .completed, activity: nil, summary: summary,
                             agentType: agentType, transcriptPath: transcript)
        case .remove:
            change = .remove(id: agent ?? "")
        case .finish:
            change = .finishAll
        case .end:
            change = .end(conversation: conversation)
        case .clear:
            change = .clear
        case .conversation:
            change = .conversation(conversation ?? "")
        }
        return actions.applySubagentChange(change, target: request.target, window: args?.window)
    }

    /// One display line: control characters become spaces, the result is trimmed and capped; nil when blank.
    static func subagentText(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
    }
}
