"use strict";

// Pure weather composer for ld-weather (Pattern B — runs under the generic
// plow-scheduled-runner via run.js). No HTTP, no FS, no clock: run.js fetches
// the NWS forecast bodies and passes them here. This module is the SINGLE
// source of truth for the weather tile HTML the kiosk renders verbatim
// (dangerouslySetInnerHTML) — SKILL.md does not restate the transform. The HTML
// is SELF-CONTAINED: it ships its own <style>, so the viewer carries no
// .weather-* CSS.

// Minimal HTML escape for the few text fields we interpolate (location,
// condition). Not a security boundary — the writer is trusted, bearer-gated,
// loopback-read — just keeps a stray "&"/"<" in a feed from breaking the
// fragment.
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

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

// Build the weather tile the kiosk renders verbatim: a big current temp + the
// condition, with the location and the day's H/L beneath. A blank/absent
// location renders an empty meta slot (no stray separator).
// The widget OWNS its styling: this <style> rides inside the posted HTML so the
// viewer needs zero .weather-* CSS. Rules reference only the viewer's shared
// theme tokens (--ink / --faint / fonts / cap-* type tokens).
const WEATHER_STYLE = `<style>
.weather{display:flex;flex-direction:column;gap:0.4rem;width:100%;min-height:0}
.weather-now{display:flex;align-items:baseline;gap:0.75rem}
.weather-temp{font-family:var(--ff-display);font-weight:400;font-size:2.4em;letter-spacing:-0.04em;line-height:0.82;color:var(--ink);font-variant-numeric:tabular-nums}
.weather-cond{font-family:var(--ff-body);font-weight:300;font-size:0.85em;color:var(--ink)}
.weather-meta{display:flex;justify-content:space-between;font-family:var(--ff-mono);font-weight:var(--cap-weight);font-size:var(--cap-size);letter-spacing:var(--cap-tracking);text-transform:uppercase;color:var(--faint)}
</style>`;

function formatWeather({ location, tempF, condition, highF, lowF }) {
  return (
    WEATHER_STYLE +
    `<div class="weather">` +
    `<div class="weather-now"><span class="weather-temp">${esc(tempF)}°</span>` +
    `<span class="weather-cond">${esc(condition)}</span></div>` +
    `<div class="weather-meta"><span>${esc(location || "")}</span>` +
    `<span>H${esc(highF)} · L${esc(lowF)}</span></div></div>`
  );
}

// Convenience: NWS bodies + location → the tile HTML.
function composeWeather(location, hourly, daily) {
  return formatWeather({ location, ...extractWeather(hourly, daily) });
}

module.exports = { composeWeather, extractWeather, formatWeather, shortCondition };
