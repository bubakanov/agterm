# Subagent rows

Status: implemented on branch `subagent-rows`; maintainer review happens on the PR.

## Overview
- A coding agent's subagents appear as child rows under the session whose agent spawned them, each with
  its own status, and stay reachable from that session as history.
- Child rows are owned by the parent session: not sessions, not draggable, renamable, flaggable or
  selectable on their own. Selecting one acts on the parent. Closing the parent removes every row and link.
- A row exists only while its transcript file does. A missing file removes the row, never a placeholder.
- Opt-in: Settings ▸ Agent Status ▸ Show subagents, off by default. Off hides the rows and drops new
  subagent events; recorded rows return when it is turned back on, after the transcript check.
- Generic control API (`session.subagent.*`); the Claude Code hooks are one client, so Codex, OpenCode or a
  script can report subagents the same way. Agent-specific parsing stays in the installed hook package.

## Context (from discovery)
- Probe 2026-10-05, Claude Code 2.1.289, headless `claude -p` with a logging `--settings` hook:
  - `SubagentStart`: `session_id`, `transcript_path` (parent), `prompt_id`, `agent_id`, `agent_type`.
    No description, no agent transcript path.
  - `SubagentStop`: adds `agent_transcript_path` =
    `<dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.jsonl`, and `last_assistant_message`.
  - A sibling `agent-<id>.meta.json` holds `description`, `agentType`, `toolUseId`, `spawnDepth`.
  - A subagent's own `PreToolUse`/`PostToolUse` carry `agent_id`/`agent_type`; the parent's `Agent` call
    does not.
  - The subagent ran in the background: the parent's `Stop` fired while it ran, listing it in
    `background_tasks` as `running`, and its completion re-entered the parent as a synthetic
    `UserPromptSubmit` (`<task-notification>`).
  - Every hook, the subagent's included, runs as a child of the parent `claude` and inherits its
    environment, so `AGTERM_SESSION_ID`/`AGTERM_PANE_ID` link a subagent to its pane, and
    `agterm-claude-status.sh`'s worker guard counts one agent and reports.
  - These fields are undocumented internals; re-probe on Claude Code upgrades.
- Model: `Session` (`agtermCore/Sources/agtermCore/Session.swift`, 995/1000 lines) carries
  `agentIndicator`; `SessionSnapshot` (`Snapshot.swift:138`) is the persisted form.
  `RecentClosedSession` (`RecentClosed.swift:40`) stores a full `SessionSnapshot`, so reopen restores
  subagents with no extra plumbing.
- Hooks: `AgentHooksInstall.claudeHooks` (`AgentHooksInstall.swift:119`) maps events to plain states for
  `agterm-claude-status.sh`, which forwards argv to `agterm-agent-status.sh` and never reads stdin.
- Sidebar: `SidebarNode.Kind { workspace, session }` (`agterm/Views/SidebarRowViews.swift:292`);
  `WorkspaceSidebar.swift` is 901 lines.
- Settings: Agent Status tab in `agterm/Views/SettingsView.swift` (933 lines); model in
  `AppSettings.swift` (`statusReset`, `autoFollowAttention` as precedent).
- Control: `ControlProtocol.swift` (`session.status` at :25), read-back `ControlSessionNode`
  (`ControlProjection.swift:162`).

## Development Approach
- TDD for everything host-free in `agtermCore`: model, persistence, pruning, dispatcher, projection, CLI.
  Sidebar and Settings get hosted/XCUITest coverage after their code.
- `Session` gains exactly one stored property; logic goes in `Session+Subagents.swift` and
  `AppStore+Subagents.swift`. Ask before splitting any file that crosses a lint limit.
- Additive public API only: `agterm-linux` consumes `agtermCore`.
- Targeted test runs per task; `swift test`, `make test-app`, `make lint` once, in the final task.
- Manual verification only in an isolated Debug instance; never install hooks from it.

