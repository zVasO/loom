// Seam: the Pomodoro's clock (pomodoro/engine.js) — pure functions of
// (state, settings, now), loaded as the page loads them, in a bare VM.
import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { extensionsRoot } from "./extract.mjs";

const context = vm.createContext({});
vm.runInContext(readFileSync(resolve(extensionsRoot, "pomodoro/engine.js"), "utf8"), context);
const P = context.Pomodoro;
const plain = (value) => JSON.parse(JSON.stringify(value));

const MIN = 60_000;
const T0 = Date.UTC(2026, 8, 24, 9, 0, 0);
const settings = plain(P.DEFAULT_SETTINGS);

test("a focus run lasts the focus duration and ends in a short break", () => {
  const focus = P.startFocus(P.idle(), settings, T0);
  assert.deepEqual(plain(focus), { phase: "focus", endsAt: T0 + 25 * MIN, pausedRemaining: null, completedFocus: 0 });
  const rest = P.finish(focus, settings, T0 + 25 * MIN);
  assert.equal(rest.phase, "shortBreak");
  assert.equal(rest.endsAt, T0 + 30 * MIN);
  assert.equal(rest.completedFocus, 1);
});

test("every fourth run earns the long break, which starts a new cycle", () => {
  let state = { phase: "focus", endsAt: T0, pausedRemaining: null, completedFocus: 3 };
  state = P.finish(state, settings, T0);
  assert.equal(state.phase, "longBreak");
  assert.equal(state.endsAt, T0 + 15 * MIN);
  state = P.finish(state, settings, state.endsAt);
  assert.deepEqual(plain(state), plain(P.idle(0)), "after the long break, the cycle starts over");
});

test("after a break, the next run waits for the user — or starts by itself if asked", () => {
  const rest = { phase: "shortBreak", endsAt: T0, pausedRemaining: null, completedFocus: 2 };
  assert.equal(P.finish(rest, settings, T0).phase, "idle");
  const auto = P.finish(rest, { ...settings, autoStartFocus: true }, T0);
  assert.equal(auto.phase, "focus");
  assert.equal(auto.endsAt, T0 + 25 * MIN);
  assert.equal(auto.completedFocus, 2);
});

test("pause keeps the time left; resume gives it back", () => {
  const focus = P.startFocus(P.idle(), settings, T0);
  const paused = P.pause(focus, T0 + 10 * MIN);
  assert.equal(paused.endsAt, null);
  assert.equal(paused.pausedRemaining, 15 * MIN);
  assert.ok(P.isPaused(paused));
  assert.equal(P.remaining(paused, T0 + 60 * MIN), 15 * MIN, "time does not pass while paused");
  const resumed = P.resume(paused, T0 + 60 * MIN);
  assert.equal(resumed.endsAt, T0 + 75 * MIN);
  assert.ok(!P.isPaused(resumed));
});

test("catching up after Loom was closed plays out every phase that ended", () => {
  const focus = P.startFocus(P.idle(), settings, T0);
  const { state, finished } = P.catchUp(focus, settings, T0 + 40 * MIN);
  assert.deepEqual([...finished], ["focus", "shortBreak"]);
  assert.equal(state.phase, "idle");
  assert.equal(state.completedFocus, 1);
  const midBreak = P.catchUp(focus, settings, T0 + 27 * MIN);
  assert.equal(midBreak.state.phase, "shortBreak");
  assert.equal(midBreak.state.endsAt, T0 + 30 * MIN, "the break ends when it would have");
});

test("settings are cleaned: whole minutes, sane bounds, defaults for garbage", () => {
  assert.deepEqual(plain(P.sanitizeSettings({ focus: "50", shortBreak: 0, longBreak: 999, longEvery: "x", autoStartFocus: "yes" })),
    { focus: 50, shortBreak: 1, longBreak: 60, longEvery: 4, autoStartFocus: false });
  assert.deepEqual(plain(P.sanitizeSettings(null)), plain(P.DEFAULT_SETTINGS));
  assert.deepEqual(plain(P.sanitizeState({ phase: "nap", completedFocus: -3 })), plain(P.idle()));
});

test("today's counters reset when the day changes", () => {
  const today = P.statsFor({ date: P.dayOf(T0), focusDone: 3, breaksTaken: 2, breaksSkipped: 1 }, T0);
  assert.equal(today.focusDone, 3);
  const tomorrow = P.statsFor(today, T0 + 24 * 60 * MIN);
  assert.equal(tomorrow.focusDone, 0);
});

test("the clock reads m:ss, or h:mm:ss past an hour", () => {
  assert.equal(P.format(25 * MIN), "25:00");
  assert.equal(P.format(61_500), "1:02");
  assert.equal(P.format(3_725_000), "1:02:05");
  assert.equal(P.format(-5), "0:00");
});
