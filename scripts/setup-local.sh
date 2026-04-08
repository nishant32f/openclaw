#!/usr/bin/env bash
# Local setup for OpenClaw gateway on macOS.
# Usage: ./scripts/setup-local.sh
#
# This script is idempotent — safe to re-run.
# It handles: dependency checks, local config generation, env loading,
# workspace symlink, bird auth, cron setup, and gateway start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$REPO_DIR/workspace"
LOCAL_CONFIG="$REPO_DIR/openclaw.local.json"
REMOTE_CONFIG="$REPO_DIR/openclaw.json"
ENV_FILE="$REPO_DIR/.env"
DIGEST_REPO="nishant32f/digest"
GW_URL="ws://127.0.0.1:18789"
GW_PORT=18789
DIGEST_MODEL="openrouter/deepseek/deepseek-chat"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "\n${GREEN}==> $*${NC}"; }

# ─── Preflight checks ───────────────────────────────────────────────

step "Preflight checks"

command -v openclaw >/dev/null 2>&1 || fail "openclaw CLI not found. Install: npm i -g openclaw"
command -v gh       >/dev/null 2>&1 || fail "gh CLI not found. Install: https://cli.github.com/"
command -v bird     >/dev/null 2>&1 || warn "bird CLI not found — digest X fetching won't work. Install: npm i -g @steipete/bird"
command -v jq       >/dev/null 2>&1 || fail "jq not found. Install: brew install jq"

info "CLI tools available"

[ -d "$WORKSPACE_DIR" ] || fail "workspace/ directory not found at $WORKSPACE_DIR"
info "Local workspace found"

[ -f "$ENV_FILE" ] || fail ".env not found at $ENV_FILE"
info ".env found"

gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"
info "GitHub CLI authenticated"

# ─── Load env vars ──────────────────────────────────────────────────

step "Loading environment"

set -a
source "$ENV_FILE"
set +a
info "Environment loaded from .env"

# ─── Generate local config ──────────────────────────────────────────

step "Generating local config"

cat > "$LOCAL_CONFIG" <<CONF
{
  "env": {
    "shellEnv": {
      "enabled": true
    }
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true,
    "ownerDisplay": "raw"
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE_DIR",
      "model": {
        "primary": "anthropic/claude-haiku-4-5",
        "fallbacks": [
          "openrouter/deepseek/deepseek-chat",
          "openrouter/meta-llama/llama-3.3-70b-instruct:free"
        ]
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "\${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": ["\${TELEGRAM_OWNER_ID}"],
      "groups": { "*": { "requireMention": true } }
    }
  },
  "gateway": {
    "mode": "local"
  }
}
CONF

info "Config written to openclaw.local.json"

# ─── Verify bird auth ──────────────────────────────────────────────

step "Verifying bird for X/Twitter"

if command -v bird >/dev/null 2>&1; then
  if bird whoami --plain 2>/dev/null; then
    echo "bird: authenticated"
  else
    warn "bird: not authenticated — set AUTH_TOKEN and CT0 in .env"
  fi
else
  warn "bird not installed — skipping"
fi

# ─── Kill existing gateway ──────────────────────────────────────────

step "Stopping existing gateway (if any)"

if lsof -ti :$GW_PORT >/dev/null 2>&1; then
  kill $(lsof -ti :$GW_PORT) 2>/dev/null || true
  sleep 2
  info "Stopped old gateway on port $GW_PORT"
else
  info "No existing gateway on port $GW_PORT"
fi

# ─── Start gateway ──────────────────────────────────────────────────

step "Starting gateway"

LOG_FILE="/tmp/openclaw-gateway-local.log"

OPENCLAW_CONFIG="$LOCAL_CONFIG" nohup openclaw gateway run \
  --bind loopback --port $GW_PORT --force \
  > "$LOG_FILE" 2>&1 &

GW_PID=$!
info "Gateway starting (pid: $GW_PID, log: $LOG_FILE)"

# Wait for gateway to boot
echo -n "  Waiting for gateway..."
for i in $(seq 1 30); do
  if lsof -ti :$GW_PORT >/dev/null 2>&1; then
    echo ""
    info "Gateway is up on port $GW_PORT"
    break
  fi
  echo -n "."
  sleep 1
done

if ! lsof -ti :$GW_PORT >/dev/null 2>&1; then
  echo ""
  warn "Gateway may still be booting. Check: tail -f $LOG_FILE"
fi

# ─── Setup cron jobs ────────────────────────────────────────────────

step "Setting up cron jobs"

MORNING_MSG='Run this exact command using the exec tool: '"$SCRIPT_DIR"'/generate-digest.sh morning — Do not do anything else. Just run that one command.'
EVENING_MSG='Run this exact command using the exec tool: '"$SCRIPT_DIR"'/generate-digest.sh evening — Do not do anything else. Just run that one command.'

GW_ARGS="--url $GW_URL --token $OPENCLAW_GATEWAY_TOKEN"

# Remove existing digest crons to avoid duplicates
for name in digest-morning digest-evening; do
  ID=$(openclaw cron list $GW_ARGS --json 2>/dev/null | jq -r ".jobs[] | select(.name==\"$name\") | .id" 2>/dev/null || true)
  if [ -n "$ID" ]; then
    openclaw cron rm "$ID" $GW_ARGS 2>/dev/null && echo "  Removed old $name"
  fi
done

openclaw cron add $GW_ARGS --cron "30 3 * * *" --tz Asia/Kolkata --name digest-morning --timeout-seconds 180 --no-deliver --model "$DIGEST_MODEL" --message "$MORNING_MSG" 2>/dev/null || warn "Morning cron failed"
openclaw cron add $GW_ARGS --cron "30 15 * * *" --tz Asia/Kolkata --name digest-evening --timeout-seconds 180 --no-deliver --model "$DIGEST_MODEL" --message "$EVENING_MSG" 2>/dev/null || warn "Evening cron failed"

echo "---CRON LIST---"
openclaw cron list $GW_ARGS 2>/dev/null || warn "Could not list cron jobs"

info "Cron jobs configured"

# ─── Summary ─────────────────────────────────────────────────────────

step "Local setup complete!"
echo
echo "  Gateway:     ws://127.0.0.1:$GW_PORT (pid: $GW_PID)"
echo "  Config:      $LOCAL_CONFIG"
echo "  Workspace:   $WORKSPACE_DIR"
echo "  Logs:        tail -f $LOG_FILE"
echo "  Model:       anthropic/claude-haiku-4-5 (direct, no OpenRouter)"
echo
echo "  Digest:      https://nishant32f.github.io/digest"
echo "  Digest repo: https://github.com/$DIGEST_REPO"
echo
echo "  Cron jobs:"
echo "    Morning digest: 9:00 AM IST (03:30 UTC)"
echo "    Evening digest: 9:00 PM IST (15:30 UTC)"
echo
echo "  Stop: kill $GW_PID"
echo
