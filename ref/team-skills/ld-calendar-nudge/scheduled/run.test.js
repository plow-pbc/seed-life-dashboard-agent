"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { run, inNudgeWindow } = require("./run.js");

const TZ = "America/Los_Angeles";

// The owner's own LinQ handle, as returned by GET /v1/me/channels. run.js
// resolves this at fire time and passes it as the `thread_handle` for
// owner-self iMessage delivery (the API dropped the legacy `to:"owner"`
// sentinel — an explicit handle is now required).
const OWNER_HANDLE = "+16505551212";
function meChannelsResponse(channels) {
  return {
    ok: true,
    async json() {
      return { channels: channels ?? [{ provider: "linq", provider_key: OWNER_HANDLE }] };
    },
  };
}

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

// The run() fetch mock shared by the in-window tests: a qualifying calendar
// event, then the owner-channel lookup (happy by default, overridable to
// exercise resolution failures), then an empty 200 for the kiosk/send POSTs.
// Records each call as { url, body } on `calls`.
function fetchCalendarThenOwner({ now, calls, meResponse }) {
  return async (url, init) => {
    calls.push({ url, body: init && init.body });
    if (url.includes("/calendar.events.list")) {
      return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
    }
    if (url.includes("/v1/me/channels")) return meResponse ?? meChannelsResponse();
    return { ok: true, async json() { return {}; } };
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
  const fetchImpl = fetchCalendarThenOwner({ now, calls });
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
  // iMessage wire body: owner-self delivery now requires the resolved
  // thread_handle (the owner's own LinQ handle from /v1/me/channels); the
  // legacy `to:"owner"` sentinel is gone (it 422s server-side).
  const send = calls.find((c) => c.url.includes("/channels/linq/send"));
  const sendBody = JSON.parse(send.body);
  assert.equal(sendBody.thread_handle, OWNER_HANDLE);
  assert.ok(typeof sendBody.text === "string" && sendBody.text.length > 0);
  assert.ok(!("to" in sendBody), "the dead to:'owner' sentinel must not be sent");
});

// Regression: the household Pi is offline (fetch throws, or 5xx) — the owner's
// iMessage reminder MUST still go out. Before the kiosk was made best-effort, a
// failed kiosk POST aborted the run and the owner silently got nothing.
test("kiosk POST failure (offline Pi) does not suppress the owner iMessage", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  for (const kioskOutcome of [
    () => { throw new TypeError("fetch failed"); },                    // Pi unreachable (UND_ERR_CONNECT_TIMEOUT)
    () => ({ ok: false, status: 503, async json() { return {}; } }),  // Pi up but erroring
  ]) {
    const calls = [];
    const fetchImpl = async (url, init) => {
      calls.push({ url, body: init && init.body });
      if (url.includes("/calendar.events.list")) {
        return { ok: true, async json() { return { data: { items: [qualifyingEvent(now)] } }; } };
      }
      if (url.includes("/v1/me/channels")) return meChannelsResponse();
      if (url === "https://dash.test/api/message") return kioskOutcome();
      return { ok: true, async json() { return {}; } };
    };
    const res = await run({
      now, fetch: fetchImpl, config: baseConfig(),
      apiUrl: "https://api.test", apiToken: "tok",
      dashUrl: "https://dash.test/api/message", dashToken: "dtok",
    });
    assert.equal(res.sent, true, "owner reminder sent despite kiosk failure");
    assert.equal(res.count, 1);
    const send = calls.find((c) => c.url.includes("/channels/linq/send"));
    assert.ok(send, "iMessage send happened");
    assert.equal(JSON.parse(send.body).thread_handle, OWNER_HANDLE);
  }
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
  const fetchImpl = fetchCalendarThenOwner({ now, calls });
  const res = await run({ now, fetch: fetchImpl, readFile });
  assert.equal(res.sent, true);
  assert.equal(res.count, 1);
  assert.ok(calls.some((c) => c.url === "https://dash.test/api/message"));
  assert.ok(calls.some((c) => c.url.includes("/channels/linq/send")));
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
  const fetchImpl = fetchCalendarThenOwner({ now, calls });
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

// Owner-self delivery needs the owner's LinQ handle from /v1/me/channels. Each
// way that resolution can fail must fail loud rather than send a malformed
// body — and only AFTER the kiosk reminder has posted, so a degraded send path
// never suppresses the glanceable surface (and never silently sends nothing).
for (const { name, meResponse, expected } of [
  { name: "non-2xx response", meResponse: { ok: false, status: 500, async json() { return {}; } }, expected: /me\/channels 500/ },
  { name: "malformed payload (channels not an array)", meResponse: { ok: true, async json() { return { channels: null }; } }, expected: /me\/channels malformed response/ },
  { name: "no linq channel provisioned", meResponse: meChannelsResponse([]), expected: /no linq channel/ },
]) {
  test(`/v1/me/channels ${name} throws after kiosk posts, no send attempted`, async () => {
    const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
    const calls = [];
    const fetchImpl = fetchCalendarThenOwner({ now, calls, meResponse });
    await assert.rejects(
      () => run({
        now,
        fetch: fetchImpl,
        config: baseConfig(),
        apiUrl: "https://api.test",
        apiToken: "tok",
        dashUrl: "https://dash.test/api/message",
        dashToken: "dtok",
      }),
      expected,
    );
    assert.ok(calls.some((c) => c.url === "https://dash.test/api/message"), "kiosk posted before the throw");
    assert.ok(!calls.some((c) => c.url.includes("/channels/linq/send")), "no send attempted without a handle");
  });
}

// A non-http(s) kiosk URL trips postKiosk's token-leak guard (never forward the
// bearer to a non-http target) — but the kiosk is best-effort, so a misconfigured
// URL is logged-and-skipped for the kiosk, never POSTed to, and the owner's
// iMessage reminder still goes out.
test("non-http(s) kiosk URL is skipped (bearer never sent), iMessage still delivered", async () => {
  const now = new Date("2026-05-22T22:20:00Z"); // minute 20, in-window
  for (const badUrl of ["ftp://kiosk.example/api/message", "notaurl"]) {
    const calls = [];
    const res = await run({
      now,
      fetch: fetchCalendarThenOwner({ now, calls }),
      config: baseConfig(),
      apiUrl: "https://api.test",
      apiToken: "tok",
      dashUrl: badUrl,
      dashToken: "dtok",
    });
    assert.equal(res.sent, true, `owner reminder still sent for ${badUrl}`);
    assert.ok(!calls.some((c) => c.url === badUrl), `bearer never POSTed to ${badUrl}`);
    assert.ok(calls.some((c) => c.url.includes("/channels/linq/send")), `iMessage send happened for ${badUrl}`);
  }
});
