"use strict";

// Pure reminder-text composer for ld-calendar-nudge (runs under the generic plow-scheduled-runner). Mirrors SKILL.md
// §Compose + Post bit-for-bit. No HTTP, no FS, no clock — pass `timezone`
// via opts. Input events MUST be the survivors from filter.js, which
// have `_minutesUntil` and `_isVirtual` precomputed.

// SKILL.md §Compose caps each reminder at ≤ 115 chars (kiosk is a
// glanceable shared display). The two unbounded inputs are the event
// summary and location; truncate the composed line with an ellipsis so
// the cap holds for a pathological title/location.
const MAX_REMINDER_CHARS = 115;

function formatLocalTime(startDt, timezone) {
  // Format as "3:50pm" in the household timezone. Intl.DateTimeFormat
  // emits "3:50 PM" with a space + uppercase; we strip-and-lowercase to
  // match SKILL.md's "<local_time>" example exactly.
  const fmt = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
    timeZone: timezone,
  });
  return fmt.format(new Date(startDt)).replace(" AM", "am").replace(" PM", "pm");
}

function composeOneEvent(evt, opts) {
  const localTime = formatLocalTime(evt.start.date_time, opts.timezone);
  // Clamp to ≥1: filter.js already dropped past events (minutesUntil > 0),
  // so a sub-30s float would only produce a misleading "(0m)" string.
  const minutesUntil = Math.max(1, Math.round(evt._minutesUntil));
  // SKILL.md §Compose: <where> is "online" if virtual, else location
  // verbatim if non-empty, else the entire ` — <where>` clause is omitted.
  // hangout_link is NEVER included — bearer-style join token + shared kiosk.
  // A location that contains a meeting URL is already classified virtual by
  // filter.js `isVirtual` (single source of truth), so `_isVirtual` is true
  // here and the raw URL is rendered as "online" — never echoed.
  let where = "";
  if (evt._isVirtual) {
    where = "online";
  } else if (typeof evt.location === "string" && evt.location.trim().length > 0) {
    where = evt.location.trim();
  }

  // The `at <time> (<Nm>)` portion is the actionable part and must never be
  // cut. When over budget, squeeze the variable fields — location first
  // (keep the title, which identifies the meeting), then the title if it's
  // the offender — never the time/minutes suffix.
  const build = (summary, whereText) => {
    const head = `Heads up: "${summary}" at ${localTime} (${minutesUntil}m)`;
    return whereText ? `${head} — ${whereText}.` : `${head}.`;
  };
  if (build(evt.summary, where).length <= MAX_REMINDER_CHARS) return build(evt.summary, where);

  // 1. Keep the full title; truncate the location to fit.
  if (where) {
    const whereBudget = MAX_REMINDER_CHARS - build(evt.summary, "").length - " — .".length;
    if (whereBudget >= 1) {
      const candidate = build(evt.summary, ellipsize(where, whereBudget));
      if (candidate.length <= MAX_REMINDER_CHARS) return candidate;
    }
  }
  // 2. The title itself is too long — truncate it, keep the location that fits.
  const summaryBudget = MAX_REMINDER_CHARS - build("", where).length;
  if (summaryBudget >= 1) return build(ellipsize(evt.summary, summaryBudget), where);
  // 3. Pathological (title AND location both huge) — drop the title, squeeze location.
  const wb = MAX_REMINDER_CHARS - build("", "").length - " — .".length;
  return build("", wb >= 1 ? ellipsize(where, wb) : "");
}

// Truncate `s` to at most `max` chars, using a trailing ellipsis when cut.
function ellipsize(s, max) {
  if (s.length <= max) return s;
  return max >= 1 ? s.slice(0, max - 1) + "…" : "";
}

/**
 * Compose the reminder text for one or more qualifying events.
 * Multiple events join with a blank line (SKILL.md §Compose).
 *
 * @param {Array}  events       filter.js survivors (have _minutesUntil + _isVirtual)
 * @param {Object} opts
 * @param {string} opts.timezone  IANA tz, e.g. "America/Los_Angeles"
 * @returns {string}
 */
function composeReminder(events, opts) {
  return events.map((e) => composeOneEvent(e, opts)).join("\n\n");
}

module.exports = { composeReminder };
