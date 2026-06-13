"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { parseGameFor, sideOf, hexColor } = require("./parse.js");

// Minimal ESPN-shaped scoreboard. run.js fetches this; parse.js only reads the
// fields below, so the fixture carries just those.
function event({ state = "in", date = "2026-06-12T02:10Z", mineHome = true, mineScore = "4", oppScore = "2", shortDetail = "Bot 7th" } = {}) {
  const mine = {
    homeAway: mineHome ? "home" : "away",
    score: mineScore,
    team: { abbreviation: "SF", displayName: "San Francisco Giants", logo: "https://a.espncdn.com/sf.png", color: "FD5A1E", alternateColor: "27251F" },
  };
  const opp = {
    homeAway: mineHome ? "away" : "home",
    score: oppScore,
    team: { abbreviation: "LAD", displayName: "Los Angeles Dodgers", logo: "https://a.espncdn.com/lad.png", color: "005A9C", alternateColor: "EF3E42" },
  };
  return {
    date,
    competitions: [{ status: { type: { state, shortDetail } }, competitors: [mine, opp] }],
  };
}

test("hexColor normalizes ESPN colors to #RRGGBB or null", () => {
  assert.equal(hexColor("FD5A1E"), "#FD5A1E");
  assert.equal(hexColor("#abcdef"), "#ABCDEF");
  assert.equal(hexColor("xyz"), null);
  assert.equal(hexColor(undefined), null);
});

test("sideOf falls back to neutral colors and drops a non-https logo", () => {
  const s = sideOf({ score: "", team: { abbreviation: "SF", logo: "data:image/png;base64,xx" } });
  assert.equal(s.abbr, "SF");
  assert.equal(s.logo, null); // non-http(s) dropped
  assert.equal(s.score, null); // empty string → null, not 0
  assert.deepEqual(s.colors, { primary: "#6B7280", secondary: "#FFFFFF" });
  assert.equal(s.followed, false);
});

test("parseGameFor orients away/home by ESPN homeAway and flags the followed side", () => {
  const sb = { events: [event({ mineHome: true })] };
  const g = parseGameFor(sb, "sf");
  assert.equal(g.state, "live");
  assert.equal(g.home.abbr, "SF");
  assert.equal(g.home.followed, true);
  assert.equal(g.away.abbr, "LAD");
  assert.equal(g.away.followed, false);
  assert.equal(g.home.score, 4);
  assert.equal(g.away.score, 2);
});

test("parseGameFor maps ESPN state → upcoming/live/final", () => {
  assert.equal(parseGameFor({ events: [event({ state: "pre" })] }, "sf").state, "upcoming");
  assert.equal(parseGameFor({ events: [event({ state: "in" })] }, "sf").state, "live");
  assert.equal(parseGameFor({ events: [event({ state: "post" })] }, "sf").state, "final");
});

test("parseGameFor returns null when the followed team has no game", () => {
  assert.equal(parseGameFor({ events: [event()] }, "nyy"), null);
  assert.equal(parseGameFor({ events: [] }, "sf"), null);
  assert.equal(parseGameFor({}, "sf"), null);
});

test("parseGameFor adds a weekday label only when kickoff is a different day", () => {
  // Mid-day event so the local-tz calendar date is unambiguous regardless of
  // the test runner's timezone.
  const sb = { events: [event({ state: "pre", date: "2026-06-13T19:00Z" })] };
  const sameDay = parseGameFor(sb, "sf", new Date("2026-06-13T19:00Z"));
  assert.equal(sameDay.dayLabel, "");
  const otherDay = parseGameFor(sb, "sf", new Date("2026-06-10T19:00Z"));
  assert.notEqual(otherDay.dayLabel, "");
});
