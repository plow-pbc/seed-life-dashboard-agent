"use strict";

// ld-shared/scheduled/kiosk.js — the shared idioms every Pattern-B scheduled
// runner (ld-calendar-nudge, ld-weather, ld-sports) uses to talk to the kiosk.
//
// Cross-bundle require resolves the same way the Python wrapper scripts already
// import ld-shared at runtime (ld-morning-*/scripts/post_*.py do
// `../../ld-shared/scripts`): plowd installs every ld-* bundle as a sibling
// under one skills root, so `../../ld-shared/scheduled/kiosk.js` resolves both
// in the installed tree and under `node --test` from a scheduled/ dir.

// Tag-bound logger: `makeLogger("ld-weather")` returns the runner's `log`.
function makeLogger(tag) {
  return function log(message, fields) {
    try {
      console.error(`[${tag}] ${message}${fields ? " " + JSON.stringify(fields) : ""}`);
    } catch {
      console.error(`[${tag}] ${message}`);
    }
  };
}

async function readTrimmed(readFile, path) {
  return (await readFile(path, "utf8")).trim();
}

// Wall-clock minute (0-59) in `tz`. Used by the hourly/half-hour self-gates;
// computed in the family timezone so the cadence is correct on a UTC gateway.
function minuteInTz(now, tz) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    minute: "2-digit",
  }).formatToParts(now);
  const m = parts.find((p) => p.type === "minute");
  return m ? parseInt(m.value, 10) : now.getMinutes();
}

// POST {card, type, text} to the kiosk. The Pi backend rides the household
// LAN/tailnet, not the public internet — http:// is an accepted trade-off for
// that trust zone. redirect:"error" so the bearer is never forwarded to a 3xx
// target.
async function postKiosk(fetchImpl, dashUrl, dashToken, card, type, text) {
  if (!dashUrl.startsWith("http://") && !dashUrl.startsWith("https://")) {
    throw new Error("kiosk POST: dashboard URL must be http(s)://");
  }
  const resp = await fetchImpl(dashUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${dashToken}`, "Content-Type": "application/json" },
    redirect: "error",
    body: JSON.stringify({ card, type, text }),
  });
  if (!resp.ok) throw new Error(`kiosk POST ${resp.status}`);
}

module.exports = { makeLogger, readTrimmed, minuteInTz, postKiosk };
