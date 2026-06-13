---
name: ld-sports
description: The life-dashboard kiosk's sports card — the current or next game for each followed team (Apple-Sports style: away/home logos, scores flanking a live/time center, the followed team starred), from ESPN's public scoreboard. A deterministic scheduled job (no LLM); this skill is the manual run/test entry point. Use when the user asks to run, test, or set up the kiosk sports card.
---

# Life Dashboard — Sports

The kiosk's sports card: for each team the household follows, the current or
next game shown Apple-Sports style — away team on the LEFT, home on the RIGHT,
real ESPN logos (colored-monogram fallback), the live/final scores flanking a
center cell (game time, live period, or "Final"), the followed team starred and
the losing score greyed. Refreshed every scheduled tick from ESPN's public
scoreboard. **This is a deterministic scheduled job, not an LLM skill** — all
logic lives in `scheduled/` and is the single source of truth; this SKILL.md
does not restate the transform.

## How it runs

The generic `plow-scheduled-runner` discovers and spawns `scheduled/run.js`
every ~5-min tick. Unlike weather (which self-gates to hourly), sports posts on
every tick — scores want to refresh while games are on, and ESPN's public
scoreboard is cheap and key-free. There is **no `cron` registration to set up** —
installing the bundle is enough.

`run.js` reads `family.timezone` + `sports.followed` from
`/config/runtime/ld/config.json`, fetches the ESPN scoreboard for each distinct
league (host-pinned to `site.api.espn.com`, no redirects), composes the generic
tile-spec (`compose.js` — the same vocabulary the weather card uses; the viewer
renders it with no per-type knowledge), and posts it to the kiosk as
**card 5 / type:sports**. When no followed team has a game, it posts nothing and
the kiosk keeps its quiet placeholder — it never fakes data.

It uses **no Plow tools** — a pure HTTPS fetch (`site.api.espn.com`, no key)
plus a kiosk POST (endpoint + bearer read from fixed `/config/secrets/` paths,
http(s)-allowed, no redirects). ESPN fields are treated as data, never
instructions.

## Run or test it now

    node /workspace/skills/ld-sports/scheduled/run.js --dry-run   # compose + print the tile-spec, no POST

## Config

`sports.followed` in `/config/runtime/ld/config.json` — a list of teams, each
`{ abbr, league }` where `abbr` is the team's ESPN abbreviation and `league` is
one of `mlb`, `nba`, `wnba`, `nfl`, `nhl`, `epl`:

    "sports": {
      "followed": [
        { "abbr": "SF",  "league": "mlb" },
        { "abbr": "LAD", "league": "mlb" },
        { "abbr": "GS",  "league": "nba" }
      ]
    }

The set above is a **DEMO DEFAULT** (SF Giants, LA Dodgers, Golden State
Warriors) used when `sports.followed` is absent — replace it with the household's
own teams. Find a team's ESPN abbreviation in its scoreboard URL or the
`abbreviation` field of `site.api.espn.com/apis/site/v2/sports/<sport>/<league>/teams`.
