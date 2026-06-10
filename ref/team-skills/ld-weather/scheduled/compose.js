"use strict";

// Pure weather composer for ld-weather (Pattern B — runs under the generic
// plow-scheduled-runner via run.js). No HTTP, no FS, no clock: run.js fetches
// the NWS forecast bodies and passes them here. This module is the SINGLE
// source of truth for the displayed line — SKILL.md does not restate the
// transform.

// NWS `shortForecast` can be a compound phrase like "Patchy Fog then Sunny".
// Keep the clause after the last " then " so the kiosk condition stays a
// glanceable word or two (the trailing clause is the prevailing condition).
function shortCondition(shortForecast) {
  const parts = String(shortForecast).split(" then ");
  return parts[parts.length - 1].trim();
}

// Extract the displayed fields from the NWS hourly + daily forecast bodies.
//   - current temp:           hourly periods[0].temperature
//   - today's high + condition: first daytime daily period
//   - today's low:            first nighttime daily period
// On an evening/overnight run today's daytime period has rolled off the daily
// feed, so the first daytime period is tomorrow's — acceptable for a
// glanceable kiosk (documented, not worked around). Fails loud on a malformed
// 2xx body so a bad feed surfaces as a clear error, not a "NaN°F" card.
function extractWeather(hourly, daily) {
  const cur = hourly?.properties?.periods?.[0];
  if (!cur || !Number.isFinite(cur.temperature)) {
    throw new Error("NWS hourly: missing current temperature");
  }
  const periods = daily?.properties?.periods;
  if (!Array.isArray(periods) || periods.length === 0) {
    throw new Error("NWS daily: no forecast periods");
  }
  const day = periods.find((p) => p.isDaytime === true);
  const night = periods.find((p) => p.isDaytime === false);
  if (!day || !Number.isFinite(day.temperature)) {
    throw new Error("NWS daily: no daytime high");
  }
  // Guard the condition the same way as the temperatures: a daytime period
  // without a string shortForecast would otherwise render "72°F undefined".
  if (typeof day.shortForecast !== "string" || !day.shortForecast.trim()) {
    throw new Error("NWS daily: missing condition");
  }
  if (!night || !Number.isFinite(night.temperature)) {
    throw new Error("NWS daily: no nighttime low");
  }
  return {
    tempF: Math.round(cur.temperature),
    highF: Math.round(day.temperature),
    lowF: Math.round(night.temperature),
    condition: shortCondition(day.shortForecast),
  };
}

// Format the one glanceable line the kiosk renders verbatim, e.g.
//   "Mountain View · 72°F Sunny · H77 L55"
// A blank/absent location drops the leading "<location> · " segment.
function formatWeather({ location, tempF, condition, highF, lowF }) {
  const head = location ? `${location} · ` : "";
  return `${head}${tempF}°F ${condition} · H${highF} L${lowF}`;
}

// Convenience: NWS bodies + location → the display line.
function composeWeather(location, hourly, daily) {
  return formatWeather({ location, ...extractWeather(hourly, daily) });
}

module.exports = { composeWeather, extractWeather, formatWeather, shortCondition };
