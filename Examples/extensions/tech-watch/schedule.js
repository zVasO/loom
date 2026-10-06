// @ts-check
// When the morning digest is due — pure functions of `now` (ms since 1970),
// in the Mac's local time. Days are built with the Date constructor, never by
// adding 24 hours: a daylight-saving day is 23 or 25 hours long.

(() => {
  "use strict";

  const root = /** @type {any} */ (globalThis);
  /** @type {TechWatchTypes.Namespace} */
  const TechWatch = (root.TechWatch = root.TechWatch || /** @type {any} */ ({}));

  const HOUR = 3600 * 1000;
  /** A catch-up digest covers three days at most. */
  const MAX_WINDOW = 72 * HOUR;

  /** The slot `daysFromToday` days from now's day. @param {number} now @param {number} hour @param {number} minute @param {number} daysFromToday */
  function slot(now, hour, minute, daysFromToday) {
    const day = new Date(now);
    return new Date(day.getFullYear(), day.getMonth(), day.getDate() + daysFromToday, hour, minute, 0, 0).getTime();
  }

  /** The latest digest time at or before `now`. @param {number} now @param {number} hour @param {number} minute */
  function lastSlotAtOrBefore(now, hour, minute) {
    const today = slot(now, hour, minute, 0);
    return today <= now ? today : slot(now, hour, minute, -1);
  }

  /** The next digest time strictly after `now`. @param {number} now @param {number} hour @param {number} minute */
  function nextSlotAfter(now, hour, minute) {
    const today = slot(now, hour, minute, 0);
    return today > now ? today : slot(now, hour, minute, 1);
  }

  /**
   * Whether a digest time passed with no digest since — Loom was closed, or
   * the Mac asleep. `since` is the last digest, or when the watch started.
   * @param {number} now @param {TechWatchTypes.Settings} settings @param {number | null} since
   */
  function isDigestDue(now, settings, since) {
    if (since === null) return false;
    return since < lastSlotAtOrBefore(now, settings.digestHour, settings.digestMinute);
  }

  /** What a digest covers: since the last one, a day at first, three days at most. @param {number} now @param {number | null} lastDigestAt */
  function digestWindow(now, lastDigestAt) {
    return Math.max(lastDigestAt ?? now - 24 * HOUR, now - MAX_WINDOW);
  }

  TechWatch.schedule = Object.freeze({ lastSlotAtOrBefore, nextSlotAfter, isDigestDue, digestWindow, MAX_WINDOW });
})();
