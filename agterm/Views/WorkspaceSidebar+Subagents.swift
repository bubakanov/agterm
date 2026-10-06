import agtermCore
import AppKit
import CryptoKit

/// `WorkspaceSidebar.Coordinator`'s subagent rows: children of a session row, shown while Show subagents is
/// on. They are not sessions, so they are never selected, dragged, renamed or flagged; a click opens the
/// transcript over the owning session.
extension WorkspaceSidebar.Coordinator {
    /// A stable node id from the owning session and the agent id, so the shared node cache, row-content diff
    /// and in-place relabel work for subagent rows unchanged. A nil agent is the session's truncation row.
    static func subagentRowID(session: UUID, agent: String?) -> UUID {
        let digest = Insecure.MD5.hash(data: Data("\(session.uuidString)/\(agent ?? "…")".utf8))
        let bytes = Array(digest)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The rows under a session, truncation row first because the evicted rows are the oldest.
    private func subagentRows(for session: Session) -> [(id: UUID, agent: String?)] {
        let visible = session.subagents.visibleEntries
        guard GhosttyApp.shared.showSubagents, !visible.isEmpty else { return [] }
        var rows = visible.map { (Self.subagentRowID(session: session.id, agent: $0.id), Optional($0.id)) }
        if session.subagents.droppedCount > 0 {
            rows.insert((Self.subagentRowID(session: session.id, agent: nil), nil), at: 0)
        }
        return rows.map { (id: $0.0, agent: $0.1) }
    }

    func subagentRowIDs(for session: Session) -> [UUID] {
        subagentRows(for: session).map(\.id)
    }

    /// A session node with its subagent children rebuilt, recording every id it renders in `seen`.
    func sessionNode(_ session: Session, seen: inout Set<UUID>) -> SidebarNode {
        let sessionNode = node(for: session.id, kind: .session)
        sessionNode.children = subagentRows(for: session).map { row in
            seen.insert(row.id)
            if let cached = nodeCache[row.id] { return cached }
            let child = SidebarNode(kind: .subagent, id: row.id, ownerSessionID: session.id, agentID: row.agent)
            nodeCache[row.id] = child
            return child
        }
        return sessionNode
    }

    /// Re-opens the sessions the user expanded, after a rebuild dropped the outline's own state.
    func restoreSessionExpansion(in outline: NSOutlineView) {
        expandedSessionIDs.formIntersection(Set(nodeCache.keys))
        for id in expandedSessionIDs {
            guard let node = nodeCache[id], !node.children.isEmpty else { continue }
            outline.expandItem(node)
        }
    }

    /// Opening a session's rows is when a vanished transcript is noticed; the prune reshapes the tree.
    func sessionDidExpand(_ node: SidebarNode) {
        expandedSessionIDs.insert(node.id)
        store.pruneSubagents(forSession: node.id)
    }

    func subagentRowContents(for session: Session) -> [(UUID, RowContent)] {
        subagentRows(for: session).map { row in
            let node = SidebarNode(kind: .subagent, id: row.id, ownerSessionID: session.id, agentID: row.agent)
            return (row.id, RowContent(label: subagentLabel(node), hasSplit: false, splitAxis: .leftRight, unseen: 0,
                                       indicator: subagentIndicator(node), flagged: false, focusMember: false))
        }
    }

    private func subagent(_ node: SidebarNode) -> Subagent? {
        guard let owner = node.ownerSessionID, let agent = node.agentID else { return nil }
        return store.session(withID: owner)?.subagents.entry(agent)
    }

    /// What the row reads: its description (else type, else id), then what it is doing while it runs.
    func subagentLabel(_ node: SidebarNode) -> String {
        guard let subagent = subagent(node) else {
            let dropped = node.ownerSessionID.flatMap { store.session(withID: $0)?.subagents.droppedCount } ?? 0
            return "\(dropped) older"
        }
        let name = subagent.summary ?? subagent.agentType ?? subagent.id
        guard subagent.status.isRunning, let activity = subagent.activity else { return name }
        return "\(name) · \(activity)"
    }

    func subagentIndicator(_ node: SidebarNode) -> AgentIndicator {
        switch subagent(node)?.status {
        case .active?: AgentIndicator(status: .active)
        case .blocked?: AgentIndicator(status: .blocked)
        case .completed?: AgentIndicator(status: .completed)
        case nil: AgentIndicator()
        }
    }

    /// Fills a subagent cell. The tooltip carries the full label, which the row truncates.
    func configureSubagentCell(_ cell: SidebarCellView, node: SidebarNode) {
        let label = subagentLabel(node)
        cell.textField?.stringValue = label
        cell.textField?.font = .systemFont(ofSize: max(GhosttyApp.shared.sidebarFontSize - 1, 9))
        cell.textField?.setAccessibilityIdentifier(node.agentID == nil ? "subagent-truncation-row" : "subagent-row")
        cell.textField?.setAccessibilityLabel(label)
        cell.statusIcon.apply(subagentIndicator(node))
        cell.imageView?.image = node.agentID == nil ? subagentTruncationIcon : subagentIcon
        cell.imageView?.toolTip = subagent(node).map { [label, $0.transcriptPath].compactMap { $0 }.joined(separator: "\n") }
        cell.imageView?.setAccessibilityIdentifier("subagent-icon")
    }

    /// The clicked subagent row's index while its session is the selected one; otherwise forgets it.
    /// The highlight lasts exactly as long as that subagent's transcript is open, so closing it any way at all
    /// (⌘W, the pager's q, another row) hands the selection back to the session.
    func highlightedSubagentRow(forSelectedSession selectedID: UUID, in outline: NSOutlineView) -> Int? {
        guard let id = highlightedSubagentRowID else { return nil }
        guard let node = nodeCache[id], node.ownerSessionID == selectedID,
              let owner = store.session(withID: selectedID), AppActions.showsSubagentTranscript(owner) else {
            highlightedSubagentRowID = nil
            return nil
        }
        let row = outline.row(forItem: node)
        return row >= 0 ? row : nil
    }

    /// Hiding a session's rows leaves its subagent: the transcript closes and the session row takes the
    /// selection, which AppKit otherwise drops with the hidden row.
    func sessionDidCollapse(_ node: SidebarNode) {
        expandedSessionIDs.remove(node.id)
        guard let highlighted = highlightedSubagentRowID, nodeCache[highlighted]?.ownerSessionID == node.id else { return }
        highlightedSubagentRowID = nil
        actions.closeSubagentTranscript(session: node.id, in: store)
        syncSelection()
    }

    /// Selects the owning session, marks the clicked row, and shows the transcript over the session; a
    /// refusal beeps, since a click has no other place to report it.
    func openSubagent(_ node: SidebarNode) {
        guard let owner = node.ownerSessionID, let agent = node.agentID else { return }
        if let previous = store.selectedSessionID, previous != owner {
            actions.closeSubagentTranscript(session: previous, in: store)
        }
        selectOwner(owner)
        Task { @MainActor in
            guard await actions.openSubagentTranscript(agent, session: owner, in: store) == nil else {
                NSSound.beep()
                return
            }
            // only now: the highlight needs the transcript open, or the next sync takes it straight back
            highlightedSubagentRowID = node.id
            syncSelection()
        }
    }

    /// Selecting counts as visiting, which clears an auto-reset `completed` glyph, so the session already
    /// on screen is not selected again just because one of its subagent rows was clicked.
    private func selectOwner(_ owner: UUID) {
        if store.selectedSessionID != owner { store.selectSession(owner) }
    }

    /// A session-row pick is the way back from a transcript: the viewer closes on the session being left and
    /// on the one picked, so the user never has to know the pager's quit key.
    func closeSubagentTranscripts(leaving previous: UUID?, arrivingAt next: UUID) {
        for id in Set([previous, next].compactMap { $0 }) { actions.closeSubagentTranscript(session: id, in: store) }
    }

    /// No Remove: a row removed here would come back the next time its conversation is resumed, since the
    /// hook re-reports a conversation's subagents from Claude's own files.
    func subagentMenu(_ node: SidebarNode) -> NSMenu? {
        guard node.agentID != nil else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open Transcript", action: #selector(menuOpenSubagent(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = node
        let hasTranscript = subagent(node)?.transcriptPath != nil
        open.isEnabled = hasTranscript
        menu.addItem(open)
        for (title, action) in [("Copy Transcript", #selector(menuCopySubagent(_:))),
                                ("Mention in Chat", #selector(menuMentionSubagent(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            item.isEnabled = hasTranscript
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuOpenSubagent(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        openSubagent(node)
    }

    @objc private func menuCopySubagent(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let owner = node.ownerSessionID,
              let agent = node.agentID else { return }
        Task { @MainActor in
            if await actions.copySubagentTranscript(agent, session: owner, in: store) != nil { NSSound.beep() }
        }
    }

    /// Mentions the transcript at the parent agent's prompt; the session is selected first so the typed
    /// reference lands in the chat the user is looking at.
    @objc private func menuMentionSubagent(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let owner = node.ownerSessionID,
              let agent = node.agentID else { return }
        selectOwner(owner)
        if actions.mentionSubagentTranscript(agent, session: owner, in: store) != nil { NSSound.beep() }
    }
}
