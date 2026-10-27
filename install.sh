#!/bin/bash
# Installs agent-feedback: builds the app (start at login), links hooks and skill.
#   ./install.sh           app + links; prints the hook entries for ~/.claude/settings.json
#   ./install.sh --hooks   also adds the hooks itself (backup: settings.json.bak-agent-feedback)
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME/.claude/agent-feedback"
SETTINGS="$HOME/.claude/settings.json"

for tool in swiftc jq; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool (swiftc: xcode-select --install, jq: brew install jq)" >&2; exit 1; }
done

"$D/build.sh"

mkdir -p "$HOME_DIR/bin" "$HOME/.claude/skills"
for f in common.sh feedback-dir.sh feedback-hint.sh session.sh; do ln -sfn "$D/hooks/$f" "$HOME_DIR/bin/$f"; done
ln -sfn "$D/skills/feedback" "$HOME/.claude/skills/feedback"
[ -f "$HOME_DIR/config.json" ] || echo '{}' > "$HOME_DIR/config.json"
echo "Hooks: $HOME_DIR/bin  ·  Skill: ~/.claude/skills/feedback  ·  Settings: $HOME_DIR/config.json"

BIN='~/.claude/agent-feedback/bin'
HOOKS=$(jq -n --arg b "$BIN" '{
  UserPromptSubmit: [{hooks: [
    {type: "command", command: ($b + "/session.sh update"), timeout: 5},
    {type: "command", command: ($b + "/feedback-hint.sh"), timeout: 5}]}],
  SessionEnd: [{hooks: [{type: "command", command: ($b + "/session.sh end"), timeout: 5}]}]
}')

if [ "${1-}" != "--hooks" ]; then
  echo
  echo "Still to add to $SETTINGS under \"hooks\" (or ./install.sh --hooks):"
  echo "$HOOKS"
  exit 0
fi

if [ -f "$SETTINGS" ] && grep -q 'agent-feedback' "$SETTINGS"; then
  echo "Hooks are already set up."
  exit 0
fi
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-agent-feedback"
MERGED=$(jq --argjson add "$HOOKS" '
  .hooks //= {} |
  reduce ($add | keys[]) as $event (.; .hooks[$event] = ((.hooks[$event] // []) + $add[$event]))' "$SETTINGS")
# Write into the existing file so a symlink (e.g. into a dotfiles repo) is preserved.
printf '%s\n' "$MERGED" > "$SETTINGS"
echo "Hooks added (backup: $SETTINGS.bak-agent-feedback). New Claude Code sessions will register from now on."
