import Foundation

/// SubagentChange is one `session.subagent` write against a session's rows.
public enum SubagentChange: Equatable, Sendable {
    case start(Subagent)
    case update(id: String, status: SubagentStatus?, activity: String?, summary: String?, agentType: String?,
                transcriptPath: String?)
    case remove(id: String)
    /// A new or resumed conversation began; the session shows that conversation's rows.
    case conversation(String)
    /// Marks every running row completed; the reporting agent's turn ended.
    case finishAll
    /// The reporting agent exited: running rows complete and the conversation's rows hide. Naming the
    /// conversation that ended keeps a stale end from hiding the conversation the session moved on to.
    case end(conversation: String?)
    case clear
}

extension SubagentChange {
    /// Whether this write records subagent activity, which Show subagents gates. Removal, clearing and
    /// finishing only tidy rows already recorded, so they run whatever the setting.
    public var records: Bool {
        switch self {
        case .start, .update: return true
        case .remove, .finishAll, .end, .clear, .conversation: return false
        }
    }
}

public enum SubagentChangeResult: Equatable, Sendable {
    case applied
    case unknownSubagent
    case unknownSession
}

extension AppStore {
    /// Applies a subagent write, then settles the parent's held-back `completed` once nothing runs.
    @discardableResult
    public func applySubagentChange(_ change: SubagentChange, forSession id: UUID,
                                    now: Date = Date()) -> SubagentChangeResult {
        guard let session = session(withID: id) else { return .unknownSession }
        let before = session.subagents
        var history = before
        switch change {
        case .start(let subagent):
            history.start(subagent)
        case let .update(subagentID, status, activity, summary, agentType, transcriptPath):
            guard history.update(subagentID, status: status, activity: activity, summary: summary,
                                 agentType: agentType, transcriptPath: transcriptPath, at: now) else {
                return .unknownSubagent
            }
        case .remove(let subagentID):
            guard history.remove(subagentID) else { return .unknownSubagent }
        case .finishAll:
            history.finishAll(at: now)
        case .end(let conversation):
            history.endConversation(conversation, at: now)
        case .conversation(let conversation):
            history.setConversation(conversation)
        case .clear:
            history.clear()
        }
        let deferred = history.hasRunning ? nil : history.deferredParentStatus
        if deferred != nil { history.deferredParentStatus = nil }
        guard history != before else { return .applied }
        session.subagents = history
        emitSubagentEvents(from: before, to: history, session: session)
        if let deferred { setAgentIndicator(deferred, forSession: id) }
        save()
        return .applied
    }

    /// The parent's own `completed` while a subagent still runs: the agent's turn ended but its background
    /// subagents did not. Shows `active` and keeps the write for `applySubagentChange` to apply later.
    func holdingCompletionForSubagents(_ indicator: AgentIndicator, session: Session) -> AgentIndicator {
        guard indicator.status == .completed, session.subagents.hasRunning else {
            if indicator.status != .completed { session.subagents.deferredParentStatus = nil }
            return indicator
        }
        session.subagents.deferredParentStatus = indicator
        var held = indicator
        held.status = .active
        held.autoReset = false
        return held
    }

    /// Restored rows: running ones are marked completed, since no agent survives to finish them, and rows
    /// whose transcript was deleted are dropped.
    func restoredSubagents(_ stored: SubagentHistory?) -> SubagentHistory {
        guard var history = stored else { return SubagentHistory() }
        history.finishAll(at: Date())
        history.prune(fileExists: subagentTranscriptExists)
        return history
    }

    /// Drops the session's rows whose transcript was deleted, at expand and before opening one.
    public func pruneSubagents(forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        var history = session.subagents
        guard history.prune(fileExists: subagentTranscriptExists) else { return }
        let removedRows = history.entries.count != session.subagents.entries.count
        session.subagents = history
        if removedRows { scheduleTreeChanged() }
        save()
    }

    private func emitSubagentEvents(from before: SubagentHistory, to after: SubagentHistory, session: Session) {
        let workspaceID = workspace(forSession: session.id)?.id
        for entry in after.entries {
            let previous = before.entry(entry.id)?.status
            guard previous != entry.status else { continue }
            emitControlEvent(.subagent, workspace: workspaceID, session: session.id,
                             payload: ControlEventPayload(name: session.displayName, status: entry.status.rawValue,
                                                          previous: previous?.rawValue,
                                                          title: entry.summary ?? entry.agentType, agent: entry.id))
        }
        if before.visibleEntries.map(\.id) != after.visibleEntries.map(\.id) { scheduleTreeChanged() }
    }
}
