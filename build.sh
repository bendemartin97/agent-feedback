#!/bin/bash
# Builds ~/Applications/AgentFeedback.app and registers the LaunchAgent (start at login).
# Custom bundle ID: AGENT_FEEDBACK_BUNDLE_ID=com.example.agentfeedback ./build.sh
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/AgentFeedback.app"
LABEL="${AGENT_FEEDBACK_BUNDLE_ID:-com.martinbende.agentfeedback}"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

"$D/scripts/make-app.sh" "$APP" "$LABEL"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AgentFeedback</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "running: $APP"
