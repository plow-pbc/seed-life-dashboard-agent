"use strict";

// Pure sports composer for ld-sports (Pattern B). No HTTP, no FS, no clock:
// run.js fetches each followed team's ESPN scoreboard, parse.js builds the
// games, and this module renders them. Together with parse.js it is the SINGLE
// source of truth for the sports tile HTML the kiosk renders verbatim
// (dangerouslySetInnerHTML) — SKILL.md does not restate the transform. The HTML
// targets the viewer's shared .sp-* CSS (the Apple-Sports look); no viewer code
// knows about sports.

// Minimal HTML escape for the few text fields we interpolate (team abbrs,
// status strings, logo URLs). Not a security boundary — the writer is trusted,
// bearer-gated, loopback-read — just keeps a stray "&"/"<" in a feed from
// breaking the fragment.
function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

// One displayed side (away or home): real logo <img> or a colored monogram.
// `pos` is "a" (away, left) or "h" (home, right); `lose` greys the loser.
function sideHtml(side, pos, lose) {
  // Every shown game already involves a followed team, so a "followed" star is
  // redundant noise — emit an empty spacer span to keep the row's column grid
  // aligned without drawing a ★.
  const star = '<span class="sp-star"></span>';
  const logo = side.logo
    ? `<span class="sp-logo"><img src="${esc(side.logo)}" alt="${esc(side.abbr)}"></span>`
    : `<span class="sp-logo"><span class="sp-mono" style="--p:${esc(side.colors.primary)};--s:${esc(side.colors.secondary)}">${esc(side.abbr)}</span></span>`;
  const score =
    side.score == null
      ? `<span class="sp-sc ${pos}"></span>`
      : `<span class="sp-sc ${pos}${lose ? " lose" : ""}">${esc(side.score)}</span>`;
  // away: star · logo · score (score nearest center); home mirrors it.
  return pos === "a" ? `${star}${logo}${score}` : `${score}${logo}${star}`;
}

// The center cell: upcoming = tip-off time (+ weekday); live = a red dot +
// status; final = "Final".
function centerHtml(game) {
  if (game.state === "upcoming") {
    const day = game.dayLabel ? `<span class="sp-day">${esc(game.dayLabel)}</span>` : "";
    return `<span class="sp-ctr"><span class="sp-time">${esc(game.timeLabel || "TBD")}</span>${day}</span>`;
  }
  if (game.state === "final") {
    return `<span class="sp-ctr"><span class="sp-fin">Final</span></span>`;
  }
  // live
  return `<span class="sp-ctr"><span class="sp-per"><span class="sp-livedot"></span>${esc(game.status || "Live")}</span></span>`;
}

// One game row: away (LEFT) · center · home (RIGHT). Loser greyed.
function gameHtml(game) {
  const { away, home } = game;
  const scored = game.state !== "upcoming" && away.score != null && home.score != null;
  const awayLose = scored && home.score > away.score;
  const homeLose = scored && away.score > home.score;
  return (
    `<div class="sp-game">` +
    sideHtml(away, "a", awayLose) +
    centerHtml(game) +
    sideHtml(home, "h", homeLose) +
    `</div>`
  );
}

// The whole tile: a stacked list of game rows. Up to `max` rows fit the slot.
// `is-live` warms the background when any shown game is live.
function composeSports(games, max = 3) {
  // No followed team has a game within the window → say so plainly (the producer
  // still posts, so the card refreshes to this instead of stale scores).
  if (games.length === 0) {
    return `<div class="sp-list"><div class="sp-empty">No upcoming games</div></div>`;
  }
  const shown = games.slice(0, Math.max(0, max));
  const live = shown.some((g) => g.state === "live");
  return `<div class="sp-list${live ? " is-live" : ""}">${shown.map(gameHtml).join("")}</div>`;
}

module.exports = { composeSports, gameHtml, esc };
