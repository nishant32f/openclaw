#!/usr/bin/env bash
# Full reproducible setup for an OpenClaw Fly.io instance.
# Usage: ./scripts/setup-fly-instance.sh [app-name]
#
# This script is idempotent — safe to re-run.
# It handles: dependency checks, config push, workspace sync, bird auth,
# cron setup, GitHub Pages repo setup, and gateway restart.

set -euo pipefail

APP="${1:-pawalker-openclaw}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$REPO_DIR/workspace"
REMOTE_WORKSPACE="/data/workspace"
DIGEST_REPO="nishant32f/digest"
GW_URL="ws://127.0.0.1:3000"

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

command -v fly  >/dev/null 2>&1 || fail "fly CLI not found. Install: https://fly.io/docs/flyctl/install/"
command -v gh   >/dev/null 2>&1 || fail "gh CLI not found. Install: https://cli.github.com/"

fly status -a "$APP" >/dev/null 2>&1 || fail "Cannot reach fly app: $APP"
info "Fly app '$APP' is reachable"

gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"
info "GitHub CLI authenticated"

[ -d "$WORKSPACE_DIR" ] || fail "workspace/ directory not found at $WORKSPACE_DIR"
info "Local workspace found"

# ─── Check & install remote dependencies ─────────────────────────────

step "Checking remote dependencies"

DEP_STATUS=$(fly ssh console -a "$APP" -C "sh -c 'for cmd in gh git openclaw bird; do which \$cmd >/dev/null 2>&1 && echo \"OK:\$cmd\" || echo \"MISSING:\$cmd\"; done'" 2>/dev/null || echo "MISSING:gh")

echo "$DEP_STATUS" | while IFS=: read -r status cmd; do
  if [ "$status" = "OK" ]; then
    info "$cmd available on remote"
  else
    warn "$cmd NOT found on remote"
  fi
done

# gh and bird are baked into the Docker image. If missing, redeploy.
if echo "$DEP_STATUS" | grep -q "MISSING:gh\|MISSING:bird"; then
  warn "gh or bird missing on remote — run 'fly deploy' to rebuild the Docker image"
fi

# ─── Push config ─────────────────────────────────────────────────────

step "Pushing openclaw.json config"

if [ -f "$REPO_DIR/openclaw.json" ]; then
  fly ssh console -a "$APP" -C "sh -c 'cat > /data/openclaw.json && chown node:node /data/openclaw.json'" < "$REPO_DIR/openclaw.json"
  info "Config pushed"
else
  warn "No openclaw.json found at repo root — skipping config push"
fi

# ─── Sync secrets (--stage to defer restart) ─────────────────────────

step "Syncing secrets"

if [ -f "$REPO_DIR/.env" ]; then
  fly secrets import -a "$APP" --stage < "$REPO_DIR/.env" 2>/dev/null \
    || fly secrets import -a "$APP" < "$REPO_DIR/.env"
  info "Secrets synced"
else
  warn "No .env found — skipping secrets sync"
fi

# ─── Sync workspace ─────────────────────────────────────────────────

step "Syncing workspace files"

"$SCRIPT_DIR/sync-workspace-to-fly.sh" "$APP"
info "Workspace synced"

# ─── Setup GitHub Pages ─────────────────────────────────────────────

step "Configuring GitHub Pages on $DIGEST_REPO"

PAGES_STATUS=$(gh api "repos/$DIGEST_REPO/pages" 2>&1 || echo "NOT_ENABLED")
if echo "$PAGES_STATUS" | grep -q "NOT_ENABLED\|Not Found"; then
  gh api "repos/$DIGEST_REPO/pages" \
    --method POST \
    -f "source[branch]=main" \
    -f "source[path]=/" 2>/dev/null || \
    warn "Could not auto-enable GitHub Pages. Enable manually: repo Settings → Pages → Source: main branch"
  info "GitHub Pages enabled"
else
  info "GitHub Pages already configured"
fi

# ─── Restart gateway (deploys staged secrets) ───────────────────────

step "Restarting gateway to pick up all changes"

