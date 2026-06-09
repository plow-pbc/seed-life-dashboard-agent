"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { composeWeather, extractWeather, formatWeather, shortCondition } = require("./compose.js");

// Minimal NWS-shaped fixtures. run.js fetches these; compose.js only reads the
// fields below, so the fixtures carry just those.
function hourly(tempF) {
  return { properties: { periods: [{ temperature: tempF }] } };
}
function daily(highF, lowF, shortForecast = "Sunny") {
  return {
    properties: {
      periods: [
        { isDaytime: true, temperature: highF, shortForecast },
        { isDaytime: false, temperature: lowF, shortForecast: "Clear" },
      ],
    },
  };
}

test("shortCondition keeps the clause after the last ' then '", () => {
  assert.equal(shortCondition("Sunny"), "Sunny");
  assert.equal(shortCondition("Partly Cloudy"), "Partly Cloudy");
  assert.equal(shortCondition("Patchy Fog then Sunny"), "Sunny");
  assert.equal(shortCondition("Rain then Mostly Cloudy "), "Mostly Cloudy");
});

test("extractWeather pulls current temp, daytime high+condition, nighttime low", () => {
  assert.deepEqual(extractWeather(hourly(72), daily(75, 54)), {
    tempF: 72,
    highF: 75,
    lowF: 54,
    condition: "Sunny",
  });
});

test("extractWeather rounds non-integer temperatures", () => {
  const r = extractWeather(hourly(71.6), daily(74.4, 53.5));
  assert.deepEqual(r, { tempF: 72, highF: 74, lowF: 54, condition: "Sunny" });
});

test("extractWeather uses the FIRST daytime/nighttime period (evening rollover)", () => {
  // Overnight feed: first period is nighttime (tonight's low), then tomorrow's
  // daytime high — the documented evening behavior.
  const overnight = {
    properties: {
      periods: [
        { isDaytime: false, temperature: 50, shortForecast: "Clear" },
        { isDaytime: true, temperature: 80, shortForecast: "Mostly Sunny" },
      ],
    },
  };
  assert.deepEqual(extractWeather(hourly(58), overnight), {
    tempF: 58,
    highF: 80,
    lowF: 50,
    condition: "Mostly Sunny",
  });
});

test("extractWeather fails loud on a malformed feed", () => {
  assert.throws(() => extractWeather({ properties: { periods: [] } }, daily(75, 54)), /current temperature/);
  assert.throws(() => extractWeather(hourly(72), { properties: { periods: [] } }), /no forecast periods/);
  assert.throws(
    () => extractWeather(hourly(72), { properties: { periods: [{ isDaytime: true, temperature: 75 }] } }),
    /no nighttime low/,
  );
});

test("formatWeather renders the glanceable line with location", () => {
  assert.equal(
    formatWeather({ location: "Mountain View", tempF: 72, condition: "Sunny", highF: 77, lowF: 55 }),
    "Mountain View · 72°F Sunny · H77 L55",
  );
});

test("formatWeather drops the location segment when absent", () => {
  assert.equal(
    formatWeather({ location: "", tempF: 72, condition: "Sunny", highF: 77, lowF: 55 }),
    "72°F Sunny · H77 L55",
  );
});

test("composeWeather end-to-end: fixtures → display line", () => {
  assert.equal(composeWeather("Mountain View", hourly(72), daily(75, 54, "Partly Cloudy")), "Mountain View · 72°F Partly Cloudy · H75 L54");
});
