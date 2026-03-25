#!/usr/bin/env bash
# Generate an AI digest: fetch X posts, summarize with LLM, push to GitHub Pages.
#
# Usage:
#   ./scripts/generate-digest.sh                  # morning digest
#   ./scripts/generate-digest.sh evening           # evening digest
#   ./scripts/generate-digest.sh morning --dry-run # preview without pushing
#
# Designed to run on the Fly instance via cron or manually.
# Only the summarization step uses an LLM — everything else is deterministic.
#
# Requires: bird, gh, jq, openclaw (for LLM summarization + telegram notify)
# Env vars: AUTH_TOKEN, CT0 (bird), GH_TOKEN (gh), OPENCLAW_GATEWAY_TOKEN

set -euo pipefail

PERIOD="${1:-morning}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

DATE=$(date -u +%Y-%m-%d)
YEAR=$(date -u +%Y)
MONTH=$(date -u +%m)
DAY=$(date -u +%d)
HOUR=$(TZ=Asia/Kolkata date +%H:%M)
TIMESTAMP=$(TZ=Asia/Kolkata date +"%Y-%m-%d %H:%M:%S %z")
DIGEST_REPO="nishant32f/digest"
CONFIG="/data/workspace/skills/digest/digest.config.json"
WORK_DIR=$(mktemp -d)
RAW_FILE="$WORK_DIR/raw.txt"
DIGEST_FILE="$WORK_DIR/digest.md"
FILENAME="_digests/${DATE}-${PERIOD}.md"
TITLE="AI Digest — $(TZ=Asia/Kolkata date +'%b %d, %Y') $(echo "$PERIOD" | sed 's/./\U&/')"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log() { echo "[digest] $*" >&2; }

# ─── Step 1: Read config ────────────────────────────────────────────

log "Reading config..."
PEOPLE=$(jq -r '.people[]' "$CONFIG")
TOPICS=$(jq -r '.topics[]' "$CONFIG")
MAX_POSTS=$(jq -r '.maxPostsPerDigest // 20' "$CONFIG")
STYLE=$(jq -r '.summaryStyle // "crisp and opinionated"' "$CONFIG")

# ─── Step 2: Fetch X posts from people ──────────────────────────────

log "Fetching posts from people..."
echo "=== X/TWITTER POSTS FROM FOLLOWED PEOPLE ===" > "$RAW_FILE"
echo "" >> "$RAW_FILE"

PEOPLE_COUNT=0
while IFS= read -r handle; do
  [ -z "$handle" ] && continue
  log "  bird user-tweets $handle..."
  if OUTPUT=$(bird user-tweets "$handle" -n 3 --plain 2>/dev/null); then
    if [ -n "$OUTPUT" ]; then
      echo "--- $handle ---" >> "$RAW_FILE"
      echo "$OUTPUT" >> "$RAW_FILE"
      echo "" >> "$RAW_FILE"
      PEOPLE_COUNT=$((PEOPLE_COUNT + 1))
    fi
  else
    log "  WARN: bird failed for $handle (skipping)"
  fi
done <<< "$PEOPLE"

log "Fetched posts from $PEOPLE_COUNT people"

# ─── Step 3: Fetch topic searches ───────────────────────────────────

log "Searching topics..."
echo "" >> "$RAW_FILE"
echo "=== X/TWITTER TOPIC SEARCHES ===" >> "$RAW_FILE"
echo "" >> "$RAW_FILE"

TOPIC_COUNT=0
while IFS= read -r topic; do
  [ -z "$topic" ] && continue
  log "  bird search: $topic..."
  if OUTPUT=$(bird search "$topic" -n 5 --plain 2>/dev/null); then
    if [ -n "$OUTPUT" ]; then
      echo "--- Topic: $topic ---" >> "$RAW_FILE"
      echo "$OUTPUT" >> "$RAW_FILE"
      echo "" >> "$RAW_FILE"
      TOPIC_COUNT=$((TOPIC_COUNT + 1))
    fi
  else
    log "  WARN: bird search failed for '$topic' (skipping)"
  fi
done <<< "$TOPICS"

log "Searched $TOPIC_COUNT topics"

# ─── Step 4: Check we have content ──────────────────────────────────

RAW_SIZE=$(wc -c < "$RAW_FILE")
if [ "$RAW_SIZE" -lt 200 ]; then
  log "ERROR: Not enough content fetched (${RAW_SIZE} bytes). Bird auth may have expired."
  log "Refresh AUTH_TOKEN and CT0 in .env and re-run setup."
  exit 1
fi

log "Raw content: ${RAW_SIZE} bytes"

