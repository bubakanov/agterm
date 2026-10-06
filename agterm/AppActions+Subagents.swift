import agtermCore
import AppKit
import Foundation

extension AppActions {
    /// The bundled viewer; its name in an overlay's command is how a transcript viewer is told from any other
    /// program overlay, which picking a row must never close.
    nonisolated static let subagentViewerName = "agterm-transcript-view.sh"

    /// Shows a subagent's transcript in a terminal overlay over its session, the one path for the sidebar row
    /// and `session.subagent open`. A transcript already open there is replaced, so picking another row
    /// switches the view. Returns nil on success, else the refusal; a deleted transcript drops its row.
    func openSubagentTranscript(_ agentID: String, session sessionID: UUID, in store: AppStore) async -> String? {
        store.pruneSubagents(forSession: sessionID)
        guard let entry = store.session(withID: sessionID)?.subagents.entry(agentID) else {
            return "unknown subagent: \(agentID)"
        }
        guard let transcript = entry.transcriptPath else { return "subagent \(agentID) has no transcript" }
        guard let viewer = Bundle.main.resourceURL?.appendingPathComponent("agent-status/\(Self.subagentViewerName)"),
              FileManager.default.isReadableFile(atPath: viewer.path) else {
            return "transcript viewer is not bundled"
        }
        closeSubagentTranscript(session: sessionID, in: store)
        let title = entry.summary ?? entry.agentType ?? agentID
        // the overlay wrapper evals this line, so every argument is escaped; /bin/sh survives a lost exec bit
        // a running subagent's transcript is still growing, so the viewer follows it like tail -f
        let follow = entry.status.isRunning ? " --follow" : ""
        let command = "/bin/sh \(ShellEscape.path(viewer.path)) \(ShellEscape.path(transcript)) \(ShellEscape.path(title))\(follow)"
        guard store.openOverlay(sessionID, command: command) else { return "overlay already open" }
        return nil
    }

    /// Closes the session's transcript viewer, leaving any other overlay alone; true when one was open.
    @discardableResult
    func closeSubagentTranscript(session sessionID: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: sessionID), Self.showsSubagentTranscript(session) else { return false }
        return store.closeOverlay(sessionID)
    }

    /// Whether the session's overlay is a transcript viewer, however it was opened or will close.
    static func showsSubagentTranscript(_ session: Session) -> Bool {
        session.programOverlayActive && session.overlayCommand?.contains(subagentViewerName) == true
    }

    /// Copies the transcript as the viewer shows it, without its styling. Menu-only: a write to the system
    /// pasteboard gets no control command. Returns nil on success, else the refusal.
    func copySubagentTranscript(_ agentID: String, session sessionID: UUID, in store: AppStore) async -> String? {
        guard let entry = store.session(withID: sessionID)?.subagents.entry(agentID),
              let transcript = entry.transcriptPath else { return "subagent \(agentID) has no transcript" }
        guard let viewer = Bundle.main.resourceURL?.appendingPathComponent("agent-status/\(Self.subagentViewerName)")
        else { return "transcript viewer is not bundled" }
        let title = entry.summary ?? entry.agentType ?? agentID
        guard let text = await Self.renderTranscriptText(viewer: viewer.path, transcript: transcript, title: title) else {
            return "could not read the transcript of subagent \(agentID)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return nil
    }

    /// Takes the user back to the chat and types `@<transcript> ` at its prompt, unsubmitted, so the parent
    /// agent reads the whole transcript itself instead of a pasted, size-limited copy.
    func mentionSubagentTranscript(_ agentID: String, session sessionID: UUID, in store: AppStore) -> String? {
        guard let session = store.session(withID: sessionID),
              let transcript = session.subagents.entry(agentID)?.transcriptPath else {
            return "subagent \(agentID) has no transcript"
        }
        closeSubagentTranscript(session: sessionID, in: store)
        guard let pane = session.activeSurface as? GhosttySurfaceView, pane.inject(text: "@\(transcript) ") else {
            return "session not realized"
        }
        focusActiveSession()
        return nil
    }

    /// The viewer's text with its SGR styling removed: `less` writing to a pipe passes the text straight
    /// through. nil when the render fails or outlives its deadline.
    nonisolated static func renderTranscriptText(viewer: String, transcript: String, title: String) async -> String? {
        await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [viewer, transcript, title]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            guard (try? process.run()) != nil else { return nil }
            let deadline = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }.value
    }
}
