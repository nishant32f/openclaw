#!/usr/bin/env bash
# Sync local workspace files to the Fly.io instance.
# Usage: ./scripts/sync-workspace-to-fly.sh [app-name]
#
# Workspace is stored on the persistent volume at /data/workspace/
# (configured via agents.defaults.workspace in openclaw.json).
# Uses a single tar pipe to minimize SSH round-trips.

set -euo pipefail

APP="${1:-pawalker-openclaw}"
LOCAL_DIR="$(cd "$(dirname "$0")/../workspace" && pwd)"
REMOTE_DIR="/data/workspace"

if [ ! -d "$LOCAL_DIR" ]; then
  echo "Error: workspace/ directory not found at $LOCAL_DIR"
  exit 1
fi

echo "Syncing workspace to fly app: $APP"
echo "  Local:  $LOCAL_DIR"
echo "  Remote: $REMOTE_DIR (persistent volume)"
echo

# Build file list (portable — works on macOS BSD find + tar)
FILE_LIST=$(cd "$LOCAL_DIR" && find . -type f \( -name '*.md' -o -name '*.json' -o -name '*.sh' \))

if [ -z "$FILE_LIST" ]; then
  echo "No files to sync."
  exit 0
fi

# Show what's being synced
echo "$FILE_LIST" | sed 's|^\./|  → |'

# Single tar pipe: pack locally → extract on remote → fix ownership
# Replaces N individual SSH calls with one.
echo
echo "Pushing..."
# COPYFILE_DISABLE=1 prevents macOS ._* resource fork files in the tar archive
echo "$FILE_LIST" | COPYFILE_DISABLE=1 tar -cf - -C "$LOCAL_DIR" -T - 2>/dev/null \
  | fly ssh console -a "$APP" -C "sh -c 'mkdir -p $REMOTE_DIR && tar -xf - -C $REMOTE_DIR 2>/dev/null && chown -R node:node $REMOTE_DIR'"

echo "Done! Workspace is on persistent volume — survives deploys."