MACHINE_ID=$(fly machines list -a "$APP" --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)
if [ -n "$MACHINE_ID" ]; then
  fly machines restart "$MACHINE_ID" -a "$APP" 2>&1 || warn "Could not restart machine $MACHINE_ID"
  info "Gateway restarting (machine $MACHINE_ID)"
else
  warn "Could not determine machine ID. Restart manually."
fi

# ─── Wait for gateway to boot ───────────────────────────────────────

step "Waiting for gateway to boot..."
sleep 25

# ─── Setup bird auth (after restart so secrets are live) ─────────────

step "Verifying bird for X/Twitter"

# bird reads AUTH_TOKEN and CT0 env vars directly (set via Fly secrets).
# No config file needed — env vars are the cleanest path on headless servers.
fly ssh console -a "$APP" -C "sh -c 'bird whoami --plain 2>/dev/null && echo \"bird: authenticated\" || echo \"bird: not authenticated — set AUTH_TOKEN and CT0 in .env\"'" 2>&1

# ─── Setup cron jobs (deduplicate first) ─────────────────────────────

step "Setting up cron jobs"

MORNING_MSG='Read the digest skill (workspace skills/digest/SKILL.md). Run a morning digest: search X/Twitter for AI posts from the last 12 hours using the topics and people in digest.config.json. Create a digest post and push it to the nishant32f/digest GitHub repo. Then send me a short summary of the digest on Telegram.'
EVENING_MSG='Read the digest skill (workspace skills/digest/SKILL.md). Run an evening digest: search X/Twitter for AI posts from the last 12 hours using the topics and people in digest.config.json. Create a digest post and push it to the nishant32f/digest GitHub repo. Then send me a short summary of the digest on Telegram.'

# Push a cron setup script to avoid nested quoting issues
CRON_SETUP=$(mktemp)
cat > "$CRON_SETUP" <<CRONSCRIPT
#!/bin/sh
GW="--url $GW_URL --token \$OPENCLAW_GATEWAY_TOKEN"
# Remove existing digest crons to avoid duplicates
for name in digest-morning digest-evening; do
  ID=\$(openclaw cron list \$GW --json 2>/dev/null | jq -r ".jobs[] | select(.name==\"\$name\") | .id" 2>/dev/null)
  if [ -n "\$ID" ]; then
    openclaw cron rm "\$ID" \$GW 2>/dev/null && echo "Removed old \$name"
  fi
done
openclaw cron add \$GW --cron "30 3 * * *" --tz Asia/Kolkata --name digest-morning --timeout-seconds 120 --channel telegram --message "$MORNING_MSG" 2>/dev/null || echo "Morning cron failed"
openclaw cron add \$GW --cron "30 15 * * *" --tz Asia/Kolkata --name digest-evening --timeout-seconds 120 --channel telegram --message "$EVENING_MSG" 2>/dev/null || echo "Evening cron failed"
echo "---CRON LIST---"
openclaw cron list \$GW 2>/dev/null || echo "Could not list cron jobs"
CRONSCRIPT

fly ssh console -a "$APP" -C "sh -c 'cat > /tmp/cron-setup.sh && chmod +x /tmp/cron-setup.sh && /tmp/cron-setup.sh && rm -f /tmp/cron-setup.sh'" < "$CRON_SETUP" 2>&1 || warn "Cron setup failed — gateway may still be booting."
rm -f "$CRON_SETUP"

info "Cron jobs configured"

# ─── Summary ─────────────────────────────────────────────────────────

step "Setup complete!"
echo
echo "  App:         $APP"
echo "  Workspace:   $REMOTE_WORKSPACE"
echo "  Digest:      https://${DIGEST_REPO/\//.github.io/}"
echo "  Digest repo: https://github.com/$DIGEST_REPO"
echo
echo "  Cron jobs:"
echo "    Morning digest: 9:00 AM IST (03:30 UTC)"
echo "    Evening digest: 9:00 PM IST (15:30 UTC)"
echo
echo "  To share a bookmark: send the bot a link on Telegram"
echo "  To change topics/people: tell the bot on Telegram"
echo
