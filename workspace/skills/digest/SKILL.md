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

### 2. Search X/Twitter for posts

Use `web_search` tool to search for recent posts. For each topic and person in the config:

```
site:x.com OR site:twitter.com "<topic>" after:<yesterday-date>
site:x.com OR site:twitter.com from:<handle> after:<yesterday-date>
```

Also try:
```
"<topic>" AI site:nitter.net after:<yesterday-date>
```

### 3. Curate and summarize

From the search results:
- Pick the top 15-20 most interesting/impactful posts
- Group by theme (not by person)
- Write a crisp summary for each — what it says, why it matters
- Add the original post URL
- Include a 2-3 sentence "TL;DR" at the top

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

## Important Notes

- Use IST (Asia/Kolkata, UTC+5:30) for all dates
- Keep summaries crisp — no filler, no "In this post..."
- For X searches without API: use web_search with `site:x.com` queries
- If a search returns nothing useful, say so — don't fabricate
- The site auto-builds via GitHub Pages on push, allow ~2 min for deploy
- Always include source URLs so the reader can click through
