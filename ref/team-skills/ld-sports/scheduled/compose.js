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

// Given the followed-team list [{abbr, league}] and a map league→ESPN scoreboard
// body, build the full tile-spec. Each followed team contributes at most its one
// current/next game row. An empty result → null so run.js posts nothing and the
// kiosk keeps its quiet placeholder (never fake data).
function composeSports(followed, scoreboards, tz) {
  const rows = [];
  for (const { abbr, league } of followed) {
    const events = scoreboards[league]?.events;
    if (!Array.isArray(events)) continue;
    for (const ev of events) {
      const comp = Array.isArray(ev?.competitions) ? ev.competitions[0] : null;
      // ESPN nests status on the event; mirror it onto the competition so
      // gameState/centerText read one shape.
      const merged = comp ? { ...comp, status: comp.status ?? ev.status, date: comp.date ?? ev.date } : null;
      const row = merged ? gameRow(merged, abbr, tz) : null;
      if (row) {
        rows.push(row);
        break; // one game per followed team (the soonest/active one)
      }
    }
  }
  return rows.length ? { rows } : null;
}

module.exports = { composeSports, gameRow, gameState, side, centerText, color };
