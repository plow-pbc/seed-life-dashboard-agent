"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { composeReminder } = require("./compose.js");

const TZ = "America/Los_Angeles"; // UTC-7 in May (PDT)

// Build a survivor-shape event (post-filter.js, so _minutesUntil and
// _isVirtual are present).
function survivor(overrides = {}) {
  return {
    summary: "Sync",
    start: { date_time: "2026-05-21T15:50:00Z" }, // 8:50am PDT
    location: "",
    hangout_link: "",
    _minutesUntil: 50,
    _isVirtual: false,
    ...overrides,
  };
}

test("virtual event composes 'online' as <where>", () => {
  const evt = survivor({
    summary: "1:1",
    _isVirtual: true,
    hangout_link: "https://meet.google.com/abc-defg-hij",
    _minutesUntil: 10,
    start: { date_time: "2026-05-21T22:00:00Z" }, // 3:00pm PDT
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.equal(out, 'Heads up: "1:1" at 3:00pm (10m) — online.');
});

test("in-person event uses location verbatim", () => {
  const evt = survivor({
    summary: "Coffee",
    location: "Blue Bottle, SF",
    _isVirtual: false,
    _minutesUntil: 45,
    start: { date_time: "2026-05-21T22:30:00Z" }, // 3:30pm PDT
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.equal(out, 'Heads up: "Coffee" at 3:30pm (45m) — Blue Bottle, SF.');
});

test("empty location with non-virtual omits the where clause", () => {
  const evt = survivor({
    summary: "Standup",
    location: "",
    _isVirtual: false,
    _minutesUntil: 12,
    start: { date_time: "2026-05-21T22:15:00Z" }, // 3:15pm PDT
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.equal(out, 'Heads up: "Standup" at 3:15pm (12m).');
});

test("two events join with a blank line", () => {
  const a = survivor({
    summary: "A",
    location: "Office",
    _minutesUntil: 10,
    start: { date_time: "2026-05-21T22:00:00Z" }, // 3:00pm PDT
  });
  const b = survivor({
    summary: "B",
    _isVirtual: true,
    hangout_link: "https://meet.google.com/xyz",
    _minutesUntil: 30,
    start: { date_time: "2026-05-21T22:30:00Z" }, // 3:30pm PDT
  });
  const out = composeReminder([a, b], { timezone: TZ });
  assert.equal(
    out,
    'Heads up: "A" at 3:00pm (10m) — Office.\n\nHeads up: "B" at 3:30pm (30m) — online.',
  );
});

test("hangout_link substring is never in the output", () => {
  const hangout = "https://meet.google.com/abc-defg-hij";
  const evt = survivor({
    summary: "Town hall",
    _isVirtual: true,
    hangout_link: hangout,
    _minutesUntil: 20,
    start: { date_time: "2026-05-21T22:00:00Z" },
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.equal(
    out.includes(hangout),
    false,
    "hangout_link must NOT appear verbatim — bearer-style join token + shared kiosk",
  );
  // sanity: still includes "online"
  assert.ok(out.includes("online"));
});

test("a virtual event never echoes its location (URL-in-location case)", () => {
  // filter.js classifies a URL-bearing location as virtual (single source
  // of truth), so compose receives `_isVirtual: true` and must render
  // "online" — the raw join token in `location` must never reach the kiosk.
  const joinUrl = "Zoom Meeting: https://zoom.us/j/123456789?pwd=secrettoken";
  const evt = survivor({
    summary: "Vendor call",
    _isVirtual: true,  // what filter.js computes for a URL-bearing location
    location: joinUrl,
    _minutesUntil: 15,
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.equal(out.includes("zoom.us"), false, "raw join URL must not appear");
  assert.equal(out.includes("secrettoken"), false, "join token must not leak");
  assert.ok(out.includes("— online."), `expected 'online' where-clause: ${out}`);
});

test("plain street address with a slash passes through (in-person)", () => {
  const evt = survivor({
    summary: "Lunch",
    _isVirtual: false,
    location: "Building A/Room 3, 1 Main St",
    _minutesUntil: 40,
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.includes("Building A/Room 3, 1 Main St"), `address should pass through: ${out}`);
});

test("AM/PM is lowercase ('3:00pm' not '3:00 PM')", () => {
  const evt = survivor({
    summary: "Demo",
    _minutesUntil: 10,
    location: "HQ",
    start: { date_time: "2026-05-21T22:00:00Z" }, // 3:00pm PDT
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.includes("3:00pm"));
  assert.equal(out.includes(" PM"), false);
  assert.equal(out.includes(" AM"), false);
});

test("morning time renders as 'am'", () => {
  const evt = survivor({
    summary: "Run",
    _minutesUntil: 60,
    location: "Park",
    // 6:30am PDT = 13:30 UTC
    start: { date_time: "2026-05-21T13:30:00Z" },
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.includes("6:30am"), `expected 6:30am in: ${out}`);
});

test("long title is truncated but the time/minutes suffix survives", () => {
  const evt = survivor({
    summary: "X".repeat(400),  // pathological title
    _minutesUntil: 10,
    _isVirtual: true,
    hangout_link: "https://meet.google.com/abc",
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.length <= 115, `expected ≤115-char cap, got ${out.length}`);
  // The actionable time/minutes/where must not be chopped off the end.
  assert.match(out, /\(10m\) — online\.$/, `time suffix lost: ${out}`);
  assert.ok(out.includes("…"), "expected ellipsis where the title was cut");
});

test("long location is truncated but the time/minutes suffix survives", () => {
  const evt = survivor({
    summary: "Sync",
    _minutesUntil: 25,
    location: "Y".repeat(400),  // pathological location
  });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.length <= 115, `expected ≤115-char cap, got ${out.length}`);
  assert.ok(out.includes("(25m)"), `minutes lost: ${out}`);
  assert.ok(out.includes('"Sync"'), `summary lost: ${out}`);
});

test("reminder at or under 115 chars is left intact (no ellipsis)", () => {
  const evt = survivor({ summary: "Short sync", _minutesUntil: 10, location: "HQ" });
  const out = composeReminder([evt], { timezone: TZ });
  assert.ok(out.length <= 115);
  assert.ok(!out.endsWith("…"));
  assert.ok(out.includes("Short sync"));
});
