"use strict";

// Pure ESPN-scoreboard parser for ld-sports (Pattern B — runs under the generic
// plow-scheduled-runner via run.js). No HTTP, no FS, no clock by default:
// run.js fetches each followed team's scoreboard JSON and passes it here. This
// module + compose.js are the SINGLE source of truth for the sports transform —
// SKILL.md does not restate it.

// ESPN status.type.state → our render-ready game state.
const STATE = { pre: "upcoming", in: "live", post: "final" };

// Only surface upcoming games within this window — a followed team whose next
// game is further out (an off-season fixture months away, e.g. an NFL team in
// June) contributes no row, so the tile stays current instead of teasing a game
// nobody's watching for. Live/final games are "today" and always pass.
const UPCOMING_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;

// Normalize a team color to "#RRGGBB" (uppercased) or null. ESPN omits the "#".
function hexColor(v) {
  if (typeof v !== "string") return null;
  const h = v.trim().replace(/^#/, "");
  return /^[0-9a-fA-F]{6}$/.test(h) ? `#${h.toUpperCase()}` : null;
}

// A feed-supplied logo URL is UNTRUSTED data emitted as <img src> on the kiosk:
// accept only HTTPS on an ESPN CDN host, else null (monogram fallback). This
// stops a steered feed from driving the kiosk browser to fetch an arbitrary
// host despite the scoreboard fetch itself being host-pinned in run.js.
function safeLogo(url) {
  if (typeof url !== "string") return null;
  let host;
  try {
    const u = new URL(url);
    if (u.protocol !== "https:") return null;
    host = u.hostname.toLowerCase();
  } catch {
    return null;
  }
  return host === "espncdn.com" || host.endsWith(".espncdn.com") ? url : null;
}

// One competitor → a render-ready side. Logo only via the ESPN-CDN allowlist;
// colors fall back to neutral so the monogram never renders an empty swatch.
function sideOf(competitor) {
  const t = competitor.team || {};
  const score = competitor.score != null && competitor.score !== "" ? Number(competitor.score) : null;
  return {
    abbr: t.abbreviation || "?",
    name: t.displayName || t.abbreviation || "?",
    logo: safeLogo(t.logo),
    colors: { primary: hexColor(t.color) || "#6B7280", secondary: hexColor(t.alternateColor) || "#FFFFFF" },
    score: Number.isFinite(score) ? score : null,
  };
}

// Calendar day (YYYY-MM-DD) of `date` as it falls in `tz`. Used so the
// "different day?" comparison and the rendered clock are both in the household
// zone, not the runner's system zone (correct even on a UTC gateway).
function dayKeyInTz(date, tz) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

// Find the event whose competitor abbr matches `abbr`, build a render-ready
// game (away/home oriented by ESPN's homeAway), or null if the followed team
// has no game in this scoreboard. `tz` is the household timezone (family.timezone):
// the tip-off clock and the weekday label both resolve in it so the kiosk shows
// the right local time even when the runner's system zone differs. `now` only
// decides whether to show a weekday label (kickoff on a different calendar day).
function parseGameFor(scoreboard, abbr, tz, now = new Date()) {
  const want = String(abbr).toUpperCase();
  const events = Array.isArray(scoreboard?.events) ? scoreboard.events : [];
  for (const ev of events) {
    const comp = ev?.competitions?.[0];
    if (!comp || !Array.isArray(comp.competitors)) continue;
    const mine = comp.competitors.find((c) => (c.team?.abbreviation || "").toUpperCase() === want);
    if (!mine) continue;
    const other = comp.competitors.find((c) => c !== mine);
    if (!other) continue;
    const state = STATE[comp.status?.type?.state] || "upcoming";
    const mineSide = sideOf(mine);
    const opp = sideOf(other);
    const homeAway = (mine.homeAway || "").toLowerCase();
    const away = homeAway === "home" ? opp : mineSide;
    const home = homeAway === "home" ? mineSide : opp;
    const d = new Date(ev.date);
    const valid = !Number.isNaN(d.getTime());
    // Skip an upcoming game beyond the 14-day window; keep scanning this team's
    // scoreboard in case a nearer game exists.
    if (state === "upcoming" && valid && d.getTime() - now.getTime() > UPCOMING_WINDOW_MS) continue;
    // Stable key so two followed teams in the same matchup (SF + LAD) dedupe to
    // one row. ESPN event id when present, else the orientation-stable matchup.
    const key = ev.id != null ? `id:${ev.id}` : `mu:${ev.date}|${away.abbr}@${home.abbr}`;
    return {
      key,
      state,
      away,
      home,
      status: comp.status?.type?.shortDetail || "",
      timeLabel: valid ? new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(d) : "",
      dayLabel:
        valid && dayKeyInTz(d, tz) !== dayKeyInTz(now, tz)
          ? new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short" }).format(d)
          : "",
    };
  }
  return null;
}

module.exports = { parseGameFor, sideOf, hexColor };
