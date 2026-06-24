---
name: ld-cooktonight
description: Set or clear the life-dashboard kiosk's "Cook Tonight" featured recipe — pin tonight's dinner on the Cook Tonight tile so the family sees what's for dinner, or clear it so the tile auto-falls-back to the most-recently-cooked recipe. Use when the head chef says what's for dinner tonight ("we're having X tonight", "set tonight's dinner to X", "feature the lasagna"), or asks to clear/reset tonight's pick. Request-triggered only (no cron).
---

# Life Dashboard — Cook Tonight

Pin tonight's dinner on the kiosk's **Cook Tonight** tile. The tile normally
shows an auto-pick (the most-recently-cooked recipe, then the most-recently-
updated); this skill lets the head chef override it with a specific recipe for
the night. Tapping the tile on the kiosk opens that recipe's full detail
(ingredients + directions) straight away.

The pick is stored on the dashboard's Pinch API in its **own** file
(`featured.json`), kept deliberately separate from the recipe library — the
hourly Paprika sync rewrites the library and **never touches the pick**, so a
sync can't wipe what you set tonight.

**Request-triggered, not scheduled.** Like `ld-theme` and `ld-bonus`, this skill
has **no cron and no `## Scheduling` section** — the agent runs it on demand when
the head chef sets or clears tonight's pick.

## What this skill does

When the head chef tells you what's for dinner:

1. Resolve the recipe **name** they gave to its id (against the live collection).
2. **Set** it as today's Cook Tonight pick via the Pinch API (`scripts/cook_tonight.py set`).

When they ask to clear it:

1. **Clear** today's pick (`scripts/cook_tonight.py clear`) → the tile auto-falls-back.

This skill only sets the Cook Tonight tile's featured pick. It does not manage the
recipe library, the grocery list, the calendar, or any other widget.

## When to use it

- **Set** — the head chef names tonight's dinner: "we're having sheet-pan chicken
  tonight", "set tonight's dinner to the lasagna", "feature the chili on the
  kiosk", "put taco night up". → `set "<recipe name>"`.
- **Clear** — "clear tonight's pick", "reset the Cook Tonight tile", "we'll
  figure out dinner later". → `clear` (the tile returns to its auto-fallback).

If the head chef names a recipe you can't find, or one that's ambiguous (several
recipes match), the script lists the candidates — relay them and ask which one
rather than guessing.

## Requirements / config

The skill needs the Pinch API base URL and the bearer token used for recipe
writes. Both are read **file-first, then environment** — never from the command
line, so a prompt-injected turn can't redirect the credential:

| What       | File (preferred)                      | Env fallback           |
| ---------- | ------------------------------------- | ---------------------- |
| Base URL   | `/config/secrets/pinch-base-url`      | `PINCH_BASE_URL`       |
| Bearer token | `/config/secrets/pinch-recipe-token` | `PINCH_RECIPE_TOKEN`   |

The base URL must be `https://` (the kiosk's public origin) — plain `http://` is
allowed only for `127.0.0.1`/`localhost` (the local mock). The token is never
printed; `--dry-run` redacts it.

The recipe **name** is the only thing you pass on the command line — it is not a
secret. The script resolves it to a recipe id by reading the live collection, so
you don't need to know ids.

## Set tonight's pick

Run the script by absolute path (the working directory is not the skill folder):

    scripts/cook_tonight.py set "<recipe name>"
    scripts/cook_tonight.py set "<recipe name>" --note "kids loved it"
    scripts/cook_tonight.py set "<recipe name>" --date 2026-06-23   # a future night

The name is matched case-insensitively: exact id → exact title → unique substring.
On success it prints, e.g.:

    set Cook Tonight: "Sheet-Pan Chicken" for 2026-06-22 · visible on the kiosk within ~5 min

If the name matches several recipes, it lists them and exits without setting
anything — pick a more specific name or pass the exact id shown.

Preview without sending (resolves the name, redacts the token):

    scripts/cook_tonight.py --dry-run set "Sheet-Pan Chicken"

## Clear tonight's pick

    scripts/cook_tonight.py clear                # today
    scripts/cook_tonight.py clear --date 2026-06-23

Clearing removes the override; the tile **auto-falls-back** to the most-recently-
cooked recipe (it is never blank). On success:

    cleared Cook Tonight for 2026-06-22 — tile returns to its auto-fallback · within ~5 min

## How it shows up on the kiosk

- The Cook Tonight tile shows the pinned recipe's photo + title, with the caption
  **"Tonight's pick"** (vs. "Recently cooked" / "From your library" for the
  auto-fallback).
- Tapping the tile opens that recipe's **detail** (ingredients + directions)
  directly — Back returns to the full library.
- If the pinned recipe is later deleted from the library, the tile falls back
  gracefully to the auto-pick (no broken tile).
- **The change appears on the kiosk's next reload (~5 min)** — the kiosk
  full-reloads on its `REFRESH_MS` cycle.

## Local testing against the 5180 mock

To try it end-to-end against the local mock (recipes served at `127.0.0.1:5180`):

    export PINCH_BASE_URL=http://127.0.0.1:5180
    export PINCH_RECIPE_TOKEN=<the mock's PINCH_RECIPE_TOKEN>

    # set a pick by name, then refresh http://127.0.0.1:5180 — the tile shows it
    scripts/cook_tonight.py set "Raspberry Swirl Cheesecake Pie"

    # clear it, then refresh — the tile returns to its auto-fallback
    scripts/cook_tonight.py clear

## Endpoints (for reference)

- `GET  {base}/api/pinch/collection` — read recipes (name→id resolution) +
  today's `featured` id.
- `PUT  {base}/api/pinch/featured` `{recipeId, date?, note?}` — set the pick
  (Bearer; validates the recipe exists).
- `DELETE {base}/api/pinch/featured?date=YYYY-MM-DD` — clear the pick (Bearer).
