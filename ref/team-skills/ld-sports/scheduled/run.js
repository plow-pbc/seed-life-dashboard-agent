"use strict";

// ld-sports — scheduled entrypoint, run by the generic plow-scheduled-runner
// (which spawns this `run.js` on every ~5-min poll tick). Mirrors ld-weather's
// Pattern-B shape: a deterministic scheduled job (no LLM), config + secrets from
// the /config mount, a host-pinned public fetch, and a card-keyed kiosk POST.
//
// When it runs: resolve the followed teams from config, fetch the ESPN public
// scoreboard for each distinct league, compose the generic tile-spec
// (compose.js), and post it to the kiosk as card 5 / type:sports. No self-gate:
// unlike weather (hourly), scores want to refresh every tick while games are on,
// and ESPN's public scoreboard is cheap + key-free. Posting nothing when there
// are no followed games keeps the kiosk's quiet placeholder (never fake data).
//
// Config + secrets (written by plowd):
//   /config/runtime/ld/config.json        — family.timezone, sports.followed[]
//   /config/secrets/dashboard-endpoint-url — kiosk endpoint
//   /config/secrets/dashboard-token        — kiosk bearer

const fs = require("node:fs/promises");
const { composeSports } = require("./compose.js");
const { makeLogger, readTrimmed, postKiosk } = require("../../ld-shared/scheduled/kiosk.js");

const log = makeLogger("ld-sports");

const LD_CONFIG_PATH = "/config/runtime/ld/config.json";
const DASH_URL_PATH = "/config/secrets/dashboard-endpoint-url";
const DASH_TOKEN_PATH = "/config/secrets/dashboard-token";

// The card-keyed live store needs {card, type, text}; sports lands on card 5.
const SPORTS_CARD = "5";

// ESPN's public scoreboard is host-pinned (combined with redirect:"error") so a
// malformed/compromised response can't steer an outbound GET elsewhere.
const ESPN_BASE = "https://site.api.espn.com/";

// League token → ESPN <sport>/<league> path. The followed-team `league` field
// uses these tokens (matching the kiosk's sport vocabulary).
const ESPN_PATHS = {
  mlb: "baseball/mlb",
  nba: "basketball/nba",
  wnba: "basketball/wnba",
  nfl: "football/nfl",
  nhl: "hockey/nhl",
  epl: "soccer/eng.1",
};

// DEMO DEFAULT followed set (June, in-season → real games): SF Giants, LA
// Dodgers, Golden State Warriors. Replace `sports.followed` in config to
// customize — each entry is { abbr (ESPN team abbreviation), league }.
const DEFAULT_FOLLOWED = [
  { abbr: "SF", league: "mlb" },
  { abbr: "LAD", league: "mlb" },
  { abbr: "GS", league: "nba" },
];

async function fetchScoreboard(fetchImpl, sportPath) {
  const url = `${ESPN_BASE}apis/site/v2/sports/${sportPath}/scoreboard`;
  const resp = await fetchImpl(url, {
    headers: { Accept: "application/json" },
    redirect: "error", // stay on site.api.espn.com; never follow a 3xx elsewhere
  });
  if (!resp.ok) throw new Error(`ESPN ${sportPath} ${resp.status}`);
  return resp.json();
}

// Testable seam: pass now/fetch/readFile/config and dashUrl/dashToken.
// opts.dryRun composes but does not POST. Returns { posted, text } | { dryRun,
// text } | { empty } (no followed games → nothing posted).
async function run(opts = {}) {
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  const readFile = opts.readFile ?? fs.readFile;

  const config = opts.config ?? JSON.parse(await readFile(LD_CONFIG_PATH, "utf8"));
  const timezone = config?.family?.timezone;
  if (typeof timezone !== "string" || timezone.length === 0) {
    throw new Error("ld-sports: family.timezone missing in /config/runtime/ld/config.json");
  }
  // Default ONLY when `sports.followed` is absent/non-array — an explicit empty
  // array means "follow no teams" (keep the quiet placeholder), not "use demo".
  const followed = Array.isArray(config?.sports?.followed)
    ? config.sports.followed
    : DEFAULT_FOLLOWED;

  // Fetch each DISTINCT league once (multiple followed teams can share a league).
  // Fail loud on an unsupported league token rather than silently dropping it
  // (a real config typo would otherwise render a partial card / placeholder).
  const leagues = [...new Set(followed.map((f) => f.league))];
  for (const l of leagues) {
    if (!ESPN_PATHS[l]) throw new Error(`ld-sports: unsupported league "${l}" in sports.followed`);
  }
  const scoreboards = {};
  await Promise.all(
    leagues.map(async (league) => {
      scoreboards[league] = await fetchScoreboard(fetchImpl, ESPN_PATHS[league]);
    }),
  );

  const spec = composeSports(followed, scoreboards, timezone);
  if (!spec) {
    log("no_games"); // no followed games right now — leave the quiet placeholder
    return { empty: true };
  }
  const text = JSON.stringify(spec);

  if (opts.dryRun) {
    log("dry_run");
    return { dryRun: true, text };
  }

  const dashUrl = opts.dashUrl ?? (await readTrimmed(readFile, DASH_URL_PATH));
  const dashToken = opts.dashToken ?? (await readTrimmed(readFile, DASH_TOKEN_PATH));
  await postKiosk(fetchImpl, dashUrl, dashToken, SPORTS_CARD, "sports", text);
  log("sports_posted", { games: spec.rows.length });
  return { posted: true, text };
}

module.exports = { run, DEFAULT_FOLLOWED, ESPN_PATHS };

// When spawned by the runner (not require()'d by a test), execute once.
// --dry-run composes + prints without POSTing; the unattended runner passes no
// flags and posts every tick.
if (require.main === module) {
  const dryRun = process.argv.includes("--dry-run");
  run({ dryRun })
    .then((r) => {
      if (r && r.dryRun) console.log(r.text);
    })
    .catch((err) => {
      log("run_failed", { error: String((err && err.message) || err) });
      process.exitCode = 1;
    });
}
