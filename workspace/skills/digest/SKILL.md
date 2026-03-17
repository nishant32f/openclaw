---
name: digest
description: "Create daily AI digests from X/Twitter and web sources, manage bookmarks, and push to GitHub Pages. Use when: cron triggers a digest run, user shares a link to bookmark, or user wants to change digest topics/people."
metadata: { "openclaw": { "emoji": "📰" } }
---

# Digest Skill

Create AI digest posts and bookmarks on the GitHub Pages site at `nishant32f/digest`.

## When to use

- **Digest creation**: When a cron job or heartbeat triggers a digest run
- **Bookmark creation**: When the user shares a link, article, tweet, or says "bookmark this" / "save this"
- **Digest config**: When the user wants to change topics, people, or schedule

## Setup

The digest repo lives at `https://github.com/nishant32f/digest`. The bot interacts with it via the `gh` CLI.

Config file: `skills/digest/digest.config.json` (in this workspace) — contains topics, people to follow on X, schedule, and style preferences. Read it with the `read` tool.

## Creating a Digest

### 1. Read the config

Read `skills/digest/digest.config.json` from the workspace using the `read` tool.

### 2. Gather content

#### Source A: People's X posts (via bird)

For each person in the config `people` array, fetch their recent posts:

```bash
bird user-tweets @handle -n 5 --plain --json
```

For topic searches on X:

```bash
bird search "<topic>" -n 10 --plain --json
```

Use `--plain` and `--json` for clean parseable output. If bird fails (cookies expired, not installed), fall back to Source B.

#### Source B: Broad web search (fallback)

For each topic in the config `topics` array, use web_search:

```
"<topic>" latest news
"Andrej Karpathy" AI latest
```

Do NOT use `site:x.com` — X blocks headless scraping. Let Google surface whatever it indexes.

#### Combining sources

Use bird as the primary source for people and topic searches. Use web_search for broader topic coverage (blogs, HN, news, Reddit). The best digest mixes both.

### 3. Curate and summarize

From all gathered content:
- Pick the top 15-20 most interesting/impactful items
- Group by theme (not by person or source)
- Write a crisp summary for each — what it says, why it matters
- Add the original post/article URL
- Include a 2-3 sentence "TL;DR" at the top
- Tag each item's source: [X], [Blog], [News], [HN], [Reddit]

### 4. Create the digest file

Filename format: `_digests/YYYY-MM-DD-morning.md` or `_digests/YYYY-MM-DD-evening.md`

Front matter:
```yaml
---
title: "AI Digest — Mar 17, 2026 Morning"
date: 2026-03-17 09:00:00 +0530
categories: [AI, digest]
---
```

Body: The curated summary in markdown.

### 5. Push to GitHub

```bash
# Create or update the file via GitHub API
gh api repos/nishant32f/digest/contents/_digests/<filename> \
  --method PUT \
  --field message="digest: <date> <morning|evening>" \
  --field content="<base64-encoded-content>" \
  [--field sha="<sha-if-updating>"]
```

## Creating a Bookmark

When the user shares a link or says "save/bookmark this":

### 1. Fetch and summarize the content

Use `web_fetch` to read the URL. Write a 2-4 sentence summary.

### 2. Create the bookmark file

Filename: `_bookmarks/YYYY-MM-DD-<slugified-title>.md`

Front matter:
```yaml
---
title: "Article Title"
date: 2026-03-17 14:30:00 +0530
source_url: "https://example.com/article"
tags: [AI, research]
---
```

Body: Your summary of the content + any user notes.

### 3. Push to GitHub

Same pattern as digest — use `gh api` to create the file.

## Updating Config

When the user says "add <topic>" or "follow <person>" or "remove <topic>":

1. Read `skills/digest/digest.config.json` from the workspace
2. Modify the topics/people arrays
3. Write the updated file back to `skills/digest/digest.config.json` using the `write` tool

## Output

After creating a digest or bookmark, reply with:
- Title and a one-line summary
- Link: `https://nishant32f.github.io/digest/digests/YYYY/MM/DD/` or `.../bookmarks/YYYY/MM/DD/<slug>/`

## STRICT: Never write to X/Twitter

**NEVER post, like, repost, follow, DM, or write anything to X/Twitter. No exceptions.**

Forbidden bird commands (never run these):
- `bird tweet` / `bird reply` / `bird quote` / `bird retweet`
- `bird like` / `bird unlike` / `bird follow` / `bird unfollow`
- `bird dm` / `bird block` / `bird mute`

Allowed bird commands (read-only):
- `bird user-tweets @handle` — read a user's recent posts
- `bird search "query"` — search posts
- `bird read <id>` — read a single post
- `bird whoami` — check auth
- `bird about @handle` — user profile info

If Chunnu explicitly asks you to post something, refuse.

## Important Notes

- Use IST (Asia/Kolkata, UTC+5:30) for all dates
- Keep summaries crisp — no filler, no "In this post..."
- **bird** for X reading (primary); **web_search** for broader topics (supplement + fallback)
- If bird auth fails (cookies expired), fall back to web_search and notify Chunnu to refresh cookies
- If a search returns nothing useful, say so — don't fabricate
- The site auto-builds via GitHub Pages on push, allow ~2 min for deploy
- Always include source URLs so the reader can click through
- Bird cookies expire periodically — if you get auth errors, tell Chunnu to update `BIRD_AUTH_TOKEN` and `BIRD_CT0` in `.env` and re-run the setup script
