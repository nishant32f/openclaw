# Food Log Skill

Track meals, calories, and nutrition via conversational food logging.

## When to use

- User mentions eating, food, meals, snacks, breakfast/lunch/dinner
- User says "log food", "I ate...", "had ...", "food log", "what did I eat"
- User asks for calorie summary, weekly report, or nutrition stats
- Cron/heartbeat asks for a daily food summary

## How it works

### Logging a meal

When the user mentions food:

1. **Ask meal type** (if not obvious): Breakfast / Lunch / Dinner / Snack
2. **Ask time** — if they don't reply or say "now", use current system time in IST
3. **Collect items** — let them list freely. They might say:
   - "2 rotis, dal, rice" → infer typical portions
   - "a bowl of oats with banana" → parse components
   - "chicken biryani from swiggy" → estimate restaurant portion
   - "coffee" → assume 1 cup with milk unless specified
4. **Canonicalize** each item (see rules below)
5. **Estimate calories** per item based on quantity
6. **Confirm** with the user — show a clean table:
   ```
   Lunch — 1:30 PM

   Chicken Biryani (1 plate)     ~520 kcal
   Raita (1 bowl)                ~80 kcal
   Coke (330ml can)              ~140 kcal
   ─────────────────────────────────────
   Total                         ~740 kcal
   ```
7. **On confirmation** (or if no objection after showing), write to the log

### Canonicalization rules

- Normalize names: "roti" / "chapati" / "phulka" → **Roti**
- Normalize names: "daal" / "dal" / "dhal" → **Dal**
- Standardize quantities: "a couple" → 2, "some" → 1 serving, "bowl" → 1 bowl
- Include cooking style when calorie-relevant: "fried egg" vs "boiled egg"
- For branded/restaurant items, note the source: "Biryani (Behrouz, 1 plate)"
- When quantity is ambiguous, infer typical Indian serving sizes
- Always show the inferred quantity so the user can correct it

### Calorie estimation

- Use commonly known Indian food calorie values
- Be honest about estimates — prefix with `~` (approximate)
- For packaged food, use label values if known
- For restaurant food, estimate on the higher side
- Common references to keep consistent:
  - Roti (1 medium): ~100 kcal
  - Rice (1 bowl/katori): ~180 kcal
  - Dal (1 bowl): ~150 kcal
  - Sabzi (1 bowl, avg): ~120 kcal
  - Egg (1, boiled): ~70 kcal
  - Egg (1, fried): ~110 kcal
  - Chai (1 cup, with sugar): ~50 kcal
  - Coffee (1 cup, milk+sugar): ~60 kcal
  - Chicken breast (100g): ~165 kcal
  - Paneer (100g): ~265 kcal

## Storage

All data lives in the workspace under `foodlog/`.

### Daily log: `foodlog/YYYY-MM-DD.md`

```markdown
# Food Log — Mar 17, 2026

## Breakfast — 8:30 AM
| Item | Qty | Calories |
|------|-----|----------|
| Oats Porridge | 1 bowl | ~180 |
| Banana | 1 medium | ~105 |
| Coffee | 1 cup | ~60 |
| **Subtotal** | | **~345** |

## Lunch — 1:15 PM
| Item | Qty | Calories |
|------|-----|----------|
| Roti | 2 | ~200 |
| Dal | 1 bowl | ~150 |
| Aloo Gobi | 1 bowl | ~130 |
| **Subtotal** | | **~480** |

## Snack — 4:00 PM
| Item | Qty | Calories |
|------|-----|----------|
| Chai | 1 cup | ~50 |
| Biscuits (Parle-G) | 4 | ~80 |
| **Subtotal** | | **~130** |

---
**Day Total: ~955 kcal** (so far)
```

### Weekly summary: `foodlog/weekly/YYYY-WNN.md`

Generated on request or via cron (Sunday evening). Contains:
- Daily totals for the week
- Average daily intake
- Most frequent items
- Any notable patterns (skipped meals, high days, etc.)

### Food database: `foodlog/foods.md`

A growing canonical list of foods the user eats regularly, with settled calorie values. This avoids re-estimating the same items.

```markdown
# Food Database

| Food | Default Qty | Calories | Notes |
|------|-------------|----------|-------|
| Roti | 1 medium | ~100 | Whole wheat, no ghee |
| Dal (Toor) | 1 bowl | ~150 | With tadka |
| Rice (Steamed) | 1 katori | ~180 | White basmati |
| Chicken Biryani | 1 plate | ~520 | Restaurant avg |
| Oats Porridge | 1 bowl | ~180 | With milk, no sugar |
```

Update this file whenever:
- A new food is logged for the first time
- The user corrects a calorie estimate
- You learn the user's specific portion sizes

## Interaction style

- Be quick, not clinical. This isn't a hospital form.
- If they say "had lunch — dal chawal 2 roti", log it. Don't ask 5 follow-up questions.
- Only ask follow-ups when genuinely ambiguous (e.g., "had pasta" — what kind? how much?)
- On Telegram, format as clean text (no markdown tables — use aligned text or bullet lists)
- Show the running day total after each meal log
- If they forgot to log and mention it later ("oh I also had chai at 4"), add it retroactively

## Summaries

When asked "what did I eat today" or "calorie count":
- Read today's `foodlog/YYYY-MM-DD.md`
- Show a clean summary with running total
- Compare to daily calorie target from `skills/foodlog/foods.md` (default: ~2000 kcal if not set)

To persist a custom calorie target, add a line to the top of `foods.md`:
```
**Daily target: 1800 kcal**
```

When asked for weekly/monthly view:
- Read relevant daily files
- Compute averages and trends
- Keep it visual — use simple bar representations if on a platform that supports it

## Creating the foodlog directory

If `foodlog/` doesn't exist in the workspace, create it on first use:
```
foodlog/
  foods.md          ← canonical food database
  YYYY-MM-DD.md     ← daily logs
  weekly/           ← weekly summaries
```

## Platform formatting

- **Telegram**: No markdown tables. Use bullet lists or aligned text:
  ```
  🍽 Lunch — 1:15 PM
  • Roti × 2 — ~200 kcal
  • Dal (1 bowl) — ~150 kcal
  • Aloo Gobi (1 bowl) — ~130 kcal
  Total: ~480 kcal

  📊 Day so far: ~825 kcal
  ```
- **Web/Discord**: Tables are fine
