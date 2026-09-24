// @ts-check
// The Pomodoro's clock, as pure functions of (state, settings, now): no DOM,
// no Loom — app.js and break.js share it, and Node tests it as is.
// Times are milliseconds since 1970, like Date.now().

(() => {
  "use strict";

  /**
   * @typedef {"idle" | "focus" | "shortBreak" | "longBreak"} Phase
   * @typedef {{
   *   phase: Phase,
   *   endsAt: number | null,
   *   pausedRemaining: number | null,
   *   completedFocus: number,
   * }} TimerState
   * @typedef {{
   *   focus: number, shortBreak: number, longBreak: number,
   *   longEvery: number, autoStartFocus: boolean,
   * }} Settings
   * @typedef {{ date: string, focusDone: number, breaksTaken: number, breaksSkipped: number }} Stats
   */

  const MINUTE = 60 * 1000;

  /** @type {Settings} */
  const DEFAULT_SETTINGS = { focus: 25, shortBreak: 5, longBreak: 15, longEvery: 4, autoStartFocus: false };

  /** @returns {TimerState} */
  function idle(completedFocus = 0) {
    return { phase: "idle", endsAt: null, pausedRemaining: null, completedFocus };
  }

  /** Settings as stored, cleaned: whole minutes in sane bounds. @param {any} raw @returns {Settings} */
  function sanitizeSettings(raw) {
    const clamp = (/** @type {any} */ value, /** @type {number} */ min, /** @type {number} */ max,
                   /** @type {number} */ fallback) => {
      const number = Math.round(Number(value));
      return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
    };
    const source = raw && typeof raw === "object" ? raw : {};
    return {
      focus: clamp(source.focus, 1, 180, DEFAULT_SETTINGS.focus),
      shortBreak: clamp(source.shortBreak, 1, 60, DEFAULT_SETTINGS.shortBreak),
      longBreak: clamp(source.longBreak, 1, 60, DEFAULT_SETTINGS.longBreak),
      longEvery: clamp(source.longEvery, 1, 12, DEFAULT_SETTINGS.longEvery),
      autoStartFocus: source.autoStartFocus === true,
    };
  }

  /** @param {any} raw @returns {TimerState} */
  function sanitizeState(raw) {
    if (!raw || typeof raw !== "object") return idle();
    const phases = ["idle", "focus", "shortBreak", "longBreak"];
    const phase = phases.includes(raw.phase) ? raw.phase : "idle";
    return {
      phase,
      endsAt: typeof raw.endsAt === "number" ? raw.endsAt : null,
      pausedRemaining: typeof raw.pausedRemaining === "number" ? raw.pausedRemaining : null,
      completedFocus: Number.isInteger(raw.completedFocus) && raw.completedFocus >= 0 ? raw.completedFocus : 0,
    };
  }

  /** @param {Phase} phase */
  function isBreak(phase) {
    return phase === "shortBreak" || phase === "longBreak";
  }

  /** @param {Phase} phase @param {Settings} settings */
  function durationOf(phase, settings) {
    switch (phase) {
      case "focus": return settings.focus * MINUTE;
      case "shortBreak": return settings.shortBreak * MINUTE;
      case "longBreak": return settings.longBreak * MINUTE;
      default: return 0;
    }
  }

  /** @param {TimerState} state */
  function isPaused(state) {
    return state.phase !== "idle" && state.endsAt === null && state.pausedRemaining !== null;
  }

  /** @param {TimerState} state @param {number} now */
  function remaining(state, now) {
    if (state.endsAt !== null) return Math.max(0, state.endsAt - now);
    return state.pausedRemaining ?? 0;
  }

  /** @param {TimerState} state @param {Settings} settings @param {number} now @returns {TimerState} */
  function startFocus(state, settings, now) {
    return { phase: "focus", endsAt: now + durationOf("focus", settings), pausedRemaining: null,
             completedFocus: state.completedFocus };
  }

  /** @param {TimerState} state @param {number} now @returns {TimerState} */
  function pause(state, now) {
    if (state.endsAt === null) return state;
    return { ...state, endsAt: null, pausedRemaining: Math.max(0, state.endsAt - now) };
  }

  /** @param {TimerState} state @param {number} now @returns {TimerState} */
  function resume(state, now) {
    if (!isPaused(state)) return state;
    return { ...state, endsAt: now + (state.pausedRemaining ?? 0), pausedRemaining: null };
  }

  /**
   * The phase is over (its time is up, or the user skipped it): focus leads to
   * a break — a long one every `longEvery` — and a break to the next focus,
   * started or waiting for the user.
   * @param {TimerState} state @param {Settings} settings @param {number} now @returns {TimerState}
   */
  function finish(state, settings, now) {
    if (state.phase === "focus") {
      const completedFocus = state.completedFocus + 1;
      const phase = completedFocus % settings.longEvery === 0 ? "longBreak" : "shortBreak";
      return { phase, endsAt: now + durationOf(phase, settings), pausedRemaining: null, completedFocus };
    }
    if (isBreak(state.phase)) {
      const completedFocus = state.phase === "longBreak" ? 0 : state.completedFocus;
      return settings.autoStartFocus
        ? startFocus({ ...state, completedFocus }, settings, now)
        : idle(completedFocus);
    }
    return state;
  }

  /**
   * After Loom was closed or the Mac slept: every phase that ended since is
   * played out at the time it ended, so the clock lands where it would be.
   * @param {TimerState} state @param {Settings} settings @param {number} now
   * @returns {{ state: TimerState, finished: Phase[] }}
   */
  function catchUp(state, settings, now) {
    /** @type {Phase[]} */
    const finished = [];
    let current = state;
    for (let step = 0; step < 50 && current.endsAt !== null && current.endsAt <= now; step++) {
      finished.push(current.phase);
      current = finish(current, settings, current.endsAt);
    }
    return { state: current, finished };
  }

  /** "2026-09-24" in local time. @param {number} now */
  function dayOf(now) {
    const date = new Date(now);
    const pad = (/** @type {number} */ n) => String(n).padStart(2, "0");
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
  }

  /** Today's counters, reset when the day changed. @param {any} raw @param {number} now @returns {Stats} */
  function statsFor(raw, now) {
    const today = dayOf(now);
    if (raw && raw.date === today) {
      return { date: today, focusDone: raw.focusDone | 0, breaksTaken: raw.breaksTaken | 0,
               breaksSkipped: raw.breaksSkipped | 0 };
    }
    return { date: today, focusDone: 0, breaksTaken: 0, breaksSkipped: 0 };
  }

  /** 12:34, or 1:02:03 past an hour. @param {number} ms */
  function format(ms) {
    const total = Math.max(0, Math.ceil(ms / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    const pad = (/** @type {number} */ n) => String(n).padStart(2, "0");
    return hours > 0 ? hours + ":" + pad(minutes) + ":" + pad(seconds) : minutes + ":" + pad(seconds);
  }

  /** @param {Phase} phase */
  function label(phase) {
    switch (phase) {
      case "focus": return "Focus";
      case "shortBreak": return "Short break";
      case "longBreak": return "Long break";
      default: return "Ready";
    }
  }

  const Pomodoro = Object.freeze({
    DEFAULT_SETTINGS, idle, sanitizeSettings, sanitizeState, isBreak, isPaused, durationOf, remaining,
    startFocus, pause, resume, finish, catchUp, statsFor, dayOf, format, label,
  });
  /** @type {any} */ (globalThis).Pomodoro = Pomodoro;
})();
