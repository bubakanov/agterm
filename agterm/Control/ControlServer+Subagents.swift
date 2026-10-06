import agtermCore
import Foundation

extension ControlServer {
    /// While Show subagents is off a recording write answers ok and changes nothing, so a hook never fails
    /// on the setting; the note says why the row did not appear.
    func applySubagentChange(_ change: SubagentChange, target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            if change.records, !GhosttyApp.shared.showSubagents {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: Self.subagentsOffNote))
            }
            switch store.applySubagentChange(change, forSession: id) {
            case .applied: return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            case .unknownSubagent: return ControlResponse(ok: false, error: "unknown subagent")
            case .unknownSession: return ControlResponse(ok: false, error: "session not found")
            }
        }
    }

    func openSubagent(_ agent: String, target: String?, window: String?) async -> ControlResponse {
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response):
            return response
        case .success(let (store, id)):
            if let failure = await actions.openSubagentTranscript(agent, session: id, in: store) {
                return ControlResponse(ok: false, error: failure)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// App-wide like `setFlaggedViewLayout`, written through the Settings toggle's setter; echoes the result.
    func setSubagentRows(_ mode: ControlSubagentRowsMode) -> ControlResponse {
        let want = mode.resolve(settingsModel.settings.showSubagents ?? false)
        if mode != .read { settingsModel.setShowSubagents(want) }
        return ControlResponse(ok: true, result: ControlResult(text: want ? "on" : "off"))
    }

    static let subagentsOffNote = "Show subagents is off, nothing recorded"
}
