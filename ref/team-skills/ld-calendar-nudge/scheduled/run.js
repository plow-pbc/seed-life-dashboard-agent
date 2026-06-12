"use strict";

// ld-calendar-nudge — scheduled entrypoint, run by the generic
// plow-scheduled-runner (which spawns this `run.js` on every poll tick).
//
// This is opt-in (d) code: it ships in the ld-calendar-nudge bundle and is
// installed into the read-only /scheduled mount only when a household runs
// this SEED's install (which POSTs the bundle to plowd's
// install-local-bundles endpoint). It does NOT ship with Plow.
//
// SELF-GATING: the runner ticks every ~5 min, but the nudge cadence is
// :20 / :50 (10 min before each hour and half-hour). This script gates
// itself: it does the calendar check only when the wall-clock minute (in
// family.timezone) is in the [20,25) or [50,55) window — i.e. one tick per
// half-hour — and exits 0 immediately otherwise. (Window width = the
// runner's 5-min interval, so exactly one tick lands in each window.)
//
// When it does run: fetch the calendar, filter to qualifying meetings
// (filter.js, mirrors SKILL.md §Filter/§Dedupe), and if ≥1 qualifies post
// a reminder to the kiosk + iMessage (compose.js). Zero qualifying → exit
// 0 silently. No LLM, deterministic.
//
// Config + secrets are read from the /config mount (all written by plowd):
//   /config/runtime/ld/config.json      — family tz, calendar.sources, lookaheads
//   /config/gateway/plow-api-url         — Plow API base URL (in-VM reachable)
//   /config/secrets/plow-api-token       — bearer for calendar fetch + iMessage send
//   /config/secrets/dashboard-endpoint-url — kiosk endpoint
//   /config/secrets/dashboard-token      — kiosk bearer

const fs = require("node:fs/promises");

const { qualifyingEvents } = require("./filter.js");
const { composeReminder } = require("./compose.js");

const LD_CONFIG_PATH = "/config/runtime/ld/config.json";
const API_URL_PATH = "/config/gateway/plow-api-url";
const API_TOKEN_PATH = "/config/secrets/plow-api-token";
const DASH_URL_PATH = "/config/secrets/dashboard-endpoint-url";
const DASH_TOKEN_PATH = "/config/secrets/dashboard-token";

// Resolve the card slot from config, matching post_to_kiosk.py::_resolve_card semantics:
//   absent/null at any level of dashboard / card_targets / per-type key → defaultCard
//   present but non-object dashboard or card_targets → throw (misconfigured node)
//   present per-type value that isn't a non-empty-trimmed string → throw (misconfigured key)
function resolveCard(config, type, defaultCard) {
  const dashboard = config != null ? config.dashboard : undefined;
  if (dashboard === undefined || dashboard === null) return defaultCard;
  if (typeof dashboard !== "object" || Array.isArray(dashboard)) {
    throw new Error(`dashboard in config must be an object`);
  }
  const cardTargets = dashboard.card_targets;
  if (cardTargets === undefined || cardTargets === null) return defaultCard;
  if (typeof cardTargets !== "object" || Array.isArray(cardTargets)) {
    throw new Error(`dashboard.card_targets in config must be an object`);
  }
  const raw = cardTargets[type];
  if (raw === undefined || raw === null) return defaultCard;
  if (typeof raw !== "string" || !raw.trim()) {
    throw new Error(`dashboard.card_targets.${type} in config must be a non-empty string`);
  }
  return raw.trim();
}

function log(message, fields) {
  try {
    console.error(`[ld-calendar-nudge] ${message}${fields ? " " + JSON.stringify(fields) : ""}`);
  } catch {
    console.error(`[ld-calendar-nudge] ${message}`);
  }
}

// Wall-clock minute (0-59) in `tz`. Used by the self-gate; computed in the
// family timezone so the :20/:50 cadence is correct even on a UTC gateway.
function minuteInTz(now, tz) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    minute: "2-digit",
  }).formatToParts(now);
  const m = parts.find((p) => p.type === "minute");
  return m ? parseInt(m.value, 10) : now.getMinutes();
}

// True only in the [20,25) / [50,55) windows — one 5-min slot per half hour.
// `minute % 30` folds :20 and :50 to the same 20-29 band; [20,25) is the
// nudge slot. Exported for tests.
function inNudgeWindow(minute) {
  const slot = minute % 30;
  return slot >= 20 && slot < 25;
}

async function readTrimmed(readFile, path) {
  return (await readFile(path, "utf8")).trim();
}

async function fetchEvents(fetchImpl, apiUrl, apiToken, source, timeMin, timeMax) {
  const url = `${apiUrl}/v1/connectors/gmail/calendar.events.list`;
  const resp = await fetchImpl(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      account: source.account,
      calendar_id: source.calendar_id,
      time_min: timeMin,
      time_max: timeMax,
      max_results: 50,
    }),
  });
  // Prefer the operator label; never interpolate raw account/calendar_id
  // (they can leak through logs into shared diagnostics bundles).
  const label = typeof source.name === "string" && source.name.length > 0 ? ` (${source.name})` : "";
  if (!resp.ok) {
    throw new Error(`calendar.events.list ${resp.status}${label}`);
  }
  const body = await resp.json();
  // Fail loud on a malformed 2xx — a typed { data: { items: [] } } is the
  // contract; a missing/wrong-typed items would otherwise surface as an
  // opaque TypeError in the spread below.
  const items = body?.data?.items;
  if (!Array.isArray(items)) {
    throw new Error(`calendar.events.list malformed response${label}`);
  }
  return items;
}

