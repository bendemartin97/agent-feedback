#!/bin/bash
# Installs agent-feedback from this checkout: builds the app (start at login), links hooks and skill.
#   ./install.sh           app + links; prints the hook entries for ~/.claude/settings.json
#   ./install.sh --hooks   also adds the hooks itself (backup: settings.json.bak-agent-feedback)
#   ./install.sh --codex   also sets up Codex (skill in ~/.agents/skills, hooks in ~/.codex/hooks.json)
# With Homebrew: brew install bendemartin97/tap/agent-feedback, then `agent-feedback setup`.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for tool in swiftc jq; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool (swiftc: xcode-select --install, jq: brew install jq)" >&2; exit 1; }
done

"$D/build.sh"
"$D/bin/agent-feedback" setup "$@"
