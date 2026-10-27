#!/bin/bash
# Regenerates the README screenshots in docs/ from demo data (no real feedback is touched).
# Needs Screen Recording permission for the terminal you run it from; windows flash up briefly.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 "$D"/app/*.swift -o "$OUT/AgentFeedback"
"$OUT/AgentFeedback" --screenshots "$D/docs"
