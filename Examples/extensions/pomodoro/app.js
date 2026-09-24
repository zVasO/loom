// @ts-check
/// <reference path="../loom.d.ts" />
/// <reference path="./pomodoro.d.ts" />

// Pomodoro — a Loom extension (docs/extensions.md). This page runs from
// Loom's launch ("background" permission) and is also the extension's tab.
// Loom's own clock ends each phase (loom.alarms): a hidden page's timers are
// throttled, an alarm is not. When a break starts, break.html covers Loom
// (loom.ui.presentOverlay); the top bar shows the countdown (loom.ui.setStatus).

(() => {
  "use strict";

  const ALARM = "phase-end";
  const KEY_STATE = "timer";
  const KEY_SETTINGS = "settings";
  const KEY_STATS = "stats";

  /** @type {PomodoroTypes.TimerState} */ let state = Pomodoro.idle();
  /** @type {PomodoroTypes.Settings} */ let settings = Pomodoro.DEFAULT_SETTINGS;
  /** @type {PomodoroTypes.Stats} */ let stats = Pomodoro.statsFor(null, Date.now());
  /** @type {number | undefined} */ let ticker;

  /** @param {string} id */
  function $(id) {
    const element = document.getElementById(id);
    if (!element) throw new Error("missing #" + id);
    return element;
  }

  // MARK: - State changes

  /**
   * Stores the new state and brings Loom in line with it: the alarm that ends
   * the phase, the top-bar status, the break overlay.
   * @param {PomodoroTypes.TimerState} next
   */
  async function apply(next) {
    const previous = state;
    state = next;
    await loom.storage.set(KEY_STATE, state);
    await syncAlarm();
    await syncStatus();
    const onBreak = Pomodoro.isBreak(state.phase) && state.endsAt !== null;
    if (onBreak && previous.endsAt !== state.endsAt) {
      await presentBreak();
    } else if (!onBreak && Pomodoro.isBreak(previous.phase) && previous.endsAt !== null) {
      // The break ended, was skipped, or was paused: nothing left to cover Loom.
      await loom.ui.dismissOverlay().catch(() => {});
    }
    render();
  }

  async function syncAlarm() {
    if (state.endsAt !== null) {
      await loom.alarms.create(ALARM, { when: state.endsAt });
    } else {
      await loom.alarms.clear(ALARM);
    }
  }

  async function syncStatus() {
    if (state.phase === "idle") {
      await loom.ui.setStatus(null);
      return;
    }
    const icon = state.phase === "focus" ? "🍅" : "☕";
    if (Pomodoro.isPaused(state)) {
      await loom.ui.setStatus({ text: icon + " paused", tooltip: Pomodoro.label(state.phase) + " — paused" });
      return;
    }
    await loom.ui.setStatus({
      text: icon,
      countdownTo: state.endsAt ?? undefined,
      tooltip: Pomodoro.label(state.phase) + " — until " + new Date(state.endsAt ?? Date.now()).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
    });
  }

  async function presentBreak() {
    if (state.endsAt === null) return;
    try {
      await loom.ui.presentOverlay({ page: "break.html", until: state.endsAt, dismissLabel: "Skip break" });
    } catch (error) {
      console.warn("[pomodoro] overlay", error);
    }
  }

  /** @param {"focusDone" | "breaksTaken" | "breaksSkipped"} key */
  async function count(key) {
    stats = Pomodoro.statsFor(stats, Date.now());
    stats[key] += 1;
    await loom.storage.set(KEY_STATS, stats);
  }

  /** The phase is over — by the clock, or skipped. @param {"time" | "skip"} how */
  async function endPhase(how) {
    const ended = state.phase;
    if (ended === "focus") await count("focusDone");
    if (Pomodoro.isBreak(ended)) await count(how === "skip" ? "breaksSkipped" : "breaksTaken");
    await apply(Pomodoro.finish(state, settings, Date.now()));
  }

  // MARK: - Actions

  async function startOrResume() {
    if (Pomodoro.isPaused(state)) await apply(Pomodoro.resume(state, Date.now()));
    else if (state.phase === "idle") await apply(Pomodoro.startFocus(state, settings, Date.now()));
  }

  async function pause() {
    if (state.endsAt !== null) await apply(Pomodoro.pause(state, Date.now()));
  }

  async function skip() {
    if (state.phase !== "idle") await endPhase("skip");
  }

  async function reset() {
    await apply(Pomodoro.idle());
  }

  // MARK: - Rendering (only while the tab is on screen)

  function render() {
    const now = Date.now();
    const running = state.endsAt !== null;
    const paused = Pomodoro.isPaused(state);
    $("phase").textContent = Pomodoro.label(state.phase) + (paused ? " — paused" : "");
    $("clock").textContent = Pomodoro.format(state.phase === "idle"
      ? Pomodoro.durationOf("focus", settings) : Pomodoro.remaining(state, now));
    document.body.dataset.phase = state.phase;
    const inCycle = state.completedFocus % settings.longEvery;
    $("cycle").textContent = "●".repeat(inCycle) + "○".repeat(settings.longEvery - inCycle);

    const start = $("start");
    start.hidden = running;
    start.textContent = paused ? "Resume" : "Start focus";
    $("pause").hidden = !running;
    $("skip").hidden = state.phase === "idle";
    $("skip").textContent = Pomodoro.isBreak(state.phase) ? "Skip break" : "Skip to break";
    $("reset").hidden = state.phase === "idle" && state.completedFocus === 0;
    $("hint").textContent = state.phase === "idle"
      ? "Next: " + settings.focus + " minutes of focus."
      : running ? "Ends at " + new Date(state.endsAt ?? now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) + "." : "";

    stats = Pomodoro.statsFor(stats, now);
    $("stat-focus").textContent = String(stats.focusDone);
    $("stat-taken").textContent = String(stats.breaksTaken);
    $("stat-skipped").textContent = String(stats.breaksSkipped);
  }

  function renderSettings() {
    const form = /** @type {HTMLFormElement} */ ($("settings"));
    for (const [name, value] of Object.entries(settings)) {
      const input = /** @type {HTMLInputElement | null} */ (form.elements.namedItem(name));
      if (!input) continue;
      if (input.type === "checkbox") input.checked = value === true;
      else input.value = String(value);
    }
  }

  async function onSettingsChange() {
    const form = /** @type {HTMLFormElement} */ ($("settings"));
    /** @type {Record<string, unknown>} */
    const raw = {};
    for (const name of Object.keys(Pomodoro.DEFAULT_SETTINGS)) {
      const input = /** @type {HTMLInputElement | null} */ (form.elements.namedItem(name));
      if (input) raw[name] = input.type === "checkbox" ? input.checked : input.value;
    }
    settings = Pomodoro.sanitizeSettings(raw);
    await loom.storage.set(KEY_SETTINGS, settings);
    render();
  }

  /** The clock on screen ticks only while someone can see it. */
  function tickWhileVisible() {
    window.clearInterval(ticker);
    if (document.visibilityState === "visible") ticker = window.setInterval(render, 1000);
  }

  // MARK: - Boot

  async function boot() {
    $("start").addEventListener("click", () => startOrResume());
    $("pause").addEventListener("click", () => pause());
    $("skip").addEventListener("click", () => skip());
    $("reset").addEventListener("click", () => reset());
    $("settings").addEventListener("change", () => onSettingsChange());
    document.addEventListener("visibilitychange", tickWhileVisible);

    loom.on("alarm", ({ name }) => {
      if (name === ALARM && state.endsAt !== null && state.endsAt <= Date.now() + 1000) endPhase("time");
    });
    loom.on("overlay.dismissed", ({ reason }) => {
      // The user skipped the break with Loom's button; a timeout is the alarm's to handle.
      if (reason === "user" && Pomodoro.isBreak(state.phase)) endPhase("skip");
    });
    loom.on("command", ({ id }) => {
      if (id === "start") startOrResume();
      else if (id === "pause") pause();
      else if (id === "skip") skip();
    });

    const [storedState, storedSettings, storedStats] = await Promise.all([
      loom.storage.get(KEY_STATE), loom.storage.get(KEY_SETTINGS), loom.storage.get(KEY_STATS),
    ]);
    settings = Pomodoro.sanitizeSettings(storedSettings);
    stats = Pomodoro.statsFor(storedStats, Date.now());
    renderSettings();

    // Loom was closed, or the Mac slept: play out what ended in the meantime.
    const { state: caughtUp, finished } = Pomodoro.catchUp(Pomodoro.sanitizeState(storedState), settings, Date.now());
    for (const phase of finished) {
      if (phase === "focus") await count("focusDone");
      else if (Pomodoro.isBreak(phase)) await count("breaksTaken");
    }
    state = Pomodoro.idle();
    await apply(caughtUp);
    tickWhileVisible();
  }

  window.addEventListener("DOMContentLoaded", () => {
    boot().catch((error) => console.error("[pomodoro] boot", error));
  });
})();