async function postKiosk(fetchImpl, dashUrl, dashToken, card, text) {
  // The Pi backend rides the household LAN/tailnet, not the public internet —
  // http:// is an accepted trade-off for that trust zone.
  if (!dashUrl.startsWith("http://") && !dashUrl.startsWith("https://")) {
    throw new Error("kiosk POST: dashboard URL must be http(s)://");
  }
  const resp = await fetchImpl(dashUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${dashToken}`, "Content-Type": "application/json" },
    redirect: "error", // never forward the bearer to a 3xx target
    body: JSON.stringify({ card, type: "nudge", text }),
  });
  if (!resp.ok) throw new Error(`kiosk POST ${resp.status}`);
}

async function postImessage(fetchImpl, apiUrl, apiToken, text) {
  const resp = await fetchImpl(`${apiUrl}/channels/linq/send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiToken}`, "Content-Type": "application/json" },
    // `to` is required by the schema but ignored server-side — the server
    // resolves the recipient to the authenticated user's own LinQ phone.
    body: JSON.stringify({ to: "owner", text }),
  });
  if (!resp.ok) throw new Error(`channels/linq/send ${resp.status}`);
}

// Testable seam: pass `now`, `fetch`, `readFile`, and optionally `config`.
// Returns { gated } | { sent, count }.
async function run(opts = {}) {
  const now = opts.now ?? new Date();
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  const readFile = opts.readFile ?? fs.readFile;

  const config = opts.config ?? JSON.parse(await readFile(LD_CONFIG_PATH, "utf8"));
  const timezone = config?.family?.timezone;
  if (typeof timezone !== "string" || timezone.length === 0) {
    throw new Error("ld-calendar-nudge: family.timezone missing in /config/runtime/ld/config.json");
  }

  // Self-gate: only one tick per half hour does real work.
  if (!inNudgeWindow(minuteInTz(now, timezone))) {
    return { gated: true };
  }

  const sources = config?.calendar?.sources;
  if (!Array.isArray(sources) || sources.length === 0) {
    throw new Error("ld-calendar-nudge: calendar.sources missing or empty");
  }
  for (let i = 0; i < sources.length; i++) {
    const s = sources[i];
    if (typeof s?.account !== "string" || !s.account || typeof s?.calendar_id !== "string" || !s.calendar_id) {
      throw new Error(`ld-calendar-nudge: calendar.sources[${i}] must have non-empty 'account' and 'calendar_id'`);
    }
  }
  const nudge = config?.calendar_nudge ?? {};
  const virtualLookahead = nudge.lookahead_virtual_minutes;
  const inPersonLookahead = nudge.lookahead_in_person_minutes;
  if (!Number.isFinite(virtualLookahead) || !Number.isFinite(inPersonLookahead)) {
    throw new Error("ld-calendar-nudge: calendar_nudge lookahead minutes missing/invalid");
  }
  const userIdentities = new Set(sources.filter((s) => s.self !== false).map((s) => s.account));
  if (userIdentities.size === 0) {
    throw new Error("ld-calendar-nudge: no owner identities — every calendar.sources entry is self:false");
  }

  const apiUrl = opts.apiUrl ?? (await readTrimmed(readFile, API_URL_PATH));
  const apiToken = opts.apiToken ?? (await readTrimmed(readFile, API_TOKEN_PATH));

  const horizonMin = Math.max(virtualLookahead, inPersonLookahead);
  const timeMin = now.toISOString();
  const timeMax = new Date(now.getTime() + horizonMin * 60_000).toISOString();

  const events = [];
  for (const src of sources) {
    const data = await fetchEvents(fetchImpl, apiUrl, apiToken, src, timeMin, timeMax);
    events.push(...data);
  }

  const qualifying = qualifyingEvents(events, { now, userIdentities, virtualLookahead, inPersonLookahead });
  if (qualifying.length === 0) {
    log("quiet_tick");
    return { sent: false, count: 0 };
  }

  const text = composeReminder(qualifying, { timezone });

  // Resolve card slot — fail-loud semantics matching _resolve_card in post_to_kiosk.py:
  // absent/null at any level → fall back to default "2"; present non-null non-string
  // or present blank string → throw (misconfigured key must not silently misroute).
  const card = resolveCard(config, "nudge", "2");

  const dashUrl = opts.dashUrl ?? (await readTrimmed(readFile, DASH_URL_PATH));
  const dashToken = opts.dashToken ?? (await readTrimmed(readFile, DASH_TOKEN_PATH));

  // Kiosk first; on a failed kiosk post, surface and stop (don't iMessage).
  await postKiosk(fetchImpl, dashUrl, dashToken, card, text);
  await postImessage(fetchImpl, apiUrl, apiToken, text);
  log("nudge_sent", { count: qualifying.length });
  return { sent: true, count: qualifying.length };
}

module.exports = { run, inNudgeWindow };

// When spawned by the runner (not require()'d by a test), execute once.
if (require.main === module) {
  run().catch((err) => {
    log("run_failed", { error: String((err && err.message) || err) });
    process.exitCode = 1;
  });
}
