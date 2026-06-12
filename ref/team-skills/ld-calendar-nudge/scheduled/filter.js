"use strict";

// Pure event filter + dedupe for ld-calendar-nudge (runs under the generic plow-scheduled-runner). Mirrors
// team-skills/ld-calendar-nudge/SKILL.md §Filter and §Dedupe bit-for-bit.
// No HTTP, no FS, no clock — pass `now` and `userIdentities` via opts.
//
// Privacy boundary (SKILL.md §Privacy boundary, non-negotiable): the
// kiosk is a shared family display. Events the user explicitly marked
// `visibility: "private"` or `"confidential"` in Google Calendar are
// dropped entirely — neither the title nor the fact-of-meeting reaches
// the kiosk or iMessage. This is the deterministic replacement for the
// previous LLM-judgment rule and lets the user mark sensitive entries
// in the calendar UI they already use.

// Single source of truth for "is this a virtual meeting?", used for BOTH
// the lookahead window (filter) and the "online" where-clause (compose).
// Virtual when:
//   - a non-empty Google `hangout_link` is present, OR
//   - the `location` contains an https?:// URL anywhere (a meeting link
//     pasted into the location field, e.g. "Zoom Meeting: https://…").
// We deliberately do NOT do keyword matching on the location ("Zoom",
// "Meet") — that's the wrong seam ("Meeting Room" false-positives). A
// URL is an unambiguous signal: it's a join link, so the event is
// virtual (gets the virtual lookahead) and the link must never be echoed
// to the shared kiosk — compose renders it as "online".
function locationHasMeetingUrl(evt) {
  return typeof evt?.location === "string" && /https?:\/\//i.test(evt.location);
}

function isVirtual(evt) {
  if (typeof evt?.hangout_link === "string" && evt.hangout_link.length > 0) return true;
  return locationHasMeetingUrl(evt);
}

// The owner has one identity per connected calendar account. SKILL.md
// §Filter derives the set from `calendar.sources` (entries with
// `self !== false`); an event qualifies on owner-participation when any
// of those identities organizes or accepts it.
function ownerParticipates(evt, userIdentities) {
  if (evt?.organizer?.email && userIdentities.has(evt.organizer.email)) return true;
  if (!Array.isArray(evt?.attendees)) return false;
  for (const a of evt.attendees) {
    if (a?.email && userIdentities.has(a.email) && a?.response_status !== "declined") return true;
  }
  return false;
}

// A "human external" counterparty is someone other than the owner who
// could be left waiting. Excludes the owner's own identities and the two
// Google calendar-address suffixes (`@group...` = shared/secondary
// calendar mirroring an invite; `@resource...` = rooms/equipment) — both
// are destinations, not people. SKILL.md §Filter.
function isHumanExternal(email, userIdentities) {
  return (
    typeof email === "string"
    && email.length > 0
    && !userIdentities.has(email)
    && !email.endsWith("@group.calendar.google.com")
    && !email.endsWith("@resource.calendar.google.com")
  );
}

function hasCounterparty(evt, userIdentities) {
  const attendees = Array.isArray(evt?.attendees) ? evt.attendees : [];
  for (const a of attendees) {
    if (isHumanExternal(a?.email, userIdentities) && a?.response_status !== "declined") return true;
  }
  // Google sometimes returns 1:1 invites with the human organizer absent
  // from `attendees` (most often when the user is the invitee). Count a
  // human-external organizer not already echoed into attendees, else the
  // only-attendee-is-owner case silently drops a real heads-up.
  const orgEmail = evt?.organizer?.email;
  if (isHumanExternal(orgEmail, userIdentities)
      && !attendees.some((a) => a?.email === orgEmail)) {
    return true;
  }
  return false;
}

