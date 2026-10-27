#!/bin/bash
# UserPromptSubmit hook: tells the agent about the open feedback items assigned to it
# (app agent-feedback, skill feedback). An item is an .md; its images are listed under `images:`
# (older items: `bilder:`). Items without session_id apply to every session in the folder; items with an
# open question are left out (the user answers those).
INPUT=$(cat)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
source "$(dirname "$0")/common.sh"
af_in_workspace "$CWD" || CWD="${CLAUDE_PROJECT_DIR:-$CWD}"
[ -n "$CWD" ] || exit 0
DIR=$("$(dirname "$0")/feedback-dir.sh" "$CWD")
LINES=()
for md in "$DIR"/inbox/*.md; do
  [ -f "$md" ] || continue
  OWNER=$(sed -n 's/^session_id: //p' "$md" | head -1)
  [ -z "$OWNER" ] || [ "$OWNER" = "$SID" ] || continue
  # Questions wait for the user, not for the agent.
  grep '^\*\*Status:\*\*' "$md" | tail -1 | grep -qiE 'question|frage' && continue
  if grep -qE '^(images|bilder):' "$md"; then
    IMAGES=$(sed -nE 's/^(images|bilder): *//p' "$md" | head -1)
    LINES+=("$md (images: ${IMAGES:-none, text only})")
  else
    LINES+=("$md (images: $(basename "${md%.md}.png"))")
  fi
done
[ ${#LINES[@]} -gt 0 ] || exit 0
echo "📸 ${#LINES[@]} open feedback items for this session (skill feedback, trigger \"work through feedback\"):"
printf '  %s\n' "${LINES[@]}"
exit 0
