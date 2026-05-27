"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { qualifyingEvents, isVirtual, isHumanExternal } = require("./filter.js");

const OWNER = "owner@example.com";
const OTHER = "guest@example.com";
const USER_IDENTITIES = new Set([OWNER]);

// Anchor "now" at a deterministic moment so minutes_until math is stable.
const NOW = new Date("2026-05-21T15:00:00Z");

function minutesFromNow(min) {
  return new Date(NOW.getTime() + min * 60000).toISOString();
}

function baseEvent(overrides = {}) {
  return {
    id: "ev_abc",
    summary: "Meeting",
    description: "",
    location: "",
    start: { date_time: minutesFromNow(15) },
    end: { date_time: minutesFromNow(45) },
    status: "confirmed",
    html_link: "",
    hangout_link: "",
    attendees: [
      { email: OWNER, response_status: "accepted" },
      { email: OTHER, response_status: "accepted" },
    ],
    organizer: { email: OWNER, response_status: "accepted" },
    recurrence: [],
    recurring_event_id: "",
    i_cal_uid: "uid-1@example.com",
    account: "owner-gmail",
    calendar_id: "primary",
    ...overrides,
  };
}

const OPTS = {
  now: NOW,
  userIdentities: USER_IDENTITIES,
  virtualLookahead: 30,
  inPersonLookahead: 60,
};

