"use strict";

// Pure sports composer for ld-sports (Pattern B). No HTTP, no FS, no clock:
// run.js fetches each followed team's ESPN scoreboard, parse.js builds the
// games, and this module renders them. Together with parse.js it is the SINGLE
// source of truth for the sports tile HTML the kiosk renders verbatim
// (dangerouslySetInnerHTML) — SKILL.md does not restate the transform. The HTML
// is SELF-CONTAINED: it ships its own <style> (the Apple-Sports look), so the
// viewer carries no .sp-* CSS and knows nothing about sports.

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

// The widget OWNS its styling: this <style> rides inside the posted HTML so the
// viewer needs zero .sp-* CSS — it's a dumb HTML sink. The rules reference only
// the viewer's shared theme tokens (--ink / --muted / --faint / --hair / fonts /
// accents / --live-red), the one contract; the monogram reads --p/--s the
// producer sets inline per side.
const SP_STYLE = `<style>
.sp-list{flex:1;min-height:0;display:flex;flex-direction:column;justify-content:center}
.sp-list.is-live{background:linear-gradient(180deg,#fffdfa 0%,#fdf3ec 100%);border-radius:16px}
.sp-empty{text-align:center;color:var(--muted);font-size:var(--t-card)}
.sp-game{display:grid;grid-template-columns:14px 38px 30px 1fr 30px 38px 14px;align-items:center;column-gap:6px;padding:12px 0}
.sp-game + .sp-game{border-top:1px solid var(--hair)}
.sp-star{color:var(--accent-ink,var(--clay-ink));font-size:12px;text-align:center;line-height:1}
.sp-logo{width:38px;height:38px;position:relative;display:flex;align-items:center;justify-content:center}
.sp-logo img{width:100%;height:100%;object-fit:contain;display:block}
.sp-mono{display:flex;align-items:center;justify-content:center;width:38px;height:38px;border-radius:50%;background:var(--p,var(--muted));color:var(--s,#fff);font-family:var(--ff-mono);font-weight:500;font-size:12px;letter-spacing:0.02em}
.sp-sc{font-family:var(--ff-body);font-weight:700;font-size:24px;line-height:1;font-variant-numeric:tabular-nums;color:var(--ink)}
.sp-sc.a{text-align:right}
.sp-sc.h{text-align:left}
.sp-sc.lose{color:var(--faint);font-weight:500}
.sp-ctr{display:flex;flex-direction:column;align-items:center;justify-content:center;line-height:1.1;min-width:0}
.sp-time{font-family:var(--ff-body);font-weight:600;font-size:18px;color:var(--ink);white-space:nowrap}
.sp-day{font-family:var(--ff-mono);font-weight:500;font-size:11px;letter-spacing:0.06em;text-transform:uppercase;color:var(--faint)}
.sp-per{display:flex;align-items:center;gap:5px;font-family:var(--ff-mono);font-weight:500;font-size:13px;letter-spacing:0.03em;color:var(--accent-ink,var(--clay-ink));white-space:nowrap}
.sp-livedot{width:7px;height:7px;border-radius:50%;background:var(--live-red);display:inline-block}
.sp-fin{font-family:var(--ff-mono);font-weight:500;font-size:13px;letter-spacing:0.08em;text-transform:uppercase;color:var(--muted)}
</style>`;

// The whole tile: the <style> + a stacked list of game rows (up to `max`).
// `is-live` warms the background when any shown game is live; no games in the
// window → "No upcoming games" (the producer still posts, so the card refreshes
// to that instead of stale scores).
function composeSports(games, max = 3) {
  if (games.length === 0) {
    return `${SP_STYLE}<div class="sp-list"><div class="sp-empty">No upcoming games</div></div>`;
  }
  const shown = games.slice(0, Math.max(0, max));
  const live = shown.some((g) => g.state === "live");
  return `${SP_STYLE}<div class="sp-list${live ? " is-live" : ""}">${shown.map(gameHtml).join("")}</div>`;
}

module.exports = { composeSports, gameHtml, esc };
