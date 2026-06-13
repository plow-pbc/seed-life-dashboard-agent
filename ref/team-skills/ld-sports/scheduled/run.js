"use strict";

// ld-sports — scheduled entrypoint, run by the generic plow-scheduled-runner
// (which spawns this `run.js` on every ~5-min poll tick).
//
// This is opt-in (d) code: it ships in the ld-sports bundle and is installed
// into the read-only /scheduled mount only when a household runs this SEED's
// install. It does NOT ship with Plow.
//
// SELF-GATING: the runner ticks every ~5 min, but scores refresh well enough
// every ~15 min. This script does the ESPN fetch + post only when the
// wall-clock minute (in family.timezone) is in [0,5) ∪ [15,20) ∪ [30,35) ∪
// [45,50) — one tick per quarter hour — and exits 0 immediately otherwise.
//
// When it runs: for each followed team, fetch its ESPN scoreboard, parse the
// team's current game (parse.js), build the Apple-Sports tile HTML (compose.js),
// and post it to the kiosk as card 5 / type:sports (the viewer requires all
// three of card/type/text and renders text verbatim). No LLM, deterministic.
//
// Config + secrets are read from the /config mount (all written by plowd):
//   /config/runtime/ld/config.json        — family.timezone, sports.followed[]
//   /config/secrets/dashboard-endpoint-url — kiosk endpoint
//   /config/secrets/dashboard-token        — kiosk bearer

const fs = require("node:fs/promises");
const { parseGameFor } = require("./parse.js");
const { composeSports } = require("./compose.js");

const LD_CONFIG_PATH = "/config/runtime/ld/config.json";
const DASH_URL_PATH = "/config/secrets/dashboard-endpoint-url";
const DASH_TOKEN_PATH = "/config/secrets/dashboard-token";

// Pin every scoreboard GET to the ESPN public host so a malformed/compromised
// response can't steer an outbound GET elsewhere. Combined with redirect:"error"
// the runner only ever talks to site.api.espn.com.
const ESPN_BASE = "https://site.api.espn.com/";

// NOTE (rule-of-3): minuteInTz / readTrimmed / postKiosk mirror
// ld-weather/scheduled/run.js (itself mirrored from ld-calendar-nudge). Three
// Pattern-B bundles now share these idioms — extract them into a shared
// scheduled helper next time one of these is touched (and confirm /scheduled
// co-locates ld-shared so the import resolves). Inlined for now.

function log(message, fields) {
  try {
    console.error(`[ld-sports] ${message}${fields ? " " + JSON.stringify(fields) : ""}`);
  } catch {
    console.error(`[ld-sports] ${message}`);
  }
}

// Wall-clock minute (0-59) in `tz`. Computed in the family timezone so the
// gate is correct even on a UTC gateway.
function minuteInTz(now, tz) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    minute: "2-digit",
  }).formatToParts(now);
  const m = parts.find((p) => p.type === "minute");
  return m ? parseInt(m.value, 10) : now.getMinutes();
}

// True in the first 5 minutes of each quarter hour — one 5-min runner tick per
// 15 min. Exported for tests.
function inSportsWindow(minute) {
  return minute % 15 < 5;
}

async function readTrimmed(readFile, path) {
  return (await readFile(path, "utf8")).trim();
}

// One followed team's scoreboard. Host-pinned + redirect:"error" so a steered
// response can't move the GET off site.api.espn.com.
async function fetchScoreboard(fetchImpl, sport, league) {
  const url = `${ESPN_BASE}apis/site/v2/sports/${sport}/${league}/scoreboard`;
  const resp = await fetchImpl(url, { redirect: "error" });
  if (!resp.ok) throw new Error(`ESPN ${sport}/${league} ${resp.status}`);
  return resp.json();
}

async function postKiosk(fetchImpl, dashUrl, dashToken, text) {
  // The Pi backend rides the household LAN/tailnet, not the public internet —
  // http:// is an accepted trade-off for that trust zone.
  if (!dashUrl.startsWith("http://") && !dashUrl.startsWith("https://")) {
    throw new Error("kiosk POST: dashboard URL must be http(s)://");
  }
  const resp = await fetchImpl(dashUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${dashToken}`, "Content-Type": "application/json" },
    redirect: "error", // never forward the bearer to a 3xx target
    body: JSON.stringify({ card: "5", type: "sports", text }),
  });
  if (!resp.ok) throw new Error(`kiosk POST ${resp.status}`);
}

// Testable seam: pass now/fetch/readFile/config and dashUrl/dashToken.
// opts.force bypasses the gate; opts.dryRun composes but does not POST.
// Returns { gated } | { posted, text } | { dryRun, text }.
async function run(opts = {}) {
  const now = opts.now ?? new Date();
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  const readFile = opts.readFile ?? fs.readFile;

  const config = opts.config ?? JSON.parse(await readFile(LD_CONFIG_PATH, "utf8"));
  const timezone = config?.family?.timezone;
  if (typeof timezone !== "string" || timezone.length === 0) {
    throw new Error("ld-sports: family.timezone missing in /config/runtime/ld/config.json");
  }

  // Self-gate: one run per quarter hour. Manual runs (--force/--dry-run) bypass.
  if (!opts.force && !opts.dryRun && !inSportsWindow(minuteInTz(now, timezone))) {
    return { gated: true };
  }

  const followed = config?.sports?.followed;
  if (!Array.isArray(followed) || followed.length === 0) {
    throw new Error("ld-sports: sports.followed missing or empty in /config/runtime/ld/config.json");
  }

  // Fetch each followed team's scoreboard and keep whatever game each followed
  // team has today — live, upcoming, or final (a team idle today simply
  // contributes no row). A single feed hiccup is logged and skipped — one bad
  // team shouldn't blank the whole tile.
  const games = [];
  for (const f of followed) {
    try {
      const sb = await fetchScoreboard(fetchImpl, f.sport, f.league);
      const g = parseGameFor(sb, f.abbr, timezone, now);
      if (g) games.push(g);
    } catch (err) {
      log("team_skipped", { abbr: f.abbr, error: String((err && err.message) || err) });
    }
  }
  const text = composeSports(games);

  if (opts.dryRun) {
    log("dry_run", { games: games.length });
    return { dryRun: true, text };
  }

  const dashUrl = opts.dashUrl ?? (await readTrimmed(readFile, DASH_URL_PATH));
  const dashToken = opts.dashToken ?? (await readTrimmed(readFile, DASH_TOKEN_PATH));
  await postKiosk(fetchImpl, dashUrl, dashToken, text);
  log("sports_posted", { games: games.length });
  return { posted: true, text };
}

module.exports = { run, inSportsWindow };

// When spawned by the runner (not require()'d by a test), execute once. Any CLI
// flag bypasses the self-gate so an operator can test off-cadence; the
// unattended runner passes no flags and stays gated to the quarter hour.
if (require.main === module) {
  const dryRun = process.argv.includes("--dry-run");
  const force = dryRun || process.argv.includes("--force");
  run({ dryRun, force })
    .then((r) => {
      if (r && r.dryRun) console.log(r.text);
    })
    .catch((err) => {
      log("run_failed", { error: String((err && err.message) || err) });
      process.exitCode = 1;
    });
}
