"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { run, inSportsWindow } = require("./run.js");

const TZ = "America/Los_Angeles";

function baseConfig(overrides = {}) {
  return {
    family: { timezone: TZ },
    sports: {
      followed: [
        { abbr: "sf", sport: "baseball", league: "mlb" },
        { abbr: "gsw", sport: "basketball", league: "nba" },
      ],
    },
    ...overrides,
  };
}

// Build an ESPN scoreboard whose single event includes `abbr` as the home team.
function scoreboard(abbr, { score = "4", oppScore = "2", state = "in" } = {}) {
  return {
    events: [
      {
        date: "2026-06-12T02:10Z",
        competitions: [
          {
            status: { type: { state, shortDetail: "Bot 7th" } },
            competitors: [
              { homeAway: "home", score, team: { abbreviation: abbr.toUpperCase(), displayName: abbr, logo: "https://a/h.png", color: "FD5A1E", alternateColor: "27251F" } },
              { homeAway: "away", score: oppScore, team: { abbreviation: "OPP", displayName: "Opp", logo: "https://a/o.png", color: "005A9C", alternateColor: "EF3E42" } },
            ],
          },
        ],
      },
    ],
  };
}

// A fake fetch that routes ESPN scoreboards by sport/league in the URL and the
// kiosk POST, recording every call. `kioskOk` forces a non-2xx kiosk response.
function fakeFetch({ kioskOk = true } = {}) {
  const calls = [];
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts });
    if (url.includes("/baseball/mlb/")) return json(scoreboard("sf"));
    if (url.includes("/basketball/nba/")) return json(scoreboard("gsw", { state: "pre" }));
    // kiosk POST
    return { ok: kioskOk, status: kioskOk ? 200 : 502, json: async () => ({}) };
  };
  fn.calls = calls;
  return fn;
}
function json(body) {
  return { ok: true, status: 200, json: async () => body };
}

test("inSportsWindow fires in the first 5 min of each quarter hour", () => {
  for (const m of [0, 4, 15, 19, 30, 45, 49]) assert.equal(inSportsWindow(m), true, `minute ${m}`);
  for (const m of [5, 10, 14, 20, 29, 50, 59]) assert.equal(inSportsWindow(m), false, `minute ${m}`);
});

test("off-window tick gates out without fetching", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:10:00Z"), // minute 10 → out of window
    config: baseConfig(),
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.deepEqual(res, { gated: true });
  assert.equal(fetch.calls.length, 0);
});

test("in-window tick fetches followed teams, composes, and posts card 5 / type:sports", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:00:00Z"), // minute 0 → in window
    config: baseConfig(),
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true);
  assert.match(res.text, /class="sp-list/);
  const post = fetch.calls.find((c) => c.opts.method === "POST");
  assert.ok(post, "a kiosk POST happened");
  assert.equal(post.opts.redirect, "error");
  const body = JSON.parse(post.opts.body);
  assert.equal(body.card, "5");
  assert.equal(body.type, "sports");
  assert.match(body.text, /SF/);
  assert.equal(post.opts.headers.Authorization, "Bearer tok");
  // both followed teams' scoreboards were fetched
  assert.ok(fetch.calls.some((c) => c.url.includes("/baseball/mlb/scoreboard")));
  assert.ok(fetch.calls.some((c) => c.url.includes("/basketball/nba/scoreboard")));
});

