// Types of engine.js, shared by app.js and break.js (checked with tsc --checkJs).
declare namespace PomodoroTypes {
  type Phase = "idle" | "focus" | "shortBreak" | "longBreak";
  interface TimerState {
    phase: Phase;
    endsAt: number | null;
    pausedRemaining: number | null;
    completedFocus: number;
  }
  interface Settings {
    focus: number;
    shortBreak: number;
    longBreak: number;
    longEvery: number;
    autoStartFocus: boolean;
  }
  interface Stats {
    date: string;
    focusDone: number;
    breaksTaken: number;
    breaksSkipped: number;
  }
  interface Engine {
    DEFAULT_SETTINGS: Settings;
    idle(completedFocus?: number): TimerState;
    sanitizeSettings(raw: unknown): Settings;
    sanitizeState(raw: unknown): TimerState;
    isBreak(phase: Phase): boolean;
    isPaused(state: TimerState): boolean;
    durationOf(phase: Phase, settings: Settings): number;
    remaining(state: TimerState, now: number): number;
    startFocus(state: TimerState, settings: Settings, now: number): TimerState;
    pause(state: TimerState, now: number): TimerState;
    resume(state: TimerState, now: number): TimerState;
    finish(state: TimerState, settings: Settings, now: number): TimerState;
    catchUp(state: TimerState, settings: Settings, now: number): { state: TimerState; finished: Phase[] };
    statsFor(raw: unknown, now: number): Stats;
    dayOf(now: number): string;
    format(ms: number): string;
    label(phase: Phase): string;
  }
}

declare const Pomodoro: PomodoroTypes.Engine;
