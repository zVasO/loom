// @ts-check
/// <reference path="../loom.d.ts" />
/// <reference path="./pomodoro.d.ts" />

// The break page, shown over Loom by app.js (loom.ui.presentOverlay). It only
// displays: the time left, a suggestion, and what the agents are doing — so
// the break costs nothing. Loom draws the "Skip break" button itself.

(() => {
  "use strict";

  const TIPS = [
    "Stand up and stretch your back.",
    "Look at something far away for twenty seconds.",
    "Refill your glass of water.",
    "Walk around the room — or the block.",
    "Roll your shoulders, unclench your jaw.",
    "Open a window and take a few slow breaths.",
  ];

  /** @type {PomodoroTypes.TimerState} */ let state = Pomodoro.idle();

  /** @param {string} id */
  function $(id) {
    const element = document.getElementById(id);
    if (!element) throw new Error("missing #" + id);
    return element;
  }

  function renderClock() {
    $("break-kind").textContent = state.phase === "longBreak" ? "Long break" : "Break";
    $("break-clock").textContent = Pomodoro.format(Pomodoro.remaining(state, Date.now()));
  }

  /** @param {Loom.Session[]} sessions */
  function renderSessions(sessions) {
    const working = sessions.filter((session) => session.state === "working").length;
    const waiting = sessions.filter((session) => session.state === "needs_input").length;
    const parts = [];
    if (working > 0) parts.push(working + (working === 1 ? " agent is" : " agents are") + " working");
    if (waiting > 0) parts.push(waiting + (waiting === 1 ? " waits" : " wait") + " for you — it will keep");
    $("break-sessions").textContent = parts.length > 0 ? parts.join(" · ") + "." : "No agent is running.";
  }

  async function boot() {
    const [stored, sessions] = await Promise.all([
      loom.storage.get("timer"),
      loom.sessions.list().catch(() => /** @type {Loom.Session[]} */ ([])),
    ]);
    state = Pomodoro.sanitizeState(stored);
    $("break-tip").textContent = TIPS[Math.floor(Date.now() / 60000) % TIPS.length];
    renderClock();
    renderSessions(sessions);
    window.setInterval(renderClock, 1000);
    loom.on("sessions.changed", ({ sessions: next }) => renderSessions(next));
  }

  window.addEventListener("DOMContentLoaded", () => {
    boot().catch((error) => console.error("[pomodoro] break", error));
  });
})();