test("two followed teams in the same game dedupe to one row", async () => {
  // SF and LAD are both followed and play each other: each per-team fetch parses
  // the same matchup, so the rendered tile must show ONE row, not two.
  const event = {
    id: "401",
    date: "2026-06-12T02:10Z",
    competitions: [
      {
        status: { type: { state: "in", shortDetail: "Bot 7th" } },
        competitors: [
          { homeAway: "home", score: "4", team: { abbreviation: "SF", displayName: "Giants", logo: "https://a.espncdn.com/sf.png", color: "FD5A1E", alternateColor: "27251F" } },
          { homeAway: "away", score: "2", team: { abbreviation: "LAD", displayName: "Dodgers", logo: "https://a.espncdn.com/lad.png", color: "005A9C", alternateColor: "EF3E42" } },
        ],
      },
    ],
  };
  const fetch = async (url) => {
    if (url.includes("/baseball/mlb/")) return json({ events: [event] });
    return { ok: true, status: 200, json: async () => ({}) };
  };
  const res = await run({
    now: new Date("2026-06-09T22:00:00Z"),
    config: { family: { timezone: TZ }, sports: { followed: [{ abbr: "sf", sport: "baseball", league: "mlb" }, { abbr: "lad", sport: "baseball", league: "mlb" }] } },
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true);
  // One game row (the shared matchup is deduped, not rendered twice), and no ★.
  // Match the class attribute, not `sp-game` (which also appears in the <style>).
  assert.equal((res.text.match(/class="sp-game"/g) || []).length, 1);
  assert.doesNotMatch(res.text, /★/);
});

test("a single team's feed error is skipped, not fatal", async () => {
  const fetch = (url, opts = {}) => {
    if (url.includes("/basketball/nba/")) return Promise.resolve({ ok: false, status: 500, json: async () => ({}) });
    if (url.includes("/baseball/mlb/")) return Promise.resolve(json(scoreboard("sf")));
    return Promise.resolve({ ok: true, status: 200, json: async () => ({}) });
  };
  const res = await run({
    now: new Date("2026-06-09T22:00:00Z"),
    config: baseConfig(),
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true); // SF still rendered despite GSW's 500
  assert.match(res.text, /SF/);
});

test("--force bypasses the gate off-cadence", async () => {
  const res = await run({
    now: new Date("2026-06-09T22:10:00Z"), // minute 10, would normally gate
    config: baseConfig(),
    fetch: fakeFetch(),
    force: true,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true);
});

test("--dry-run composes but never POSTs", async () => {
  const fetch = fakeFetch();
  const res = await run({ now: new Date("2026-06-09T22:10:00Z"), config: baseConfig(), fetch, dryRun: true });
  assert.equal(res.dryRun, true);
  assert.match(res.text, /class="sp-list/);
  assert.ok(!fetch.calls.some((c) => c.opts.method === "POST"), "no kiosk POST in dry-run");
});

test("http:// kiosk URL is accepted (Pi backend on household LAN/tailnet)", async () => {
  const res = await run({
    now: new Date("2026-06-09T22:00:00Z"),
    config: baseConfig(),
    fetch: fakeFetch(),
    dashUrl: "http://rpi5screen:5174/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true);
});

test("run fails loud for invalid runtime inputs", async () => {
  const inWindow = new Date("2026-06-09T22:00:00Z");
  // Genuine config errors still fail loud (kiosk failures no longer do — see the
  // best-effort test below).
  const cases = [
    { name: "missing family.timezone", config: { sports: baseConfig().sports }, fetch: fakeFetch(), dashUrl: "https://kiosk.example/api/message", error: /timezone/ },
    { name: "missing sports.followed", config: baseConfig({ sports: {} }), fetch: fakeFetch(), dashUrl: "https://kiosk.example/api/message", error: /sports\.followed/ },
  ];
  for (const c of cases) {
    await assert.rejects(
      run({ now: inWindow, config: c.config, fetch: c.fetch, dashUrl: c.dashUrl, dashToken: "tok" }),
      c.error,
      `expected rejection for ${c.name}`,
    );
  }
});

// Kiosk is best-effort now (postKioskCard): a bad URL / offline Pi / 5xx logs and
// returns posted:false rather than crashing the scheduled runner.
test("kiosk failure is best-effort — posted:false, never throws", async () => {
  const inWindow = new Date("2026-06-09T22:00:00Z");
  for (const c of [
    { dashUrl: "ftp://kiosk.example/api/message", fetch: fakeFetch() },     // bad scheme (no bearer sent)
    { dashUrl: "https://kiosk.example/api/message", fetch: fakeFetch({ kioskOk: false }) }, // 5xx
  ]) {
    const res = await run({ now: inWindow, config: baseConfig(), fetch: c.fetch, dashUrl: c.dashUrl, dashToken: "tok" });
    assert.equal(res.posted, false);
  }
});
