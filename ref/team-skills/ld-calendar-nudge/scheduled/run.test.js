"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { run, inNudgeWindow } = require("./run.js");

const TZ = "America/Los_Angeles";

function baseConfig(overrides = {}) {
  return {
    family: { timezone: TZ },
    calendar: { sources: [{ account: "owner@example.com", calendar_id: "primary" }] },
    calendar_nudge: { lookahead_virtual_minutes: 30, lookahead_in_person_minutes: 60 },
    ...overrides,
  };
}

function qualifyingEvent(now, overrides = {}) {
  return {
    i_cal_uid: "uid-1",
    status: "confirmed",
    start: { date_time: new Date(now.getTime() + 15 * 60_000).toISOString() },
    summary: "1:1 with Abby",
    location: "",
    hangout_link: "https://meet.example/abc",
    organizer: { email: "owner@example.com" },
    attendees: [
      { email: "owner@example.com", response_status: "accepted" },
      { email: "abby@example.com", response_status: "accepted" },
    ],
    ...overrides,
  };
}

test("inNudgeWindow fires in [20,25) and [50,55) only", () => {
  for (const m of [20, 21, 24, 50, 51, 54]) assert.equal(inNudgeWindow(m), true, `minute ${m}`);
  for (const m of [0, 19, 25, 29, 30, 49, 55, 59]) assert.equal(inNudgeWindow(m), false, `minute ${m}`);
});

// :15 PT is outside the window — the script must self-gate and do nothing.
test("off-window tick gates out without fetching", async () => {
  const now = new Date("2026-05-22T22:15:00Z"); // 3:15pm PT → minute 15
  let fetched = 0;
  const res = await run({
    now,
    fetch: async () => { fetched += 1; return { ok: true, async json() { return { data: { items: [] } }; } }; },
    config: baseConfig(),
    apiUrl: "https://api.test",
    apiToken: "t",
  });
  assert.deepEqual(res, { gated: true });
  assert.equal(fetched, 0);
});

// :20 PT is in-window with a qualifying meeting → kiosk + iMessage posted.
test("in-window tick with a qualifying meeting posts kiosk + iMessage", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // 3:20pm PT → minute 20
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: init && init.body });
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
    }
    return { ok: true, async json() { return {}; } };
  };
  const res = await run({
    now,
    fetch: fetchImpl,
    config: baseConfig(),
    apiUrl: "https://api.test",
    apiToken: "tok",
    dashUrl: "https://dash.test/api/message",
    dashToken: "dtok",
  });
  assert.equal(res.sent, true);
  assert.equal(res.count, 1);
  assert.ok(calls.some((c) => c.url.includes("/calendar.events.list")));
  assert.ok(calls.some((c) => c.url.includes("/channels/linq/send")));
  // Kiosk wire body: the viewer requires all three of card/type/text, and the
  // reminder rides the shared alert slot (card 1) with ld-morning-triage.
  const kiosk = calls.find((c) => c.url === "https://dash.test/api/message");
  assert.ok(kiosk, "a kiosk POST happened");
  const body = JSON.parse(kiosk.body);
  assert.equal(body.card, "1");
  assert.equal(body.type, "alert");
  assert.ok(typeof body.text === "string" && body.text.length > 0);
  assert.equal(body.title, ""); // empty title hides the alert eyebrow
  assert.deepEqual(Object.keys(body).sort(), ["card", "text", "title", "type"]);
});

// In-window but nothing qualifies → silent, no kiosk/iMessage.
test("in-window tick with no qualifying meeting is silent", async () => {
  const now = new Date("2026-05-22T22:50:00Z"); // minute 50, in-window
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [] } }; } };
    }
    return { ok: true, async json() { return {}; } };
  };
  const res = await run({
    now,
    fetch: fetchImpl,
    config: baseConfig(),
    apiUrl: "https://api.test",
    apiToken: "tok",
  });
  assert.deepEqual(res, { sent: false, count: 0 });
  assert.ok(!calls.some((u) => u.includes("/channels/linq/send")));
});

// A 2xx whose body isn't the typed { data: { items: [] } } contract must
// fail loud at the boundary, not spread an undefined into the event list.
test("malformed calendar response (no data.items) throws", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  await assert.rejects(
    () =>
      run({
        now,
        fetch: async () => ({ ok: true, async json() { return { data: {} }; } }),
        config: baseConfig(),
        apiUrl: "https://api.test",
        apiToken: "tok",
      }),
    /calendar\.events\.list malformed response/,
  );
});

// Production wiring: with no opts beyond `now`+`fetch`, run() must read
// config + api-url + tokens off the mounted /config paths via the readFile
// seam (not the test-injected shortcuts the other cases use).
test("reads config + tokens from mounted /config paths (readFile seam)", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  const files = {
    "/config/runtime/ld/config.json": JSON.stringify(baseConfig()),
    "/config/gateway/plow-api-url": "https://api.test\n",
    "/config/secrets/plow-api-token": "tok\n",
    "/config/secrets/dashboard-endpoint-url": "https://dash.test/api/message\n",
    "/config/secrets/dashboard-token": "dtok\n",
  };
  const readFile = async (path) => {
    if (!(path in files)) throw new Error(`unexpected read: ${path}`);
    return files[path];
  };
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push(url);
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
    }
    return { ok: true, async json() { return {}; } };
  };
  const res = await run({ now, fetch: fetchImpl, readFile });
  assert.equal(res.sent, true);
  assert.equal(res.count, 1);
  assert.ok(calls.some((u) => u === "https://dash.test/api/message"));
  assert.ok(calls.some((u) => u.includes("/channels/linq/send")));
});

test("missing family.timezone throws", async () => {
  await assert.rejects(
    () => run({ now: new Date(), config: { calendar: { sources: [] } }, fetch: async () => ({}) }),
    /family\.timezone missing/,
  );
});

// In-window with qualifying event, using an http:// dashUrl (Pi backend on household LAN/tailnet).
test("http:// kiosk URL is accepted (Pi backend on household LAN/tailnet)", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: init && init.body });
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
    }
    return { ok: true, async json() { return {}; } };
  };
  const res = await run({
    now,
    fetch: fetchImpl,
    config: baseConfig(),
    apiUrl: "https://api.test",
    apiToken: "tok",
    dashUrl: "http://rpi5screen:5174/api/message",
    dashToken: "dtok",
  });
  assert.equal(res.sent, true);
  assert.ok(calls.some((c) => c.url === "http://rpi5screen:5174/api/message"));
});

test("non-http(s) kiosk URL is refused (ftp:// and garbage)", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  const fetchImpl = async (url) => {
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
    }
    return { ok: true, async json() { return {}; } };
  };
  for (const badUrl of ["ftp://kiosk.example/api/message", "notaurl"]) {
    await assert.rejects(
      run({
        now,
        fetch: fetchImpl,
        config: baseConfig(),
        apiUrl: "https://api.test",
        apiToken: "tok",
        dashUrl: badUrl,
        dashToken: "dtok",
      }),
      /must be http\(s\):\/\//,
      `expected rejection for ${badUrl}`,
    );
  }
});
