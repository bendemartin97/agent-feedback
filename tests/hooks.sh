#!/bin/bash
# Tests the hooks against a throwaway HOME: ./tests/hooks.sh
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T"
unset CLAUDE_PROJECT_DIR AGENT_FEEDBACK_RUN AGENT_FEEDBACK_WORKSPACES
FAIL=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $2"; echo "     actual:   $3"; FAIL=1; fi
}

mkdir -p "$T/.claude/agent-feedback"
echo '{"workspaces": "~/work"}' > "$T/.claude/agent-feedback/config.json"
WS="$T/work/demo"
mkdir -p "$WS/app" "$T/proj/sub"

# feedback-dir.sh
check "dir: workspace root" "$WS/feedback" "$("$D/hooks/feedback-dir.sh" "$WS")"
check "dir: worktree inside workspace" "$WS/feedback" "$("$D/hooks/feedback-dir.sh" "$WS/app")"
check "dir: project outside" "$T/proj/.feedback" "$("$D/hooks/feedback-dir.sh" "$T/proj")"
check "dir: without workspace config" "$WS/app/.feedback" "$(AGENT_FEEDBACK_WORKSPACES=/nowhere "$D/hooks/feedback-dir.sh" "$WS/app")"

# session.sh
S="$T/.claude/agent-feedback/sessions"
echo "{\"session_id\":\"s1\",\"cwd\":\"$WS/app\"}" | CLAUDE_PROJECT_DIR="$T/Development" "$D/hooks/session.sh" update
check "session: root inside workspace" "$WS/app" "$(jq -r .root "$S/s1.json")"
check "session: start = project dir" "$T/Development" "$(jq -r .start "$S/s1.json")"
check "session: project = workspace slug" "demo" "$(jq -r .project "$S/s1.json")"
echo "{\"session_id\":\"s2\",\"cwd\":\"$T/proj/sub\"}" | CLAUDE_PROJECT_DIR="$T/proj" "$D/hooks/session.sh" update
check "session: root outside = project dir" "$T/proj" "$(jq -r .root "$S/s2.json")"
echo "{\"session_id\":\"s2\",\"cwd\":\"$T/proj\",\"prompt\":\"Make the\\nbutton blue\"}" | CLAUDE_PROJECT_DIR="$T/proj" "$D/hooks/session.sh" update
check "session: last prompt on one line" "Make the button blue" "$(jq -r .prompt "$S/s2.json")"
echo "{\"session_id\":\"s2\",\"cwd\":\"$T/proj\"}" | CLAUDE_PROJECT_DIR="$T/proj" "$D/hooks/session.sh" update
check "session: prompt kept without a new one" "Make the button blue" "$(jq -r .prompt "$S/s2.json")"
check "session: agent defaults to claude" "claude" "$(jq -r .agent "$S/s2.json")"
echo "{\"session_id\":\"c1\",\"cwd\":\"$T/proj\",\"prompt\":\"hi\"}" | "$D/hooks/session.sh" update codex
check "session: codex agent" "codex" "$(jq -r .agent "$S/c1.json")"
check "session: codex start = cwd" "$T/proj" "$(jq -r .start "$S/c1.json")"
check "session: no pid without one" "null" "$(jq -r .pid "$S/c1.json")"
echo "{\"session_id\":\"p1\",\"cwd\":\"$T/proj\",\"prompt\":\"hi\",\"title\":\"Fix header\",\"pid\":\"4242\"}" | "$D/hooks/session.sh" update pi
check "session: pi agent" "pi" "$(jq -r .agent "$S/p1.json")"
check "session: title from payload" "Fix header" "$(jq -r .title "$S/p1.json")"
check "session: pid from payload" "4242" "$(jq -r .pid "$S/p1.json")"
echo '{"session_id":"s3","cwd":"/tmp"}' | AGENT_FEEDBACK_RUN=1 "$D/hooks/session.sh" update
check "session: own runs not reported" "no" "$([ -f "$S/s3.json" ] && echo yes || echo no)"
echo '{"session_id":"s1"}' | "$D/hooks/session.sh" end
check "session: end deletes" "no" "$([ -f "$S/s1.json" ] && echo yes || echo no)"

# feedback-hint.sh
IN="$WS/feedback/inbox"
mkdir -p "$IN"
printf -- '---\nsession_id: s1\nimages: a.png, a-2.png\n---\nNote\n' > "$IN/a.md"
printf -- '---\nsession_id: other\n---\n' > "$IN/b.md"
printf -- '---\n---\nunassigned\n' > "$IN/c.md"
printf -- '---\nsession_id: s1\nimages:\n---\nText only\n' > "$IN/d.md"
printf -- '---\nsession_id: s1\nimages: e.png\n---\nx\n\n## Result\n**Status:** open (question)\n' > "$IN/e.md"
# Legacy German items: bilder:, an open question as "offen (Frage)", an empty bilder: for text only.
printf -- '---\nsession_id: s1\nbilder: f.png, f-2.png\n---\nNotiz\n' > "$IN/f.md"
printf -- '---\nsession_id: s1\nbilder: g.png\n---\nx\n\n## Ergebnis\n**Status:** offen (Frage)\n' > "$IN/g.md"
printf -- '---\nsession_id: s1\nbilder:\n---\nNur Text\n' > "$IN/h.md"
OUT=$(echo "{\"session_id\":\"s1\",\"cwd\":\"$WS/app\"}" | "$D/hooks/feedback-hint.sh")
check "hint: counts own + unassigned" "📸 5 open feedback items for this session (skill feedback, trigger \"work through feedback\"):" "$(head -1 <<<"$OUT")"
check "hint: lists images from images:" "1" "$(grep -c "a.md (images: a.png, a-2.png)" <<<"$OUT")"
check "hint: old format without images:" "1" "$(grep -c "c.md (images: c.png)" <<<"$OUT")"
check "hint: text-only task" "1" "$(grep -c "d.md (images: none, text only)" <<<"$OUT")"
check "hint: question left out" "0" "$(grep -c "e.md" <<<"$OUT")"
check "hint: other session left out" "0" "$(grep -c "b.md" <<<"$OUT")"
check "hint: legacy bilder: listed" "1" "$(grep -c "f.md (images: f.png, f-2.png)" <<<"$OUT")"
check "hint: legacy question (Frage) left out" "0" "$(grep -cF "/g.md" <<<"$OUT")"
check "hint: legacy empty bilder: = text only" "1" "$(grep -c "h.md (images: none, text only)" <<<"$OUT")"
check "hint: empty without items" "" "$(echo "{\"session_id\":\"x\",\"cwd\":\"$T/proj\"}" | "$D/hooks/feedback-hint.sh")"

exit $FAIL
