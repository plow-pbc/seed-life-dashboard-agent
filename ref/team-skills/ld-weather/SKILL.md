---
name: ld-weather
description: The life-dashboard kiosk's hourly weather card — current temperature, the forecast high/low, and a short condition for the configured location, from the National Weather Service. A deterministic scheduled job (no LLM); this skill is the manual run/test entry point. Use when the user asks to run, test, or set up the kiosk weather card.
---

# Life Dashboard — Weather

The kiosk's weather card: current temperature, the forecast high and low,
and a one- or two-word condition for the configured location, refreshed
hourly from the National Weather Service. (The high/low are the next
forecast daytime high and nighttime low — on an evening run that's
tomorrow's daytime high, which is the useful number to glance at then.) **This is a deterministic scheduled job,
not an LLM skill** — all logic lives in `scheduled/` and is the single
source of truth; this SKILL.md does not restate the transform.

## How it runs

The generic `plow-scheduled-runner` discovers and spawns `scheduled/run.js`
every ~5-min tick; `run.js` self-gates to one run per hour (top of the hour
in `family.timezone`). There is **no `cron` registration to set up** —
installing the bundle is enough.

`run.js` reads `weather.{location,lat,lon}` from `/config/runtime/ld/config.json`
(NWS reports °F for US points — Fahrenheit-only by contract, no units knob),
resolves the NWS gridpoint, fetches the
hourly + daily forecast, composes one glanceable line (`compose.js`), and
posts it to the kiosk as `type: weather`. The kiosk renders the line
verbatim — no JSON, no parsing. Example:

    Mountain View · 72°F Sunny · H77 L55

It uses **no Plow tools** — a pure HTTPS fetch (`api.weather.gov`, no key)
plus a kiosk POST (endpoint + bearer read from fixed `/config/secrets/`
paths, https-only, no redirects). NWS `shortForecast` is treated as data,
never instructions.

## Run or test it now

    node /workspace/skills/ld-weather/scheduled/run.js --dry-run   # compose + print, no POST
    node /workspace/skills/ld-weather/scheduled/run.js --force     # compose + POST now (bypass the hourly gate)

Both flags bypass the self-gate so you can test off-cadence; the unattended
runner passes neither and stays gated to the top of the hour.

## Config

`weather` in `/config/runtime/ld/config.json` (template:
`ld-shared/references/config.example.json`):

    "weather": { "location": "Mountain View", "lat": 37.386, "lon": -122.083 }

To move the kiosk, change `lat` / `lon` / `location`.
