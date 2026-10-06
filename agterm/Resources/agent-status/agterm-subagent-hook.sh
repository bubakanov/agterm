#!/usr/bin/env bash
# agterm-subagent-hook.sh AGENT MODE — report an agent's subagents as rows under its agterm session, from the
# hook payload on stdin. Claude Code and Codex send the same subagent payloads (agent_id, agent_type,
# session_id, transcript_path, agent_transcript_path) for SubagentStart/SubagentStop and a subagent's own tool
# calls; AGENT (claude|codex) only decides where a subagent's transcript and description live. The agent's
# own adapter runs first and pipes the payload here.
#
# Modes: start, stop, activity (a subagent's tool call), finish (the agent's turn ended), end (the agent exited),
# conversation (a new or resumed conversation; Claude also imports that conversation's earlier subagents).
# Never fails a hook.
set -u
[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0

kind=${1:-}
mode=${2:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${AGTERM_STATUS_WRAPPER:-"$script_dir/agterm-agent-status.sh"}
payload=$(cat)
# plutil reads JSON on every supported macOS, where jq is not guaranteed
field() { plutil -extract "$1" raw -o - - <<<"$payload" 2>/dev/null; }
agent=$(field agent_id)
case "$mode" in finish | end | conversation) ;; *) [ -n "$agent" ] || exit 0 ;; esac

# the subagent's own transcript file, or nothing when this payload does not name it
transcript_path() {
  local reported parent session
  reported=$(field agent_transcript_path)
  [ -n "$reported" ] && { printf '%s' "$reported"; return; }
  case "$kind" in
    claude)
      parent=$(field transcript_path)
      session=$(field session_id)
      [ -n "$parent" ] && [ -n "$session" ] && printf '%s' "${parent%/*}/$session/subagents/agent-$agent.jsonl"
      ;;
    # Codex names the subagent's own rollout at start; later events name the parent's
    codex) [ "$mode" = start ] && field transcript_path ;;
  esac
}

# what the subagent was asked to do; Claude writes it beside the transcript, often just after the start
description_of() {
  local transcript=$1 task nickname
  [ -n "$transcript" ] || return 0
  case "$kind" in
    claude) plutil -extract description raw -o - "${transcript%.jsonl}.meta.json" 2>/dev/null ;;
    codex)
      # a Codex subagent's rollout opens with its task path (/root/swift_files) and a nickname
      task=$(head -n 1 "$transcript" 2>/dev/null | plutil -extract payload.agent_path raw -o - - 2>/dev/null)
      nickname=$(head -n 1 "$transcript" 2>/dev/null | plutil -extract payload.agent_nickname raw -o - - 2>/dev/null)
      [ -n "$task" ] && printf '%s%s' "${task##*/}" "${nickname:+ ($nickname)}"
      ;;
  esac
}

case "$mode" in
  start | stop | activity)
    transcript=$(transcript_path)
    flags=()
    description=$(description_of "$transcript")
    [ -n "$description" ] && flags+=(--description "$description")
    if [ "$mode" = activity ]; then
      tool=$(field tool_name)
      detail=$(field tool_input.command || field tool_input.cmd || field tool_input.file_path || field tool_input.pattern \
        || field tool_input.description)
      exec "$status_wrapper" subagent update "$agent" --status active --activity "${tool}${detail:+: $detail}" \
        ${flags[@]+"${flags[@]}"}
    fi
    agent_type=$(field agent_type)
    [ -n "$agent_type" ] && flags+=(--type "$agent_type")
    [ -n "$transcript" ] && flags+=(--transcript "$transcript")
    if [ "$mode" = start ]; then
      conversation=$(field session_id)
      [ -n "$conversation" ] && flags+=(--conversation "$conversation")
    fi
    exec "$status_wrapper" subagent "$mode" "$agent" ${flags[@]+"${flags[@]}"}
    ;;
  finish)
    exec "$status_wrapper" subagent finish
    ;;
  end)
    # named, so a session that ends late (Codex's blank start session after /resume) cannot hide the current one
    conversation=$(field session_id)
    exec "$status_wrapper" subagent end ${conversation:+"$conversation"}
    ;;
  conversation)
    # a new, cleared or resumed conversation decides which rows the session shows
    conversation=$(field session_id)
    [ -n "$conversation" ] || exit 0
    "$status_wrapper" subagent conversation "$conversation"
    [ "$kind" = claude ] || exit 0
    # a resumed conversation's earlier subagents ran before this agterm could hear them; their meta files
    # are the record, so report each as finished. Re-reporting a known row only refreshes it. Detached, so
    # a long history never delays the session's start.
    parent=$(field transcript_path)
    folder="${parent%.jsonl}/subagents"
    [ -n "$parent" ] && [ -d "$folder" ] || exit 0
    import_subagents() {
      for meta in "$folder"/agent-*.meta.json; do
        [ -f "$meta" ] || continue
        id=${meta##*/agent-}
        id=${id%.meta.json}
        flags=(--status completed --conversation "$conversation" --transcript "${meta%.meta.json}.jsonl")
        description=$(plutil -extract description raw -o - "$meta" 2>/dev/null)
        [ -n "$description" ] && flags+=(--description "$description")
        agent_type=$(plutil -extract agentType raw -o - "$meta" 2>/dev/null)
        [ -n "$agent_type" ] && flags+=(--type "$agent_type")
        "$status_wrapper" subagent start "$id" "${flags[@]}"
      done
    }
    # tests set AGTERM_HOOK_FOREGROUND to read the calls once the hook exits
    if [ -n "${AGTERM_HOOK_FOREGROUND:-}" ]; then
      import_subagents
    else
      import_subagents </dev/null >/dev/null 2>&1 &
    fi
    ;;
esac
exit 0
