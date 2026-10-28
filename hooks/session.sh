#!/bin/bash
# Claude Code / Codex hook (pi: called by hooks/pi-extension.ts): reports running sessions to agent-feedback, so the app offers them for selection.
# Usage: session.sh update|end [claude|codex|pi] (UserPromptSubmit / SessionEnd), hook payload as JSON on stdin.
# Writes ~/.claude/agent-feedback/sessions/<session_id>.json with id, agent, root, start, project, title, prompt
# (plus pid if the payload has one: the pi extension sends it so the app can tell whether the session still runs).
# root = base for the feedback folder, start = start directory (where the session can be resumed with --resume).
# Runs started by agent-feedback (AGENT_FEEDBACK_RUN=1) do not show up in the picker.
[ -n "${AGENT_FEEDBACK_RUN-}" ] && exit 0
source "$(dirname "$0")/common.sh"
DIR="$AF_HOME/sessions"
INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$SID" ] || exit 0
if [ "${1:-update}" = end ]; then rm -f "$DIR/$SID.json"; exit 0; fi

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
CWD="${CWD:-$PWD}"
# Base for the feedback folder: the current cwd inside a workspace, otherwise the session's start directory.
if af_in_workspace "$CWD"; then
  ROOT="$CWD"; PROJECT="$AF_SLUG"
else
  ROOT="${CLAUDE_PROJECT_DIR:-$CWD}"; PROJECT="$(basename "$ROOT")"
fi
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
TITLE=""
[ -f "$TRANSCRIPT" ] && TITLE=$(grep -a '"type":"\(custom-title\|ai-title\)"' -- "$TRANSCRIPT" | tail -1 | jq -r '.customTitle // .aiTitle // empty' 2>/dev/null)
[ -z "$TITLE" ] && TITLE=$(jq -r '.title // empty' <<<"$INPUT" 2>/dev/null)
PID=$(jq -r '.pid // empty' <<<"$INPUT" 2>/dev/null)

# Last prompt as a recognizable hint in the picker (single line, shortened); without a prompt keep the previous one.
PROMPT=$(jq -r '.prompt // empty' <<<"$INPUT" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-90 | sed 's/ *$//')
[ -z "$PROMPT" ] && [ -f "$DIR/$SID.json" ] && PROMPT=$(jq -r '.prompt // empty' "$DIR/$SID.json" 2>/dev/null)

mkdir -p "$DIR"
jq -cn --arg id "$SID" --arg agent "${2:-claude}" --arg root "$ROOT" --arg start "${CLAUDE_PROJECT_DIR:-$CWD}" --arg project "$PROJECT" --arg title "$TITLE" --arg prompt "$PROMPT" --arg pid "$PID" \
  '{id: $id, agent: $agent, root: $root, start: $start, project: $project, title: $title, prompt: $prompt}
   + (if $pid == "" then {} else {pid: $pid} end)' > "$DIR/$SID.json"
exit 0
