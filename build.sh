#!/bin/bash
# Builds ~/Applications/AgentFeedback.app and registers the LaunchAgent (start at login).
# Custom bundle ID: AGENT_FEEDBACK_BUNDLE_ID=com.example.agentfeedback ./build.sh
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/AgentFeedback.app"
LABEL="${AGENT_FEEDBACK_BUNDLE_ID:-com.martinbende.agentfeedback}"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 "$D"/app/*.swift -o "$APP/Contents/MacOS/AgentFeedback"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Agent Feedback</string>
  <key>CFBundleExecutable</key><string>AgentFeedback</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the URL of the active Chrome tab for the feedback screenshot.</string>
</dict></plist>
PLIST
# Sign with the Apple Development certificate: ad-hoc signatures change on every build, and macOS then
# forgets the permissions (Screen Recording, Automation). Without a certificate it stays ad-hoc.
SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null 2>&1 || true

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
