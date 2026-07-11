"use strict";

// ld-weather — scheduled entrypoint, run by the generic plow-scheduled-runner
// (which spawns this `run.js` on every ~5-min poll tick).
//
// This is opt-in (d) code: it ships in the ld-weather bundle and is installed
// into the read-only /scheduled mount only when a household runs this SEED's
// install (which POSTs the bundle to plowd's install-local-bundles endpoint).
// It does NOT ship with Plow.
//
// SELF-GATING: the runner ticks every ~5 min, but weather refreshes hourly.
// This script does the NWS fetch + post only when the wall-clock minute (in
// family.timezone) is in [0,5) — one tick per hour — and exits 0 immediately
// otherwise. (Window width = the runner's 5-min interval, so exactly one tick
// lands in the window each hour.)
//
// When it runs: resolve the NWS gridpoint from weather.lat/lon, fetch the
// hourly + daily forecast, compose one glanceable line (compose.js), and post
// it to the kiosk as card 3 / type:weather (the viewer requires all three of
// card/type/text; type renders verbatim as the card's eyebrow). No LLM,
// deterministic. No iMessage — weather is an ambient card, not a notification.
//
// Config + secrets are read from the /config mount (all written by plowd):
//   /config/runtime/ld/config.json        — family.timezone, weather.{location,lat,lon}
//   /config/secrets/dashboard-endpoint-url — kiosk endpoint
//   /config/secrets/dashboard-token        — kiosk bearer

const fs = require("node:fs/promises");
const { composeWeather } = require("./compose.js");
const {
  minuteInTz,
  makeLog,
  loadLdConfig,
  postKioskCard,
} = require("./ld-runtime.js");

// NWS requires a User-Agent identifying the caller (with contact) or returns
// 403. Use the repo URL as the contact — no PII.
const NWS_USER_AGENT =
  "seed-life-dashboard ld-weather (https://github.com/plow-pbc/seed-life-dashboard-agent)";

// /points returns the next two fetch targets (forecast + forecastHourly); pin
// them to the NWS host so a malformed/compromised response can't steer an
// outbound GET elsewhere. Combined with redirect:"error" on every NWS fetch,
// the runner only ever talks to api.weather.gov.
const NWS_BASE = "https://api.weather.gov/";

const log = makeLog("ld-weather");

// True only in the [0,5) window — one 5-min runner tick per hour. Exported
// for tests.
function inWeatherWindow(minute) {
  return minute < 5;
}

async function fetchJson(fetchImpl, url, label) {
  const resp = await fetchImpl(url, {
    headers: { "User-Agent": NWS_USER_AGENT, Accept: "application/geo+json" },
    redirect: "error", // stay on api.weather.gov; never follow a 3xx elsewhere
  });
  if (!resp.ok) throw new Error(`${label} ${resp.status}`);
  return resp.json();
}

// Resolve the NWS daily + hourly forecast URLs for a lat/lon. Gridpoints are
// stable per location, but resolving at runtime keeps config as plain lat/lon
// (no magic office/gridpoint strings to hardcode).
async function resolveForecastUrls(fetchImpl, lat, lon) {
  const points = await fetchJson(
    fetchImpl,
    `https://api.weather.gov/points/${lat},${lon}`,
    "NWS points",
  );
  const daily = points?.properties?.forecast;
  const hourly = points?.properties?.forecastHourly;
  if (typeof daily !== "string" || typeof hourly !== "string") {
    throw new Error("NWS points: missing forecast URLs");
  }
  if (!daily.startsWith(NWS_BASE) || !hourly.startsWith(NWS_BASE)) {
    throw new Error("NWS points: forecast URLs are off-host");
  }
  return { daily, hourly };
}

// Testable seam: pass now/fetch/readFile/config and dashUrl/dashToken.
// opts.force bypasses the hourly gate; opts.dryRun composes but does not POST.
// Returns { gated } | { posted, text } | { dryRun, text }.
async function run(opts = {}) {
  const now = opts.now ?? new Date();
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  const readFile = opts.readFile ?? fs.readFile;

  const { config, timezone } = await loadLdConfig(readFile, opts);

  // Self-gate: one run per hour. Manual runs (--force/--dry-run) bypass it.
  if (!opts.force && !opts.dryRun && !inWeatherWindow(minuteInTz(now, timezone))) {
    return { gated: true };
  }

  const weather = config?.weather ?? {};
  const { location, lat, lon } = weather;
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    throw new Error("ld-weather: weather.lat/lon missing or non-numeric in /config/runtime/ld/config.json");
  }

  const { daily, hourly } = await resolveForecastUrls(fetchImpl, lat, lon);
  const [hourlyBody, dailyBody] = await Promise.all([
    fetchJson(fetchImpl, hourly, "NWS hourly"),
    fetchJson(fetchImpl, daily, "NWS daily"),
  ]);
  const text = composeWeather(location, hourlyBody, dailyBody);

  if (opts.dryRun) {
    // Body-free stderr; the manual-run path (require.main) prints the line to
    // stdout for the operator. Keeps household location out of runner logs.
    log("dry_run");
    return { dryRun: true, text };
  }

  // Best-effort kiosk post: an offline Pi logs + returns false, never crashes the runner.
  const posted = await postKioskCard(fetchImpl, readFile, text, { card: "3", type: "weather" }, log, opts);
  log(posted ? "weather_posted" : "kiosk_offline"); // body-free — the card text carries household location
  return { posted, text };
}

module.exports = { run, inWeatherWindow };

// When spawned by the runner (not require()'d by a test), execute once. Any
// CLI flag bypasses the hourly self-gate so an operator can test off-cadence;
// the unattended runner passes no flags and stays gated to the top of the hour.
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