/**
 * Apply the SKILL.md Filter + Dedupe rules.
 *
 * @param {Array} events  raw GoogleCalendarEvent objects, merged across sources
 * @param {Object} opts
 * @param {Date}   opts.now
 * @param {Set<string>} opts.userIdentities  owner's account emails (calendar.sources self!==false)
 * @param {number} opts.virtualLookahead    calendar_nudge.lookahead_virtual_minutes
 * @param {number} opts.inPersonLookahead   calendar_nudge.lookahead_in_person_minutes
 * @returns {Array} filtered + deduped events, each augmented with
 *                  { _minutesUntil, _isVirtual } for downstream compose.
 */
function qualifyingEvents(events, opts) {
  const now = opts.now;
  const userIdentities = opts.userIdentities;
  const virtualLookahead = opts.virtualLookahead;
  const inPersonLookahead = opts.inPersonLookahead;
  const nowMs = now.getTime();

  // Privacy prepass — a single real-world invite appears once per calendar
  // it's on, sharing one iCalUID (SKILL.md §Dedupe). If ANY copy is marked
  // private/confidential, the owner's intent is "don't surface this" — so
  // suppress every copy sharing that (i_cal_uid, start) key, not just the
  // one carrying the visibility flag. Without this, a default-visibility
  // duplicate of a private meeting would survive dedupe and post raw
  // title/location to the shared kiosk.
  const suppressedKeys = new Set();
  for (const evt of events) {
    if (evt && (evt.visibility === "private" || evt.visibility === "confidential")) {
      const uid = typeof evt.i_cal_uid === "string" ? evt.i_cal_uid : "";
      const startDt = evt?.start?.date_time;
      if (uid && typeof startDt === "string" && startDt.length > 0) {
        suppressedKeys.add(`${uid}|${startDt}`);
      }
    }
  }

  const survivors = [];
  for (const evt of events) {
    if (!evt) continue;
    if (evt.status === "cancelled") continue;
    // Privacy boundary — see header + prepass. `default`/`public` post in
    // full; `private`/`confidential` (on this copy OR any same-invite copy)
    // are dropped entirely.
    if (evt.visibility === "private" || evt.visibility === "confidential") continue;

    // All-day events have only `start.date`; without `start.date_time`
    // we can't compute a meaningful minutes_until, and they're handled
    // by morning-affirmation / weekly-digest instead.
    const startDt = evt?.start?.date_time;
    if (typeof startDt !== "string" || startDt.length === 0) continue;

    // Drop a default-visibility copy whose same-invite sibling was marked
    // private/confidential on another calendar (see prepass).
    if (typeof startDt === "string" && typeof evt.i_cal_uid === "string" && evt.i_cal_uid
        && suppressedKeys.has(`${evt.i_cal_uid}|${startDt}`)) continue;

    const startMs = Date.parse(startDt);
    if (!Number.isFinite(startMs)) continue;
    const minutesUntil = (startMs - nowMs) / 60000;
    if (minutesUntil <= 0) continue;

    const virtual = isVirtual(evt);
    const cap = virtual ? virtualLookahead : inPersonLookahead;
    if (!(minutesUntil <= cap)) continue;

    if (!ownerParticipates(evt, userIdentities)) continue;
    if (!hasCounterparty(evt, userIdentities)) continue;

    survivors.push({ ...evt, _minutesUntil: minutesUntil, _isVirtual: virtual });
  }

  // Dedupe by (i_cal_uid, start.date_time). Empty i_cal_uid → keep
  // un-deduped: the cost of two reminders is lower than silently
  // dropping one of two distinct meetings.
  const seen = new Map();
  const out = [];
  for (const evt of survivors) {
    const uid = typeof evt.i_cal_uid === "string" ? evt.i_cal_uid : "";
    if (!uid) {
      out.push(evt);
      continue;
    }
    const key = `${uid}|${evt.start.date_time}`;
    if (seen.has(key)) continue;
    seen.set(key, true);
    out.push(evt);
  }
  return out;
}

module.exports = {
  qualifyingEvents,
  isVirtual,
  isHumanExternal,
};
