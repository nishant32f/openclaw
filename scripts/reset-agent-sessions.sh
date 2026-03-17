#!/usr/bin/env bash
# Reset all agent sessions on the Fly instance.
# Usage: ./scripts/reset-agent-sessions.sh [app-name] [--keep-bootstrap]
#
# This wipes all conversation history. The bot starts fresh.
# By default, also removes BOOTSTRAP.md so the bot skips the intro flow
# (since IDENTITY.md and USER.md are already filled in).
# Pass --keep-bootstrap to keep the first-run intro.

set -euo pipefail

APP="${1:-pawalker-openclaw}"
KEEP_BOOTSTRAP=false

for arg in "$@"; do
  case "$arg" in
    --keep-bootstrap) KEEP_BOOTSTRAP=true ;;
  esac
done

echo "Resetting agent sessions on: $APP"

# Wipe session files and reset session index
fly ssh console -a "$APP" -C "sh -c 'rm -f /data/agents/main/sessions/*.jsonl && echo \"{}\" > /data/agents/main/sessions/sessions.json && chown -R node:node /data/agents/main/sessions/ && echo \"Sessions wiped\"'" 2>&1

# Remove BOOTSTRAP.md unless --keep-bootstrap
if [ "$KEEP_BOOTSTRAP" = false ]; then
  fly ssh console -a "$APP" -C "rm -f /data/workspace/BOOTSTRAP.md" 2>&1
  echo "BOOTSTRAP.md removed (bot skips intro flow)"
else
  echo "BOOTSTRAP.md kept (bot will run first-run intro)"
fi

echo
echo "Done. Next message on Telegram starts a fresh conversation."
