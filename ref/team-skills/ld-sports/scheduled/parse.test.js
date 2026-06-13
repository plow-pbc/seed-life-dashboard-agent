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
});

test("sideOf accepts only HTTPS ESPN-CDN logos; untrusted feed URLs → null", () => {
  const logoOf = (logo) => sideOf({ team: { abbreviation: "SF", logo } }).logo;
  // Allowed: HTTPS on espncdn.com and its subdomains.
  assert.equal(logoOf("https://a.espncdn.com/sf.png"), "https://a.espncdn.com/sf.png");
  assert.equal(logoOf("https://a1-3.espncdn.com/sf.png"), "https://a1-3.espncdn.com/sf.png");
  assert.equal(logoOf("https://espncdn.com/sf.png"), "https://espncdn.com/sf.png");
  // Rejected: a feed-driven fetch to an arbitrary host or over plain HTTP.
  assert.equal(logoOf("http://192.168.1.1/logo.png"), null); // HTTP IP → null
  assert.equal(logoOf("https://evil.example.com/logo.png"), null); // non-ESPN HTTPS → null
  assert.equal(logoOf("https://espncdn.com.evil.com/logo.png"), null); // suffix-spoof → null
  assert.equal(logoOf("not a url"), null);
});

test("parseGameFor orients away/home by ESPN homeAway", () => {
  const sb = { events: [event({ mineHome: true })] };
  const g = parseGameFor(sb, "sf", "America/Los_Angeles");
  assert.equal(g.state, "live");
  assert.equal(g.home.abbr, "SF"); // followed team is home here
  assert.equal(g.away.abbr, "LAD");
  assert.equal(g.home.score, 4);
  assert.equal(g.away.score, 2);
});

test("parseGameFor maps ESPN state → upcoming/live/final", () => {
  const tz = "America/Los_Angeles";
  assert.equal(parseGameFor({ events: [event({ state: "pre" })] }, "sf", tz).state, "upcoming");
  assert.equal(parseGameFor({ events: [event({ state: "in" })] }, "sf", tz).state, "live");
  assert.equal(parseGameFor({ events: [event({ state: "post" })] }, "sf", tz).state, "final");
});

test("parseGameFor returns null when the followed team has no game", () => {
  const tz = "America/Los_Angeles";
  assert.equal(parseGameFor({ events: [event()] }, "nyy", tz), null);
  assert.equal(parseGameFor({ events: [] }, "sf", tz), null);
  assert.equal(parseGameFor({}, "sf", tz), null);
});

test("parseGameFor renders tip-off time and day boundary in family.timezone, not the runner's", () => {
  // A 7:10 PM PT first pitch is 02:10Z the next calendar day. The label must
  // read in the household zone even when the runner's system clock is UTC.
  const sb = { events: [event({ state: "pre", date: "2026-06-13T02:10Z" })] };
  const now = new Date("2026-06-12T20:00Z"); // 1 PM PT on Jun 12
  const pt = parseGameFor(sb, "sf", "America/Los_Angeles", now);
  assert.equal(pt.timeLabel, "7:10 PM"); // 02:10Z → 7:10 PM PT (Jun 12)
  assert.equal(pt.dayLabel, ""); // same PT calendar day as `now`, no weekday label
  // Same instant, an Eastern household: 10:10 PM ET, still the same ET day.
  const et = parseGameFor(sb, "sf", "America/New_York", now);
  assert.equal(et.timeLabel, "10:10 PM");
});

test("parseGameFor adds a weekday label only when kickoff is a different day", () => {
  // Mid-day event so the tz calendar date is unambiguous.
  const tz = "America/Los_Angeles";
  const sb = { events: [event({ state: "pre", date: "2026-06-13T19:00Z" })] };
  const sameDay = parseGameFor(sb, "sf", tz, new Date("2026-06-13T19:00Z"));
  assert.equal(sameDay.dayLabel, "");
  const otherDay = parseGameFor(sb, "sf", tz, new Date("2026-06-10T19:00Z"));
  assert.notEqual(otherDay.dayLabel, "");
});
