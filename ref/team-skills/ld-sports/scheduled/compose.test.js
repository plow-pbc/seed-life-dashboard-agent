"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { composeSports, gameHtml, esc } = require("./compose.js");

// A render-ready game (the shape parse.js produces). Helpers below tweak one
// field at a time so each test asks a different question.
function side({ abbr = "SF", logo = "https://a/sf.png", score = 4, followed = false } = {}) {
  return { abbr, name: abbr, logo, colors: { primary: "#FD5A1E", secondary: "#27251F" }, score, followed };
}
function game(overrides = {}) {
  return {
    state: "live",
    away: side({ abbr: "LAD", score: 2 }),
    home: side({ abbr: "SF", score: 4, followed: true }),
    status: "Bot 7th",
    timeLabel: "7:10 PM",
    dayLabel: "",
    ...overrides,
  };
}

test("esc neutralizes HTML-significant characters", () => {
  assert.equal(esc('a & b <c> "d"'), "a &amp; b &lt;c&gt; &quot;d&quot;");
  assert.equal(esc(null), "");
});

test("a live game renders both sides, the score, and the live indicator", () => {
  const html = gameHtml(game());
  assert.match(html, /class="sp-game"/);
  assert.match(html, /class="sp-sc a[^"]*">2/); // away score
  assert.match(html, /class="sp-sc h[^"]*">4/); // home score
  assert.match(html, /sp-livedot/);
  assert.match(html, /Bot 7th/);
  assert.match(html, /class="sp-star">★/); // followed team starred
});

test("the loser's score is greyed via the lose class", () => {
  const html = gameHtml(game()); // home SF 4 beats away LAD 2
  assert.match(html, /class="sp-sc a lose">2/);
  assert.doesNotMatch(html, /class="sp-sc h lose"/);
});

test("an upcoming game shows tip-off time (+ weekday) and no scores", () => {
  const html = gameHtml(
    game({ state: "upcoming", away: side({ abbr: "LAD", score: null }), home: side({ abbr: "SF", score: null, followed: true }), dayLabel: "Sat" }),
  );
  assert.match(html, /class="sp-time">7:10 PM/);
  assert.match(html, /class="sp-day">Sat/);
  assert.doesNotMatch(html, /lose/);
});

test("a final game shows Final", () => {
  assert.match(gameHtml(game({ state: "final" })), /class="sp-fin">Final/);
});

test("a side without a logo falls back to a colored monogram", () => {
  const html = gameHtml(game({ home: side({ abbr: "SF", logo: null, followed: true }) }));
  assert.match(html, /class="sp-mono" style="--p:#FD5A1E;--s:#27251F">SF/);
});

test("composeSports stacks up to max rows and warms the background when any is live", () => {
  const three = [game({ state: "final" }), game(), game({ state: "upcoming" })];
  const html = composeSports(three, 2);
  assert.match(html, /class="sp-list is-live"/); // a live game present
  assert.equal((html.match(/class="sp-game"/g) || []).length, 2); // capped at max
});

test("composeSports renders an empty list when no games", () => {
  assert.equal(composeSports([]), '<div class="sp-list"></div>');
});
