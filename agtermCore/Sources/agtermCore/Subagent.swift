import Foundation

/// SubagentStatus is a subagent row's state. `idle` has no meaning for a row: a subagent exists only between
/// its start and its removal.
public enum SubagentStatus: String, Codable, Sendable, CaseIterable {
    case active, blocked, completed

    public var isRunning: Bool { self != .completed }
}

/// Subagent is one subagent an agent in the owning session spawned. `id` is the reporting agent's own id,
/// unique within the session.
public struct Subagent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var agentType: String?
    public var summary: String?
    public var status: SubagentStatus
    /// The last thing the subagent reported doing, such as the command it runs.
    public var activity: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// The subagent's transcript file. A finished row lives only while it does, once it has existed.
    public var transcriptPath: String?
    /// Whether `transcriptPath` was ever found on disk. An agent can name a transcript it never writes, so
    /// only a file seen and then gone means it was deleted. nil is false, keeping the saved form small.
    public var transcriptSeen: Bool?
    /// The reporting agent's conversation; the session shows only its current conversation's rows. nil for
    /// a client that reports none, which always shows.
    public var conversationID: String?

    public init(id: String, agentType: String? = nil, summary: String? = nil, status: SubagentStatus = .active,
                activity: String? = nil, startedAt: Date, endedAt: Date? = nil, transcriptPath: String? = nil,
                conversationID: String? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.agentType = agentType
        self.summary = summary
        self.status = status
        self.activity = activity
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcriptPath = transcriptPath
    }
}

/// SubagentHistory is a session's subagent rows, oldest first, capped at `limit`.
public struct SubagentHistory: Codable, Equatable, Sendable {
    public static let limit = 50

    public private(set) var entries: [Subagent] = []
    /// How many rows the cap has evicted since the last clear; nonzero draws the truncation row.
    public private(set) var droppedCount = 0
    /// The parent's `completed` held back while a subagent still ran; applied when the last one ends.
    /// Ephemeral: a relaunch has no running subagent to wait for.
    public var deferredParentStatus: AgentIndicator?
    /// The conversation the session's agent is in now; nil while no agent runs, so rows show only beside a
    /// live conversation. Ephemeral: after a relaunch the rows wait, saved, for that conversation's next start.
    public private(set) var currentConversation: String?

    enum CodingKeys: String, CodingKey { case entries, droppedCount }

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    /// The rows the session shows: its current conversation's, plus any reported without a conversation.
    public var visibleEntries: [Subagent] {
        entries.filter { $0.conversationID == nil || $0.conversationID == currentConversation }
    }
    public var hasRunning: Bool { entries.contains { $0.status.isRunning } }
    public var runningCount: Int { entries.filter { $0.status.isRunning }.count }

    public func entry(_ id: String) -> Subagent? { entries.first { $0.id == id } }

    /// Starts a row, or restarts an existing one under the same id. A finished start is a report of history,
    /// as a resume's import sends: it refreshes a known row's fields and keeps its times. Evicts the oldest
    /// finished row past the cap, else the oldest row.
    public mutating func start(_ subagent: Subagent) {
        if let conversation = subagent.conversationID { currentConversation = conversation }
        var subagent = subagent
        if !subagent.status.isRunning, subagent.endedAt == nil { subagent.endedAt = subagent.startedAt }
        if let index = entries.firstIndex(where: { $0.id == subagent.id }) {
            if subagent.status.isRunning {
                entries[index] = subagent
            } else {
                update(subagent.id, status: subagent.status, summary: subagent.summary, agentType: subagent.agentType,
                       transcriptPath: subagent.transcriptPath, at: subagent.endedAt ?? subagent.startedAt)
                if let conversation = subagent.conversationID { entries[index].conversationID = conversation }
            }
            return
        }
        entries.append(subagent)
        while entries.count > Self.limit {
            entries.remove(at: entries.firstIndex { !$0.status.isRunning } ?? 0)
            droppedCount += 1
        }
    }

    /// Applies each non-nil field to the row; false for an unknown id. A finishing status stamps `endedAt`.
    @discardableResult
    public mutating func update(_ id: String, status: SubagentStatus? = nil, activity: String? = nil,
                                summary: String? = nil, agentType: String? = nil, transcriptPath: String? = nil,
                                at now: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if let status {
            entries[index].status = status
            entries[index].endedAt = status.isRunning ? nil : (entries[index].endedAt ?? now)
            if !status.isRunning { entries[index].activity = nil }
        }
        if let activity, entries[index].status.isRunning { entries[index].activity = activity }
        if let summary { entries[index].summary = summary }
        if let agentType { entries[index].agentType = agentType }
        if let transcriptPath, transcriptPath != entries[index].transcriptPath {
            entries[index].transcriptPath = transcriptPath
            entries[index].transcriptSeen = nil
        }
        return true
    }

    /// Marks every running row completed: an agent whose turn ended without stopping its subagents, as Codex
    /// leaves an idle subagent thread open.
    public mutating func finishAll(at now: Date) {
        for index in entries.indices where entries[index].status.isRunning {
            entries[index].status = .completed
            entries[index].endedAt = now
            entries[index].activity = nil
        }
    }

    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// The agent exited: its running rows complete and its conversation's rows hide until it is resumed.
    /// A `conversation` other than the current one only completes that conversation's own rows: Codex ends the
    /// blank session it started with after `/resume` has already moved the pane to another one.
    public mutating func endConversation(_ conversation: String? = nil, at now: Date) {
        guard let conversation, conversation != currentConversation else {
            finishAll(at: now)
            currentConversation = nil
            return
        }
        for index in entries.indices where entries[index].conversationID == conversation && entries[index].status.isRunning {
            entries[index].status = .completed
            entries[index].endedAt = now
            entries[index].activity = nil
        }
    }

    /// Switches the shown rows to `conversation`, as a new or resumed conversation begins.
    public mutating func setConversation(_ conversation: String) {
        currentConversation = conversation
    }

    /// Keeps `deferredParentStatus`: the parent's held-back `completed` was already reported, and with no row
    /// left running `applySubagentChange` applies it.
    public mutating func clear() {
        entries = []
        droppedCount = 0
    }

    /// Records which transcripts exist and drops every finished row whose transcript existed and is gone;
    /// true when anything changed. A running row is kept, since an agent names its transcript before
    /// writing it, and so is a row whose transcript never appeared.
    @discardableResult
    public mutating func prune(fileExists: (String) -> Bool) -> Bool {
        let before = self
        entries = entries.compactMap { entry in
            guard let path = entry.transcriptPath else { return entry }
            var entry = entry
            if fileExists(path) {
                entry.transcriptSeen = true
                return entry
            }
            return entry.transcriptSeen == true && !entry.status.isRunning ? nil : entry
        }
        return self != before
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array(((try? c.decodeIfPresent([LossySubagent].self, forKey: .entries)) ?? [])
            .compactMap(\.value).suffix(Self.limit))
        droppedCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .droppedCount)) ?? 0)
    }
}

/// One persisted row decoded lossily, so a malformed row drops alone instead of failing the session.
private struct LossySubagent: Decodable {
    let value: Subagent?
    init(from decoder: Decoder) throws { value = try? Subagent(from: decoder) }
}