test("virtual event within virtual lookahead is kept", () => {
  const evt = baseEvent({
    start: { date_time: minutesFromNow(20) },
    hangout_link: "https://meet.google.com/abc-defg-hij",
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 1);
  assert.equal(out[0]._isVirtual, true);
});

test("virtual event past virtual lookahead is dropped", () => {
  const evt = baseEvent({
    start: { date_time: minutesFromNow(45) },
    hangout_link: "https://meet.google.com/abc-defg-hij",
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("in-person event between virtualLookahead and inPersonLookahead is kept", () => {
  // 45min out, no hangout_link, no virtual location → in-person.
  const evt = baseEvent({
    start: { date_time: minutesFromNow(45) },
    location: "123 Main St",
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 1);
  assert.equal(out[0]._isVirtual, false);
});

test("declined owner invite is dropped", () => {
  const evt = baseEvent({
    organizer: { email: "someone-else@example.com" },
    attendees: [
      { email: OWNER, response_status: "declined" },
      { email: OTHER, response_status: "accepted" },
    ],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("solo event (owner only) is dropped — no other attendee", () => {
  const evt = baseEvent({
    attendees: [{ email: OWNER, response_status: "accepted" }],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("only other attendee declined → dropped (no one to meet with)", () => {
  const evt = baseEvent({
    attendees: [
      { email: OWNER, response_status: "accepted" },
      { email: OTHER, response_status: "declined" },
    ],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("owner's SECOND identity (cross-account invite) qualifies", () => {
  // Owner fetched this via their sam@odio.dev account but is invited as
  // so@plow.co; both are in the identity set.
  const ids = new Set(["sam@odio.dev", "so@plow.co"]);
  const evt = baseEvent({
    organizer: { email: OTHER },
    attendees: [
      { email: "so@plow.co", response_status: "accepted" },
      { email: OTHER, response_status: "accepted" },
    ],
  });
  const out = qualifyingEvents([evt], { ...OPTS, userIdentities: ids });
  assert.equal(out.length, 1);
});

test("self:false account does not count as owner-participation", () => {
  // A partner's calendar (account NOT in identity set) carrying a meeting
  // the owner isn't in must not nudge.
  const evt = baseEvent({
    organizer: { email: "partner@example.com" },
    attendees: [
      { email: "partner@example.com", response_status: "accepted" },
      { email: OTHER, response_status: "accepted" },
    ],
  });
  const out = qualifyingEvents([evt], OPTS);  // identities = {OWNER} only
  assert.equal(out.length, 0);
});

test("group-calendar attendee is not a counterparty", () => {
  // A family-shared calendar mirrored into attendees is a destination,
  // not a person — it must not satisfy the counterparty requirement.
  const evt = baseEvent({
    attendees: [
      { email: OWNER, response_status: "accepted" },
      { email: "fam123@group.calendar.google.com", response_status: "accepted" },
    ],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("resource-calendar attendee (room) is not a counterparty", () => {
  const evt = baseEvent({
    attendees: [
      { email: OWNER, response_status: "accepted" },
      { email: "room-7@resource.calendar.google.com", response_status: "accepted" },
    ],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("human-external organizer absent from attendees counts as counterparty", () => {
  // 1:1 invite where Google left the organizer out of attendees and only
  // the owner is listed — the organizer is still someone to meet.
  const evt = baseEvent({
    organizer: { email: OTHER },
    attendees: [{ email: OWNER, response_status: "accepted" }],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 1);
});

test("isHumanExternal: identities, group, and resource addresses excluded", () => {
  const ids = new Set([OWNER]);
  assert.equal(isHumanExternal(OWNER, ids), false);
  assert.equal(isHumanExternal("", ids), false);
  assert.equal(isHumanExternal("x@group.calendar.google.com", ids), false);
  assert.equal(isHumanExternal("x@resource.calendar.google.com", ids), false);
  assert.equal(isHumanExternal(OTHER, ids), true);
});

test("cancelled event is dropped", () => {
  const evt = baseEvent({ status: "cancelled" });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("private visibility drops the event entirely", () => {
  const evt = baseEvent({ visibility: "private" });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("confidential visibility drops the event entirely", () => {
  const evt = baseEvent({ visibility: "confidential" });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("public visibility is allowed", () => {
  const evt = baseEvent({ visibility: "public" });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 1);
});

test("private copy suppresses its default-visibility duplicate (same iCalUID)", () => {
  // Same invite on two calendars: owner-primary marked private, family-shared
  // copy left default. The private intent must suppress BOTH — otherwise the
  // default copy leaks the title/location to the shared kiosk.
  const privateCopy = baseEvent({
    id: "copy-private",
    visibility: "private",
    i_cal_uid: "shared-uid@example.com",
  });
  const defaultCopy = baseEvent({
    id: "copy-default",
    visibility: "default",
    i_cal_uid: "shared-uid@example.com",
  });
  const out = qualifyingEvents([defaultCopy, privateCopy], OPTS);
  assert.equal(out.length, 0, "default-visibility duplicate of a private invite must not survive");
});

test("private copy with different start does NOT suppress an unrelated occurrence", () => {
  // The suppress key is (i_cal_uid, start) — a private occurrence of a series
  // must not silence a distinct same-UID occurrence at another time.
  const privateOccurrence = baseEvent({
    visibility: "private",
    i_cal_uid: "series-uid@example.com",
    start: { date_time: minutesFromNow(15) },
  });
  const otherOccurrence = baseEvent({
    visibility: "default",
    i_cal_uid: "series-uid@example.com",
    start: { date_time: minutesFromNow(25) },
  });
  const out = qualifyingEvents([privateOccurrence, otherOccurrence], OPTS);
  assert.equal(out.length, 1);
});

test("all-day event (start.date only) is dropped", () => {
  const evt = baseEvent({
    start: { date_time: null, date: "2026-05-21" },
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("dedupe by (i_cal_uid, start.date_time) collapses 2 copies to 1", () => {
  const start = minutesFromNow(20);
  const a = baseEvent({
    id: "copy_a",
    start: { date_time: start },
    location: "Office",
    i_cal_uid: "shared-uid@example.com",
  });
  const b = baseEvent({
    id: "copy_b",
    start: { date_time: start },
    location: "Office",
    i_cal_uid: "shared-uid@example.com",
  });
  const out = qualifyingEvents([a, b], OPTS);
  assert.equal(out.length, 1);
});

test("empty i_cal_uid does not collapse — 2 stay 2", () => {
  const start = minutesFromNow(20);
  const a = baseEvent({
    id: "copy_a",
    start: { date_time: start },
    location: "Office",
    i_cal_uid: "",
  });
  const b = baseEvent({
    id: "copy_b",
    start: { date_time: start },
    location: "Office",
    i_cal_uid: "",
  });
  const out = qualifyingEvents([a, b], OPTS);
  assert.equal(out.length, 2);
});

test("event in the past (minutes_until <= 0) is dropped", () => {
  const evt = baseEvent({
    start: { date_time: minutesFromNow(-5) },
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0);
});

test("owner is organizer but not in attendees list is kept", () => {
  // Owner-organized event where Google omitted the owner from attendees
  // (a single-other-attendee invite often does this).
  const evt = baseEvent({
    organizer: { email: OWNER },
    attendees: [{ email: OTHER, response_status: "accepted" }],
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 1);
});

test("isVirtual: hangout_link alone is enough", () => {
  assert.equal(
    isVirtual({ location: "", hangout_link: "https://meet.google.com/abc" }),
    true,
  );
});

test("isVirtual: keyword location strings stay in-person (no token matching)", () => {
  // The keyword-token classifier is intentionally gone: "Meeting Room"
  // would have matched "meet" and silently shortened the lookahead.
  // Only a hangout_link or an actual URL counts.
  assert.equal(isVirtual({ location: "Conference Room A — Zoom backup", hangout_link: "" }), false);
  assert.equal(isVirtual({ location: "Meeting Room 3", hangout_link: "" }), false);
  assert.equal(isVirtual({ location: "123 Main St", hangout_link: "" }), false);
});

test("isVirtual: an https URL anywhere in location counts as virtual", () => {
  // A meeting link pasted into the location field — bare or labeled — is a
  // join link; the event is virtual (virtual lookahead) and compose will
  // render it "online" rather than echo the token.
  assert.equal(isVirtual({ location: "https://zoom.us/j/123", hangout_link: "" }), true);
  assert.equal(isVirtual({ location: "Zoom Meeting: https://zoom.us/j/123?pwd=x", hangout_link: "" }), true);
  assert.equal(isVirtual({ location: "Join here http://meet.example/abc", hangout_link: "" }), true);
});

test("URL-in-location event qualifies on the VIRTUAL lookahead window", () => {
  // 40 min out: inside the 60-min in-person window but OUTSIDE the 30-min
  // virtual window. A labeled-URL location must be treated virtual, so this
  // is correctly dropped (not sent 40 min early as if in-person).
  const evt = baseEvent({
    hangout_link: "",
    location: "Zoom Meeting: https://zoom.us/j/999",
    start: { date_time: minutesFromNow(40) },
  });
  const out = qualifyingEvents([evt], OPTS);
  assert.equal(out.length, 0, "URL-location event past the 30-min virtual cap must drop");
});

test("isVirtual ignores description (prompt-injection surface)", () => {
  // Description is data, not signal — even if it mentions "Zoom".
  assert.equal(
    isVirtual({ location: "", hangout_link: "", description: "Join via Zoom" }),
    false,
  );
});
