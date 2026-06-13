"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { composeSports, gameRow, gameState, color } = require("./compose.js");

// Minimal ESPN-shaped fixtures. compose.js only reads the fields below.
function competitor(homeAway, abbr, score, { color: c = "FD5A1E", logo = `https://espn/${abbr}.png` } = {}) {
  return { homeAway, score, team: { abbreviation: abbr, color: c, logo } };
}
function comp(state, away, home, { shortDetail, date } = {}) {
  return {
    status: { type: { state, shortDetail } },
    date,
    competitors: [away, home],
  };
}

test("gameState maps ESPN state → render state, rejecting unknown", () => {
  assert.equal(gameState({ status: { type: { state: "pre" } } }), "upcoming");
  assert.equal(gameState({ status: { type: { state: "in" } } }), "live");
  assert.equal(gameState({ status: { type: { state: "post" } } }), "final");
  assert.equal(gameState({ status: { type: { state: "weird" } } }), null);
});

test("color prefixes a valid ESPN hex and rejects junk", () => {
  assert.equal(color("FD5A1E"), "#FD5A1E");
  assert.equal(color("#FD5A1E"), null); // ESPN sends no leading hash
  assert.equal(color("red"), null);
});

test("gameRow: final game — away left / home right, followed starred, loser greyed", () => {
  const c = comp("post", competitor("away", "SF", "8"), competitor("home", "LAD", "3"));
  const row = gameRow(c, "SF", "America/Los_Angeles");
  assert.equal(row.top, true);
  // cells: awayLogo, awayScore, center, homeScore, homeLogo
  assert.deepEqual(row.cells[0], { kind: "logo", abbr: "SF", color: "#FD5A1E", logo: "https://espn/SF.png", star: true });
  assert.deepEqual(row.cells[1], { kind: "text", value: "8", variant: "score" }); // winner, not dimmed
  assert.equal(row.cells[2].cells[0].value, "Final");
  assert.deepEqual(row.cells[3], { kind: "text", value: "3", variant: "score", dim: true }); // loser greyed
  assert.equal(row.cells[4].abbr, "LAD");
  assert.equal(row.cells[4].star, undefined); // opponent not followed
});

test("gameRow: live game shows ESPN shortDetail in the center", () => {
  const c = comp("in", competitor("away", "SF", "2"), competitor("home", "LAD", "1"), { shortDetail: "Top 5th" });
  const row = gameRow(c, "LAD", "America/Los_Angeles");
  assert.equal(row.cells[2].cells[0].value, "Top 5th");
  assert.equal(row.cells[4].star, true); // LAD is home + followed
});

test("gameRow: upcoming game shows tip-off time, no scores", () => {
  const c = comp("pre", competitor("away", "SF", "0"), competitor("home", "LAD", "0"), { date: "2026-06-12T22:40Z" });
  const row = gameRow(c, "SF", "America/Los_Angeles");
  assert.equal(row.cells[1].value, ""); // no score shown for upcoming
  assert.match(row.cells[2].cells[0].value, /\d:\d\d/); // a time like "3:40 PM"
});

test("gameRow returns null when the followed team isn't in the game", () => {
  const c = comp("post", competitor("away", "NYY", "5"), competitor("home", "BOS", "4"));
  assert.equal(gameRow(c, "SF", "America/Los_Angeles"), null);
});

test("gameRow: a tie greys neither score (no leader)", () => {
  const c = comp("post", competitor("away", "SF", "4"), competitor("home", "LAD", "4"));
  const row = gameRow(c, "SF", "America/Los_Angeles");
  assert.equal(row.cells[1].dim, undefined);
  assert.equal(row.cells[3].dim, undefined);
});

test("composeSports: a game two followed teams share renders ONE row (no dup)", () => {
  // SF and LAD (both followed, both MLB) play each other — the demo set's
  // head-to-head day. Each team scans the same scoreboard; the event must not
  // be emitted twice.
  const headToHead = { id: "401", competitions: [comp("post", competitor("away", "SF", "5"), competitor("home", "LAD", "3"))] };
  const spec = composeSports(
    [{ abbr: "SF", league: "mlb" }, { abbr: "LAD", league: "mlb" }],
    { mlb: { events: [headToHead] } },
    "America/Los_Angeles",
  );
  assert.equal(spec.rows.length, 1);
  assert.equal(spec.rows[0].cells[0].star, true); // SF (first followed) is starred
});

test("composeSports: prefers a live game over a finished one (state, not order)", () => {
  const events = [
    { id: "1", competitions: [comp("post", competitor("away", "SF", "2"), competitor("home", "NYM", "1"))] },
    { id: "2", competitions: [comp("in", competitor("away", "SF", "0"), competitor("home", "LAD", "0"), { shortDetail: "Top 1st" })] },
  ];
  const spec = composeSports([{ abbr: "SF", league: "mlb" }], { mlb: { events } }, "America/Los_Angeles");
  assert.equal(spec.rows.length, 1);
  assert.equal(spec.rows[0].cells[2].cells[0].value, "Top 1st"); // the live game won
});

test("composeSports: a same-state doubleheader shows the EARLIEST game, not array order", () => {
  // Two upcoming SF games listed late-then-early; the soonest must win.
  const events = [
    { id: "late", competitions: [comp("pre", competitor("away", "SF", "0"), competitor("home", "LAD", "0"), { date: "2026-06-12T23:00Z" })] },
    { id: "early", competitions: [comp("pre", competitor("away", "SF", "0"), competitor("home", "NYM", "0"), { date: "2026-06-12T18:00Z" })] },
  ];
  const spec = composeSports([{ abbr: "SF", league: "mlb" }], { mlb: { events } }, "America/Los_Angeles");
  assert.equal(spec.rows.length, 1);
  assert.equal(spec.rows[0].cells[4].abbr, "NYM"); // the earlier (18:00Z vs NYM) game
});

test("composeSports: reads status/date nested on the EVENT, not the competition", () => {
  // ESPN sometimes carries status/date on the event; composeSports merges it down.
  const ev = {
    id: "9",
    status: { type: { state: "pre" } },
    date: "2026-06-12T22:40Z",
    competitions: [{ competitors: [competitor("away", "SF", "0"), competitor("home", "LAD", "0")] }],
  };
  const spec = composeSports([{ abbr: "SF", league: "mlb" }], { mlb: { events: [ev] } }, "America/Los_Angeles");
  assert.equal(spec.rows.length, 1);
  assert.match(spec.rows[0].cells[2].cells[0].value, /\d:\d\d/); // upcoming → a tip-off time
});

test("composeSports: one row per followed team, across leagues; empty → null", () => {
  const scoreboards = {
    mlb: { events: [{ competitions: [comp("post", competitor("away", "SF", "8"), competitor("home", "LAD", "3"))] }] },
    nba: { events: [{ competitions: [comp("in", competitor("away", "GS", "55"), competitor("home", "SAC", "50"), { shortDetail: "Q3 7:42" })] }] },
  };
  const followed = [{ abbr: "SF", league: "mlb" }, { abbr: "GS", league: "nba" }];
  const spec = composeSports(followed, scoreboards, "America/Los_Angeles");
  assert.equal(spec.rows.length, 2);
  assert.equal(spec.rows[0].cells[0].abbr, "SF");
  assert.equal(spec.rows[1].cells[2].cells[0].value, "Q3 7:42");

  assert.equal(composeSports([{ abbr: "SF", league: "mlb" }], { mlb: { events: [] } }, "America/Los_Angeles"), null);
});