## Solution Overview
- **Model.** `Subagent` value: `id` (agent's own id), `agentType`, `description?`, `status`
  (`active|completed|blocked`), `activity?` (last tool summary), `startedAt`, `endedAt?`,
  `transcriptPath?`, `paneIdentity?`. `Session.subagents: [Subagent]`, capped per session (oldest
  finished dropped first), persisted in `SessionSnapshot.subagents` (nil when empty).
- **Pruning.** One function checks each `transcriptPath` with a file-exists test and removes rows whose
  file is gone. Runs at launch restore, on reopen from recently closed, on expand, and on open. A row with
  no path yet (still running, path not reported) is kept until it ends.
- **Lifetime.** Rows die with the parent session. When the parent's agent exits (`SessionEnd`), still-
  `active` rows are marked `completed` so no row claims work that stopped.
- **Hooks (Claude).** New installer entries `SubagentStart`, `SubagentStop`, and `PreToolUse` for activity,
  routed to a `subagent` mode of `agterm-claude-status.sh` that reads the stdin payload. Fields are
  extracted with `plutil -extract <key> raw -o - -` (present on macOS 14; no jq dependency) and passed to
  `agtermctl session subagent …`. Description and transcript path come from the meta file and the derived
  path. The existing state-only hooks are unchanged.
- **Control API.** `session.subagent.start|update|stop|remove|clear|open` with `--target`, `--id`, and
  `--type`, `--description`, `--status`, `--activity`, `--transcript` where relevant.
  Read-back: `ControlSessionNode.subagents`. The setting is read and set by `subagents on|off`,
  read back at tree top level. Events carry their arguments in `EventFormatter.human`.
- **Sidebar.** A session with subagents shows a disclosure triangle; child rows render type/description,
  status glyph and activity. New `SidebarNode.Kind.subagent`, excluded from drag, rename, flag, multi-
  select, attention navigation, palette and dashboard.
  ⚠️ No running/total count on a collapsed parent: the triangle marks children, and the parent's held
  `active` status already says one runs. The truncation row sits FIRST, since evicted rows are the oldest.
- **Open.** Clicking a child row selects the parent and opens the transcript in a program overlay through
  a viewer script in the hook package, so transcript format knowledge stays out of the app.
- **Setting.** `AppSettings.showSubagents: Bool?` (nil = off), toggle in the Agent Status tab.

## Decisions
- A parent with `active` subagents shows `active`, not `completed`, until they end: background subagents
  outlive the parent's turn. A store rule, not a hook rule.
- The transcript viewer is a script (`osascript -l JavaScript` rendering the JSONL for `less -R`), not an
  HTML page.
- Cap of 50 per session, oldest finished dropped first. When rows were dropped, a final non-interactive
  `…` row marks the truncation.
- No list command: `tree --json` is the read-back. Add one only if users ask.

## Implementation Steps

### Task 1: Model and persistence
- [x] `Subagent` value and `Session.subagents` (one stored line), `Session+Subagents.swift` helpers
- [x] `SessionSnapshot.subagents`, capture and restore, recently-closed round trip
- [x] cap rule and transcript pruning with an injectable file-exists check
- [x] tests for each

### Task 2: Store operations and setting
- [x] `AppStore+Subagents.swift`: start, update, stop, remove, clear, end-all-on-agent-exit
- [x] `AppSettings.showSubagents`, gating recording and visibility
- [x] parent stays `active` while any subagent is `active`
- [x] tests

### Task 3: Control API and CLI
- [x] protocol commands, dispatcher validation, `ControlSessionNode.subagents`, top-level setting read-back
- [x] events with human formatting
- [x] `agtermctl session subagent …` and `agtermctl subagents on|off`
- [x] protocol and CLI tests

### Task 4: Claude hook package
- [x] `subagent` mode in `agterm-claude-status.sh` reading the payload via `plutil`
- [x] installer entries and idempotent reinstall, `AgentHooksInstall` tests
- [x] transcript viewer script

### Task 5: Sidebar
- [x] `SidebarNode.Kind.subagent`, child rows, count on collapsed parent, `…` row after truncation
- [x] exclusions: drag, rename, flag, multi-select, attention, palette, dashboard
- [x] click opens transcript overlay over the parent
- [x] hosted/XCUITest coverage, targeted

### Task 6: Settings UI
- [x] Agent Status ▸ Show subagents toggle, hosted test

### Task 7: Docs and skill
- [x] `site/docs.html`, `site/commands.html`, `plugins/agterm/skills/agterm/`, `.claude/rules/control-api.md`
  and `sidebar.md`

### Task 8: Verify
- ➕ `ControlDispatcher.swift` sat at exactly 1000 lines; `dispatchEventsRead` moved unchanged to
  `ControlDispatcher+Events.swift` to make room for the new route.
- ➕ A running row is never pruned: Claude names a subagent's transcript before writing it.
- [x] isolated Debug run with a real subagent, rows appear, finish, survive relaunch, vanish with parent
- [x] `swift test`, `make test-app`, `make lint` once
