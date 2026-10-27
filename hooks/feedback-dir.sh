#!/bin/bash
# Feedback folder for a directory (default: $PWD): <workspaces>/<name>/feedback inside a workspace, otherwise <dir>/.feedback.
# Same rule as feedbackDir() in app/Model.swift.
source "$(dirname "$0")/common.sh"
D="${1:-$PWD}"
if af_in_workspace "$D"; then echo "$AF_WS/$AF_SLUG/feedback"; else echo "$D/.feedback"; fi
