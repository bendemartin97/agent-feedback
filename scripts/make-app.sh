#!/bin/bash
# Builds the app bundle: scripts/make-app.sh <path/AgentFeedback.app> [bundle id]
# Used by build.sh and the Homebrew formula.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
LABEL="${2:-com.martinbende.agentfeedback}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$D/assets/AppIcon.icns" "$D/assets/menubar.png" "$D/assets/menubar@2x.png" "$APP/Contents/Resources/"
swiftc -O -swift-version 5 "$D"/app/*.swift -o "$APP/Contents/MacOS/AgentFeedback"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Agent Feedback</string>
  <key>CFBundleExecutable</key><string>AgentFeedback</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the URL of the active Chrome tab for the feedback screenshot.</string>
</dict></plist>
PLIST
# Sign with the Apple Development certificate: ad-hoc signatures change on every build, and macOS then
# forgets the permissions (Screen Recording, Automation). Without a certificate it stays ad-hoc.
SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }' || true)
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null 2>&1 || true
