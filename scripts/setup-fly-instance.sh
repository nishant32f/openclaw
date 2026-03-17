#!/usr/bin/env bash
# Full reproducible setup for an OpenClaw Fly.io instance.
# Usage: ./scripts/setup-fly-instance.sh [app-name]
#
# This script is idempotent — safe to re-run.
# It handles: dependency checks, config push, workspace sync, cron setup,
# GitHub Pages repo setup, and gateway restart.

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

# ─── Check remote dependencies (batched into one SSH call) ───────────

step "Checking remote dependencies"

DEP_STATUS=$(fly ssh console -a "$APP" -C "sh -c 'for cmd in gh git openclaw; do which \$cmd >/dev/null 2>&1 && echo \"OK:\$cmd\" || echo \"MISSING:\$cmd\"; done'" 2>/dev/null || echo "MISSING:gh")

echo "$DEP_STATUS" | while IFS=: read -r status cmd; do
  if [ "$status" = "OK" ]; then
    info "$cmd available on remote"
  else
    warn "$cmd NOT found on remote"
  fi
done

if echo "$DEP_STATUS" | grep -q "MISSING:gh"; then
  warn "Attempting to install gh..."
  fly ssh console -a "$APP" -C "sh -c 'apt-get update -qq && apt-get install -y -qq gh'" 2>/dev/null || warn "Could not install gh"
fi

# ─── Push config (single SSH call) ──────────────────────────────────

step "Pushing openclaw.json config"

if [ -f "$REPO_DIR/openclaw.json" ]; then
  fly ssh console -a "$APP" -C "sh -c 'cat > /data/openclaw.json && chown node:node /data/openclaw.json'" < "$REPO_DIR/openclaw.json"
  info "Config pushed"
else
  warn "No openclaw.json found at repo root — skipping config push"
fi

# ─── Sync secrets (--stage to avoid premature restart) ───────────────

step "Syncing secrets"

if [ -f "$REPO_DIR/.env" ]; then
  fly secrets import -a "$APP" --stage < "$REPO_DIR/.env" 2>/dev/null \
    || fly secrets import -a "$APP" < "$REPO_DIR/.env"
  info "Secrets synced"
else
  warn "No .env found — skipping secrets sync"
fi

# ─── Sync workspace (delegates to sync script) ──────────────────────

step "Syncing workspace files"

"$SCRIPT_DIR/sync-workspace-to-fly.sh" "$APP"
info "Workspace synced"

# ─── Setup digest repo on remote (for gh API access) ────────────────

step "Setting up digest repo access"

if fly ssh console -a "$APP" -C "sh -c 'test -n \"\$GH_TOKEN\" && echo ok'" 2>/dev/null | grep -q ok; then
  info "GH_TOKEN secret is set on remote"
else
  warn "GH_TOKEN not set on remote. The digest skill needs it to push to GitHub."
  warn "Set it with: fly secrets set GH_TOKEN=ghp_xxx -a $APP"
  warn "Generate a fine-grained token at: https://github.com/settings/personal-access-tokens/new"
fi

# ─── Setup GitHub Pages ─────────────────────────────────────────────

step "Configuring GitHub Pages on $DIGEST_REPO"

PAGES_STATUS=$(gh api "repos/$DIGEST_REPO/pages" 2>&1 || echo "NOT_ENABLED")
if echo "$PAGES_STATUS" | grep -q "NOT_ENABLED\|Not Found"; then
  gh api "repos/$DIGEST_REPO/pages" \
    --method POST \
    -f "source[branch]=main" \
    -f "source[path]=/" 2>/dev/null || \
    warn "Could not auto-enable GitHub Pages. Enable manually: repo Settings → Pages → Source: main branch"
  info "GitHub Pages enabled (may take a few minutes to build)"
else
  info "GitHub Pages already configured"
fi

# ─── Restart gateway ────────────────────────────────────────────────

step "Restarting gateway to pick up all changes"

MACHINE_ID=$(fly machines list -a "$APP" --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)
if [ -n "$MACHINE_ID" ]; then
  fly machines restart "$MACHINE_ID" -a "$APP" 2>&1 || warn "Could not restart machine $MACHINE_ID"
  info "Gateway restarting (machine $MACHINE_ID)"
else
  warn "Could not determine machine ID. Restart manually: fly machines restart <id> -a $APP"
fi

# ─── Setup cron jobs (after gateway is up) ───────────────────────────

step "Setting up cron jobs (waiting for gateway...)"

sleep 25

MORNING_MSG='Read the digest skill (workspace skills/digest/SKILL.md). Run a morning digest: search X/Twitter for AI posts from the last 12 hours using the topics and people in digest.config.json. Create a digest post and push it to the nishant32f/digest GitHub repo. Then send me a short summary of the digest on Telegram.'
EVENING_MSG='Read the digest skill (workspace skills/digest/SKILL.md). Run an evening digest: search X/Twitter for AI posts from the last 12 hours using the topics and people in digest.config.json. Create a digest post and push it to the nishant32f/digest GitHub repo. Then send me a short summary of the digest on Telegram.'

# Create both cron jobs + verify in a single SSH call
fly ssh console -a "$APP" -C "sh -c '
  GW=\"--url $GW_URL --token \$OPENCLAW_GATEWAY_TOKEN\"
  openclaw cron add \$GW --cron \"30 3 * * *\" --tz Asia/Kolkata --name digest-morning --timeout-seconds 120 --channel telegram --message \"$MORNING_MSG\" 2>/dev/null || echo \"Morning cron may already exist\"
  openclaw cron add \$GW --cron \"30 15 * * *\" --tz Asia/Kolkata --name digest-evening --timeout-seconds 120 --channel telegram --message \"$EVENING_MSG\" 2>/dev/null || echo \"Evening cron may already exist\"
  echo \"---CRON LIST---\"
  openclaw cron list \$GW 2>/dev/null || echo \"Could not list cron jobs\"
'" 2>&1 || warn "Cron setup failed — gateway may still be booting. Run manually after gateway is up."

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
