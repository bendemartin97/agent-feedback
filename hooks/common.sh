# Shared settings of the hooks (sourced by the other scripts).
# Workspace folder: projects located at <workspaces>/<name>/<checkout> share one feedback folder
# <workspaces>/<name>/feedback. Set via AGENT_FEEDBACK_WORKSPACES or "workspaces" in
# ~/.claude/agent-feedback/config.json; without it, feedback always lives in <project>/.feedback.
AF_HOME="$HOME/.claude/agent-feedback"
AF_WS="${AGENT_FEEDBACK_WORKSPACES-}"
if [ -z "$AF_WS" ] && [ -f "$AF_HOME/config.json" ]; then
  AF_WS=$(jq -r '.workspaces // empty' "$AF_HOME/config.json" 2>/dev/null)
fi
AF_WS="${AF_WS/#\~/$HOME}"
AF_WS="${AF_WS%/}"

# af_in_workspace <dir>: true if <dir> is inside a workspace; sets AF_SLUG.
af_in_workspace() {
  [ -n "$AF_WS" ] || return 1
  case "$1/" in
    "$AF_WS"/?*) AF_SLUG="${1#"$AF_WS"/}"; AF_SLUG="${AF_SLUG%%/*}"; return 0 ;;
  esac
  return 1
}
