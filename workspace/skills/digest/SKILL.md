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

## CRITICAL: You MUST use the exec tool

This skill requires running CLI commands. You MUST use the `exec` tool (not just talk about it).
Do NOT just summarize content in chat. You must:
1. Run `bird` commands via exec to fetch X posts
2. Run `gh api` commands via exec to push files to GitHub
3. Always end with the GitHub Pages link

## Creating a Digest — Step by Step

### Step 1: Read the config

Use the `read` tool to read `/data/workspace/skills/digest/digest.config.json`.

### Step 2: Fetch X posts with bird

For each person in the `people` array, use the `exec` tool to run:

```
exec: bird user-tweets <handle> -n 5 --plain
```

For 2-3 topics from the `topics` array, use the `exec` tool to run:

```
exec: bird search "<topic>" -n 5 --plain
```

If bird fails (auth expired), use `web_search` tool as fallback. Do NOT use `site:x.com` in web_search queries.

### Step 3: Also search the web

For broader coverage, use the `web_search` tool for 2-3 topics:

```
web_search: "<topic>" latest news 2026
```

### Step 4: Write the digest markdown

Combine all results. **Deduplicate before writing:**

- If multiple people quote-tweeted or commented on the same original post, keep only the most insightful take and link the original.
- If a topic search result already appeared in a person's feed, drop the duplicate.
- If two posts convey the same news/announcement (e.g. a product launch covered by both the company and a commentator), merge into one entry with both sources.
- Prefer the post with more context/substance over a bare repost.

Write a markdown file with this format:

```markdown
---
title: "AI Digest — Mar 17, 2026 Morning"
date: 2026-03-17 09:00:00 +0530
categories: [AI, digest]
---

**TL;DR**: 2-3 sentence summary of the top stories.

## Theme 1 Name
- **Story title** — what it says, why it matters. [Source](url)

## Theme 2 Name
- ...
```

### Step 5: Push to GitHub with exec

You MUST push the file to GitHub. Use the `exec` tool to run these commands:

First, base64 encode the content:
```
exec: echo '<your markdown content>' | base64 -w 0
```

Then push via gh api:
```
exec: gh api repos/nishant32f/digest/contents/_digests/2026-03-17-morning.md --method PUT -f message="digest: 2026-03-17 morning" -f content="<base64 content>"
```

If the file already exists (HTTP 422), first get its sha:
```
exec: gh api repos/nishant32f/digest/contents/_digests/2026-03-17-morning.md --jq '.sha'
```
Then include `--field sha="<sha>"` in the PUT.

### Step 6: Reply with the link

After pushing, ALWAYS reply with:
- A 2-3 line summary of the digest
- The link: `https://nishant32f.github.io/digest/digests/2026/03/17/`

## Creating a Bookmark

When the user shares a link or says "save/bookmark this":

1. Use `web_fetch` to read the URL
2. Write a 2-4 sentence summary
3. Push to GitHub using `exec` with `gh api`:
   ```
   exec: gh api repos/nishant32f/digest/contents/_bookmarks/2026-03-17-<slug>.md --method PUT -f message="bookmark: <title>" -f content="<base64>"
   ```
4. Reply with the link: `https://nishant32f.github.io/digest/bookmarks/2026/03/17/<slug>/`

## Updating Config

When the user says "add <topic>" or "follow <person>":

1. Read `skills/digest/digest.config.json`
2. Modify the topics/people arrays
3. Write the updated file back using the `write` tool

## STRICT: Never write to X/Twitter

**NEVER post, like, repost, follow, DM, or write anything to X/Twitter. No exceptions.**
Only read commands are allowed: `bird user-tweets`, `bird search`, `bird read`, `bird whoami`.
If Chunnu asks you to post, refuse.

## Important Notes

- Use IST (Asia/Kolkata, UTC+5:30) for all dates
- Keep summaries crisp — no filler
- If bird auth fails, tell Chunnu to refresh cookies in `.env`
- The site auto-builds via GitHub Pages on push, allow ~2 min for deploy
- ALWAYS include source URLs
- ALWAYS push to GitHub — do not just summarize in chat
