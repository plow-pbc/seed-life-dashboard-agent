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
const {
  minuteInTz,
  readTrimmed,
  postKiosk,
  LD_CONFIG_PATH,
  DASH_URL_PATH,
  DASH_TOKEN_PATH,
} = require("../../ld-shared/scripts/ld-runtime.js");

// Pin every scoreboard GET to the ESPN public host so a malformed/compromised
// response can't steer an outbound GET elsewhere. Combined with redirect:"error"
// the runner only ever talks to site.api.espn.com.
const ESPN_BASE = "https://site.api.espn.com/";

function log(message, fields) {
  try {
    console.error(`[ld-sports] ${message}${fields ? " " + JSON.stringify(fields) : ""}`);
  } catch {
    console.error(`[ld-sports] ${message}`);
  }
}

// True in the first 5 minutes of each quarter hour — one 5-min runner tick per
// 15 min. Exported for tests.
function inSportsWindow(minute) {
  return minute % 15 < 5;
}

// One followed team's scoreboard. Host-pinned + redirect:"error" so a steered
// response can't move the GET off site.api.espn.com.
async function fetchScoreboard(fetchImpl, sport, league) {
  const url = `${ESPN_BASE}apis/site/v2/sports/${sport}/${league}/scoreboard`;
  const resp = await fetchImpl(url, { redirect: "error" });
  if (!resp.ok) throw new Error(`ESPN ${sport}/${league} ${resp.status}`);
  return resp.json();
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

  // Fetch each followed team's scoreboard and keep whatever game it has today —
  // live, upcoming, or final (a team idle today contributes no row), deduped by
  // game key so two followed teams in the same matchup (SF + LAD) yield one row,
  // not two. A single feed hiccup is logged and skipped — one bad team shouldn't
  // blank the whole tile.
  const byKey = new Map();
  for (const f of followed) {
    try {
      const sb = await fetchScoreboard(fetchImpl, f.sport, f.league);
      const g = parseGameFor(sb, f.abbr, timezone, now);
      if (!g) continue;
      if (!byKey.has(g.key)) byKey.set(g.key, g);
    } catch (err) {
      log("team_skipped", { abbr: f.abbr, error: String((err && err.message) || err) });
    }
  }
  const games = [...byKey.values()];
  const text = composeSports(games);

  if (opts.dryRun) {
    log("dry_run", { games: games.length });
    return { dryRun: true, text };
  }

  const dashUrl = opts.dashUrl ?? (await readTrimmed(readFile, DASH_URL_PATH));
  const dashToken = opts.dashToken ?? (await readTrimmed(readFile, DASH_TOKEN_PATH));
  await postKiosk(fetchImpl, dashUrl, dashToken, text, { card: "5", type: "sports" });
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
