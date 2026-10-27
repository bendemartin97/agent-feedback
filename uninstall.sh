#!/bin/bash
# Removes the app, LaunchAgent and links. Feedback folders, settings and hook entries in
# ~/.claude/settings.json remain; please delete the entries containing "agent-feedback" yourself.
set -uo pipefail
LABEL="${AGENT_FEEDBACK_BUNDLE_ID:-com.martinbende.agentfeedback}"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/AgentFeedback.app"
rm -f "$HOME/.claude/skills/feedback"
rm -rf "$HOME/.claude/agent-feedback/bin"
echo "Removed. Left behind: ~/.claude/agent-feedback (sessions, settings) and the feedback folders in your projects."
