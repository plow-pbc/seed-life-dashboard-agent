"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { run, inWeatherWindow } = require("./run.js");

const TZ = "America/Los_Angeles";

function baseConfig(overrides = {}) {
  return {
    family: { timezone: TZ },
    weather: { location: "Mountain View", lat: 37.386, lon: -122.083 },
    ...overrides,
  };
}

// A fake fetch that routes NWS + kiosk requests by URL and records every call.
// `kioskOk` lets a test force a non-2xx kiosk response.
function fakeFetch({ kioskOk = true } = {}) {
  const calls = [];
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts });
    if (url.includes("/points/")) {
      return json({
        properties: {
          forecast: "https://api.weather.gov/gridpoints/MTR/93,86/forecast",
          forecastHourly: "https://api.weather.gov/gridpoints/MTR/93,86/forecast/hourly",
        },
      });
    }
    if (url.endsWith("/forecast/hourly")) {
      return json({ properties: { periods: [{ temperature: 72 }] } });
    }
    if (url.endsWith("/forecast")) {
      return json({
        properties: {
          periods: [
            { isDaytime: true, temperature: 75, shortForecast: "Sunny" },
            { isDaytime: false, temperature: 54, shortForecast: "Clear" },
          ],
        },
      });
    }
    // kiosk POST
    return { ok: kioskOk, status: kioskOk ? 200 : 502, json: async () => ({}) };
  };
  fn.calls = calls;
  return fn;
}
function json(body) {
  return { ok: true, status: 200, json: async () => body };
}

test("inWeatherWindow fires only in [0,5)", () => {
  for (const m of [0, 1, 4]) assert.equal(inWeatherWindow(m), true, `minute ${m}`);
  for (const m of [5, 6, 30, 55, 59]) assert.equal(inWeatherWindow(m), false, `minute ${m}`);
});

test("off-window tick gates out without fetching", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:30:00Z"), // 3:30pm PT → minute 30
    config: baseConfig(),
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.deepEqual(res, { gated: true });
  assert.equal(fetch.calls.length, 0);
});

test("in-window tick fetches, composes, and posts type:weather", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:00:00Z"), // 3:00pm PT → minute 0
    config: baseConfig(),
    fetch,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.deepEqual(res, { posted: true, text: "Mountain View · 72°F Sunny · H75 L54" });
  const post = fetch.calls.find((c) => c.opts.method === "POST");
  assert.ok(post, "a kiosk POST happened");
  assert.equal(post.opts.redirect, "error");
  assert.deepEqual(JSON.parse(post.opts.body), { type: "weather", text: "Mountain View · 72°F Sunny · H75 L54" });
  assert.equal(post.opts.headers.Authorization, "Bearer tok");
});

test("--force bypasses the gate off-cadence", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:30:00Z"), // minute 30, would normally gate
    config: baseConfig(),
    fetch,
    force: true,
    dashUrl: "https://kiosk.example/api/message",
    dashToken: "tok",
  });
  assert.equal(res.posted, true);
});

test("--dry-run composes but never POSTs", async () => {
  const fetch = fakeFetch();
  const res = await run({
    now: new Date("2026-06-09T22:30:00Z"),
    config: baseConfig(),
    fetch,
    dryRun: true,
  });
  assert.deepEqual(res, { dryRun: true, text: "Mountain View · 72°F Sunny · H75 L54" });
  assert.ok(!fetch.calls.some((c) => c.opts.method === "POST"), "no kiosk POST in dry-run");
});

test("non-https kiosk URL is refused", async () => {
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: baseConfig(),
      fetch: fakeFetch(),
      dashUrl: "http://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /must be https/,
  );
});

test("a failed kiosk POST surfaces loudly", async () => {
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: baseConfig(),
      fetch: fakeFetch({ kioskOk: false }),
      dashUrl: "https://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /kiosk POST 502/,
  );
});

test("missing family.timezone fails loud", async () => {
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: { weather: baseConfig().weather }, // no family.timezone
      fetch: fakeFetch(),
      dashUrl: "https://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /timezone/,
  );
});

test("off-host forecast URLs are refused (no SSRF via a steered NWS response)", async () => {
  const fetch = async (url) => {
    if (url.includes("/points/")) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          properties: {
            forecast: "https://evil.example/forecast",
            forecastHourly: "https://api.weather.gov/gridpoints/MTR/93,86/forecast/hourly",
          },
        }),
      };
    }
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: baseConfig(),
      fetch,
      dashUrl: "https://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /off-host/,
  );
});

test("a points body without forecast URLs fails loud", async () => {
  const fetch = async () => ({ ok: true, status: 200, json: async () => ({ properties: {} }) });
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: baseConfig(),
      fetch,
      dashUrl: "https://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /missing forecast URLs/,
  );
});

test("missing weather.lat/lon fails loud", async () => {
  await assert.rejects(
    run({
      now: new Date("2026-06-09T22:00:00Z"),
      config: baseConfig({ weather: { location: "Nowhere" } }),
      fetch: fakeFetch(),
      dashUrl: "https://kiosk.example/api/message",
      dashToken: "tok",
    }),
    /lat\/lon/,
  );
});
