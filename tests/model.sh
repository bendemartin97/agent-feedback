#!/bin/bash
# Builds the app sources without main.swift together with tests/model.swift and runs the checks.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/src"
for f in "$D"/app/*.swift; do [ "$(basename "$f")" = main.swift ] || cp "$f" "$OUT/src/"; done
cp "$D/tests/model.swift" "$OUT/src/main.swift"
swiftc -swift-version 5 "$OUT"/src/*.swift -o "$OUT/model"
"$OUT/model"
