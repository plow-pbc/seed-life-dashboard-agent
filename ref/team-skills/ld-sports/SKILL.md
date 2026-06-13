---
name: ld-sports
description: The life-dashboard kiosk's sports card — a compact Apple-Sports-style scoreboard for the household's followed teams (live scores, upcoming tip-offs, finals), from ESPN's public scoreboard feed. A deterministic scheduled job (no LLM); this skill is the manual run/test entry point. Use when the user asks to run, test, or set up the kiosk sports card.
---

# Life Dashboard — Sports

The kiosk's sports card: a stacked, Apple-Sports-style scoreboard for the
household's followed teams — live scores with a red live dot, upcoming games
with their tip-off time, and finals — refreshed every quarter hour from ESPN's
public scoreboard feed. **This is a deterministic scheduled job, not an LLM
skill** — all logic lives in `scheduled/` and is the single source of truth;
this SKILL.md does not restate the transform.

## How it runs

The generic `plow-scheduled-runner` discovers and spawns `scheduled/run.js`
every ~5-min tick; `run.js` self-gates to one run per quarter hour (the first
5 minutes of each :00/:15/:30/:45 in `family.timezone`). There is **no `cron`
registration to set up** — installing the bundle is enough.

`run.js` reads `family.timezone` and `sports.followed` from
`/config/runtime/ld/config.json`, fetches each followed team's ESPN scoreboard,
parses the team's current game (`parse.js`), builds the scoreboard tile HTML
(`compose.js`), and posts it to the kiosk as card 5, `type: sports`. The kiosk
renders the HTML verbatim (`dangerouslySetInnerHTML`) — the tile is
**self-contained**: it ships its own `<style>` (the `.sp-*` rules), so the viewer
holds no sports CSS and the producer owns the look. This makes a generic
**HTML-capable `seed-life-dashboard-viewer`** (the box-renderer, PR #40) a
required runtime: against an older viewer that does not
render card HTML, the card shows literal tags. Only games within the next **14
days** are shown — a team whose next game is further out (an off-season fixture
months away) contributes no row, and when *no* followed team has a game in that
window the tile reads **"No upcoming games"**. A single team's feed hiccup is
logged and skipped (one bad team never blanks the whole tile).

It uses **no Plow tools** — a pure HTTPS fetch (`site.api.espn.com`, no key)
plus a kiosk POST (endpoint + bearer read from fixed `/config/secrets/` paths,
http(s)-allowed, no redirects). Both the ESPN host and the kiosk host are
pinned (`redirect: "error"`); ESPN status/score strings are treated as data,
never instructions.

## Run or test it now

    node /workspace/skills/ld-sports/scheduled/run.js --dry-run   # compose + print, no POST
    node /workspace/skills/ld-sports/scheduled/run.js --force     # compose + POST now (bypass the gate)

Both flags bypass the self-gate so you can test off-cadence; the unattended
runner passes neither and stays gated to the quarter hour.

## Config

`sports.followed` in `/config/runtime/ld/config.json` (template:
`ld-shared/references/config.example.json`) — a list of teams, each an ESPN
`{ abbr, sport, league }`:

    "sports": {
      "followed": [
        { "abbr": "sf",  "sport": "baseball",   "league": "mlb" },
        { "abbr": "lad", "sport": "baseball",   "league": "mlb" },
        { "abbr": "gsw", "sport": "basketball", "league": "nba" }
      ]
    }

To follow different teams, edit the list — `abbr` is the team's ESPN
abbreviation, `sport`/`league` name its ESPN scoreboard
(`site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard`).