# ─── Step 5: Summarize with LLM (the only agentic step) ─────────────

log "Summarizing with LLM..."

# Truncate raw content to ~30K chars to stay within context limits
RAW_TRUNCATED=$(head -c 30000 "$RAW_FILE")

SYSTEM_PROMPT="You are a digest curator. Create a crisp AI digest in markdown. Style: ${STYLE}. Rules: Pick the top ${MAX_POSTS} most interesting items. Group by theme, not by person. For each item write a one-line summary of what it says and why it matters, and make the item title a clickable markdown link to the original URL like [Title](https://x.com/...). Start with a 2-3 sentence TL;DR. No filler. Skip spam. Do NOT use footnote-style references — every URL must be an inline markdown link. Output ONLY markdown body, no front matter, no references section at the end."

# Direct OpenRouter API call — no openclaw agent needed
SUMMARY=$(curl -s --max-time 60 \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg sys "$SYSTEM_PROMPT" \
    --arg content "$RAW_TRUNCATED" \
    '{
      model: "anthropic/claude-haiku-4-5",
      max_tokens: 4096,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: $content}
      ]
    }')" \
  "https://openrouter.ai/api/v1/chat/completions" \
  | jq -r '.choices[0].message.content // empty') || true

if [ -z "$SUMMARY" ] || [ "$SUMMARY" = "null" ]; then
  log "ERROR: LLM summarization failed. Falling back to raw dump."
  SUMMARY="*LLM summarization failed. Raw content below.*

$(head -100 "$RAW_FILE")"
fi

# ─── Step 6: Format as Jekyll markdown ──────────────────────────────

log "Formatting digest..."

cat > "$DIGEST_FILE" <<JEKYLL
---
title: "${TITLE}"
date: ${TIMESTAMP}
categories: [AI, digest]
---

${SUMMARY}
JEKYLL

log "Digest written to $DIGEST_FILE"

# ─── Step 7: Dry run check ──────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN — not pushing to GitHub"
  cat "$DIGEST_FILE"
  exit 0
fi

# ─── Step 8: Push to GitHub ─────────────────────────────────────────

log "Pushing to GitHub ($DIGEST_REPO)..."

CONTENT_B64=$(base64 -w 0 < "$DIGEST_FILE" 2>/dev/null || base64 < "$DIGEST_FILE" | tr -d '\n')

# Check if file already exists (get sha for update)
SHA=$(gh api "repos/$DIGEST_REPO/contents/$FILENAME" --jq '.sha' 2>/dev/null || echo "")

if [ -n "$SHA" ]; then
  log "File exists, updating (sha: $SHA)..."
  gh api "repos/$DIGEST_REPO/contents/$FILENAME" \
    --method PUT \
    -f message="digest: ${DATE} ${PERIOD}" \
    -f content="$CONTENT_B64" \
    -f sha="$SHA" \
    --jq '.content.html_url' 2>/dev/null || log "WARN: GitHub push failed"
else
  log "Creating new file..."
  gh api "repos/$DIGEST_REPO/contents/$FILENAME" \
    --method PUT \
    -f message="digest: ${DATE} ${PERIOD}" \
    -f content="$CONTENT_B64" \
    --jq '.content.html_url' 2>/dev/null || log "WARN: GitHub push failed"
fi

PAGES_URL="https://nishant32f.github.io/digest/digests/${YEAR}/${MONTH}/${DAY}/"
log "Published: $PAGES_URL"

# ─── Step 9: Notify on Telegram ─────────────────────────────────────

log "Sending Telegram notification..."

# Extract TL;DR for the notification — strip markdown to clean plain text
# 1. Remove heading lines  2. Strip bold/italic markers  3. Convert [text](url) to just text
TLDR=$(echo "$SUMMARY" \
  | sed '/^#/d; /^$/d' \
  | head -5 \
  | sed 's/\*\*//g; s/\*//g' \
  | sed 's/\[\([^]]*\)\]([^)]*)/\1/g' \
  | head -3)

# Escape HTML special chars in TLDR for Telegram parse_mode=HTML
TLDR=$(echo "$TLDR" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

NOTIFY_MSG="📰 <b>${TITLE}</b>

${TLDR}

🔗 <a href=\"${PAGES_URL}\">Read full digest</a>"

# Direct Telegram Bot API call — more reliable than openclaw message send
curl -s --max-time 10 \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_OWNER_ID}" \
  --data-urlencode "text=${NOTIFY_MSG}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_web_page_preview=true" \
  >/dev/null 2>&1 || log "WARN: Telegram notification failed"

log "Done!"
