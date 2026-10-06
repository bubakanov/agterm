import Foundation
import XCTest

@MainActor
final class SubagentRowsUITests: ControlAPITestCase {
    private func firstSession() throws -> [String: Any] {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let root = try XCTUnwrap((tree["result"] as? [String: Any])?["tree"] as? [String: Any])
        let workspace = try XCTUnwrap((root["workspaces"] as? [[String: Any]])?.first)
        return try XCTUnwrap((workspace["sessions"] as? [[String: Any]])?.first)
    }

    func testSubagentRowExpandsUnderItsSessionAndOpensItsTranscript() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10))
        let transcript = stateDir.appendingPathComponent("agent-a1.jsonl")
        try #"{"type":"user","message":{"role":"user","content":"probe"}}"#.write(to: transcript, atomically: true, encoding: .utf8)

        XCTAssertEqual(try sendCommand(#"{"cmd":"subagents","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        let start = try sendCommand(#"{"cmd":"session.subagent","target":"active","args":{"mode":"start","agent":"a1","#
            + #""agentType":"general-purpose","title":"probe child","path":"\#(transcript.path)"}}"#)
        XCTAssertEqual(start["ok"] as? Bool, true, "start should succeed: \(start)")
        XCTAssertFalse(app.staticTexts["subagent-row"].exists, "a session's subagent rows start collapsed")

        let sessionRow = app.outlineRows.containing(.staticText, identifier: "session-row").firstMatch
        sessionRow.disclosureTriangles.firstMatch.click()
        let row = app.staticTexts["subagent-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "expanding the session should show its subagent row")
        XCTAssertEqual(row.label, "probe child")

        row.click()
        let opened = expectation(for: NSPredicate { _, _ in (try? self.firstSession()["overlay"] as? Bool) == true },
                                 evaluatedWith: nil)
        wait(for: [opened], timeout: 10)

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.overlay.close","target":"active"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"subagents","args":{"mode":"off"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "turning the setting off should hide the rows")
    }
}
