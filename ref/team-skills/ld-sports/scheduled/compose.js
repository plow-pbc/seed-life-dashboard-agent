"use strict";

// Pure sports composer for ld-sports (mirrors ld-weather/compose.js — Pattern B,
// runs under the generic plow-scheduled-runner via run.js). No HTTP, no FS, no
// clock: run.js fetches the ESPN scoreboard bodies and passes them here with the
// followed-team list. This module is the SINGLE source of truth for the tile —
// SKILL.md does not restate the transform.
//
// Output is the GENERIC tile-spec the kiosk renders (the same vocabulary weather
// uses; the viewer maps it with no per-type knowledge — see
// seed-life-dashboard-viewer ref/app/src/tilespec.ts). One stacked game row per
// followed team: away logo · score · center · score · home logo, the followed
// team starred and on the favored side, the losing score greyed, the center
// showing the game time (upcoming) / live status / "Final".

// ESPN status.type.state → our render state. Anything else is skipped.
function gameState(comp) {
  const s = comp?.status?.type?.state;
  return s === "pre" ? "upcoming" : s === "in" ? "live" : s === "post" ? "final" : null;
}

// ESPN `#rrggbb` (no leading hash) → our `#rrggbb`. Invalid → null (the viewer's
// monogram falls back to a neutral tint).
function color(hex) {
  return typeof hex === "string" && /^[0-9a-fA-F]{6}$/.test(hex) ? `#${hex}` : null;
}

// Build the per-team display side from one ESPN competitor.
function side(competitor) {
  const t = competitor?.team ?? {};
  const score = Number.parseInt(competitor?.score, 10);
  return {
    abbr: t.abbreviation ?? "?",
    color: color(t.color) ?? color(t.alternateColor),
    logo: typeof t.logo === "string" ? t.logo : null,
    score: Number.isFinite(score) ? score : null,
    homeAway: competitor?.homeAway,
  };
}

// The center cell text: upcoming = tip-off time (in tz); live = ESPN's short
// detail (e.g. "Top 5th", "Q3 7:42"); final = "Final".
function centerText(comp, state, tz) {
  if (state === "final") return "Final";
  if (state === "live") return comp?.status?.type?.shortDetail ?? "Live";
  const iso = comp?.date;
  const d = iso ? new Date(iso) : null;
  if (!d || Number.isNaN(d.getTime())) return "TBD";
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour: "numeric",
    minute: "2-digit",
  }).format(d);
}

// One ESPN event (competition) + the followed team's abbr → a tile-spec row.
// Returns null if the event doesn't involve the followed team or is in an
// unrenderable state, so a bad/irrelevant event never blanks the card.
function gameRow(comp, followedAbbr, tz) {
  const state = gameState(comp);
  if (!state) return null;
  const competitors = Array.isArray(comp?.competitors) ? comp.competitors : [];
  if (competitors.length !== 2) return null;
  const sides = competitors.map(side);
  const followedIdx = sides.findIndex((s) => s.abbr === followedAbbr);
  if (followedIdx === -1) return null;

  // away LEFT, home RIGHT (Apple layout) regardless of which is followed.
  const away = sides.find((s) => s.homeAway === "away") ?? sides[0];
  const home = sides.find((s) => s.homeAway === "home") ?? sides[1];
  const withScore = state !== "upcoming";
  const leader =
    withScore && away.score !== null && home.score !== null && away.score !== home.score
      ? away.score > home.score
        ? "away"
        : "home"
      : null;

  const logoCell = (s) => {
    const c = { kind: "logo", abbr: s.abbr };
    if (s.color) c.color = s.color;
    if (s.logo) c.logo = s.logo;
    if (s.abbr === followedAbbr) c.star = true;
    return c;
  };
  // Grey the loser: a side is dimmed when there IS a leader and it isn't this
  // side (a tie/upcoming → no leader → neither dimmed).
  const scoreCell = (s, sideName) => ({
    kind: "text",
    value: withScore && s.score !== null ? String(s.score) : "",
    variant: "score",
    ...(leader && leader !== sideName ? { dim: true } : {}),
  });

  return {
    top: true,
    cells: [
      logoCell(away),
      scoreCell(away, "away"),
      { kind: "stack", cells: [{ kind: "text", value: centerText(comp, state, tz), variant: "period" }] },
      scoreCell(home, "home"),
      logoCell(home),
    ],
  };
}

// ESPN nests status/date on the event; mirror onto the competition so
// gameState/centerText read one shape. Returns null when the event has no
// competition.
function competition(ev) {
  const comp = Array.isArray(ev?.competitions) ? ev.competitions[0] : null;
  return comp ? { ...comp, status: comp.status ?? ev.status, date: comp.date ?? ev.date } : null;
}

// Which of a team's events to show: prefer an in-progress game, then an upcoming
// one, then a final (ESPN's same-day slate isn't ordered by state, and a
// doubleheader can list a finished game ahead of a live one).
const STATE_RANK = { live: 0, upcoming: 1, final: 2 };
function pickEvent(events, abbr) {
  let best = null;
  for (const ev of Array.isArray(events) ? events : []) {
    const comp = competition(ev);
    const state = comp && gameState(comp);
    if (!state) continue;
    const involves = (Array.isArray(comp.competitors) ? comp.competitors : []).some(
      (c) => c?.team?.abbreviation === abbr,
    );
    if (!involves) continue;
    if (!best || STATE_RANK[state] < STATE_RANK[best.state]) best = { ev, comp, state };
  }
  return best;
}

// A stable per-event identity for de-duping a game two followed teams share
// (e.g. the SF/LAD demo set on a head-to-head day): the ESPN event id, or the
// unordered abbr pair as a fallback.
function eventKey(comp, evId) {
  if (evId != null) return String(evId);
  const abbrs = (Array.isArray(comp?.competitors) ? comp.competitors : [])
    .map((c) => c?.team?.abbreviation ?? "?")
    .sort();
  return abbrs.join("@");
}

// Given the followed-team list [{abbr, league}] and a map league→ESPN scoreboard
// body, build the full tile-spec — one row per distinct game, picking each
// team's best-state event and rendering a shared game only once. Empty → null so
// run.js posts nothing and the kiosk keeps its quiet placeholder (never fakes).
function composeSports(followed, scoreboards, tz) {
  const rows = [];
  const seen = new Set();
  for (const { abbr, league } of followed) {
    const best = pickEvent(scoreboards[league]?.events, abbr);
    if (!best) continue;
    const key = `${league}:${eventKey(best.comp, best.ev?.id)}`;
    if (seen.has(key)) continue; // a game both followed teams are in → one row
    const row = gameRow(best.comp, abbr, tz);
    if (row) {
      seen.add(key);
      rows.push(row);
    }
  }
  return rows.length ? { rows } : null;
}

module.exports = { composeSports, pickEvent, gameRow, gameState, side, centerText, color };
