// Input.dispatchMouseEvent and Input.dispatchKeyEvent as the engine builds
// them (design §3.4, LoomChromium's CDPInput), checked by input-click.test.mjs
// and keys.test.mjs.
export const MODIFIERS = Object.freeze({ Alt: 1, Control: 2, Meta: 4, Shift: 8 });
const BUTTONS = { left: 1, right: 2, middle: 4, none: 0 };

export function mouseMove(x, y, { modifiers = 0 } = {}) {
  return ["Input.dispatchMouseEvent", { type: "mouseMoved", x, y, button: "none", buttons: 0, modifiers, pointerType: "mouse" }];
}

/** moved, pressed, released: sent in one write, raced against a dialog the click may open. */
export function mouseClick(x, y, { button = "left", clickCount = 1, modifiers = 0 } = {}) {
  return [
    mouseMove(x, y, { modifiers }),
    ...mousePress(x, y, { button, clickCount, modifiers }),
  ];
}

/** pressed, released only: the second pair of a double click, sent after the first pair's acks. */
export function mousePress(x, y, { button = "left", clickCount = 1, modifiers = 0 } = {}) {
  const common = { x, y, button, clickCount, modifiers, pointerType: "mouse" };
  return [
    ["Input.dispatchMouseEvent", { type: "mousePressed", ...common, buttons: BUTTONS[button] }],
    ["Input.dispatchMouseEvent", { type: "mouseReleased", ...common, buttons: 0 }],
  ];
}

export const KEYS = Object.freeze({
  // Enter submits only as a keyDown carrying "\r" (not rawKeyDown, not "\n").
  Enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
  // No text: the native default action (focus traversal) runs.
  Tab: { key: "Tab", code: "Tab", keyCode: 9 },
  Escape: { key: "Escape", code: "Escape", keyCode: 27 },
  Backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
  Delete: { key: "Delete", code: "Delete", keyCode: 46 },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
  Space: { key: " ", code: "Space", keyCode: 32, text: " " },
  Shift: { key: "Shift", code: "ShiftLeft", keyCode: 16 },
  Control: { key: "Control", code: "ControlLeft", keyCode: 17 },
  Alt: { key: "Alt", code: "AltLeft", keyCode: 18 },
  Meta: { key: "Meta", code: "MetaLeft", keyCode: 91 },
});

/** A printable ASCII letter or digit, as a US keyboard types it. */
export function charKey(character) {
  if (/^[a-z]$/.test(character)) return { key: character, code: `Key${character.toUpperCase()}`, keyCode: character.toUpperCase().charCodeAt(0), text: character };
  if (/^[A-Z]$/.test(character)) return { key: character, code: `Key${character}`, keyCode: character.charCodeAt(0), text: character, shift: true };
  if (/^[0-9]$/.test(character)) return { key: character, code: `Digit${character}`, keyCode: character.charCodeAt(0), text: character };
  if (character === " ") return KEYS.Space;
  throw new Error(`no key for ${JSON.stringify(character)}: such text goes through Input.insertText`);
}

function keyEvent(type, spec, modifiers, extra = {}) {
  return ["Input.dispatchKeyEvent", {
    type, key: spec.key, code: spec.code, windowsVirtualKeyCode: spec.keyCode, nativeVirtualKeyCode: spec.keyCode, modifiers, ...extra,
  }];
}

/**
 * Modifier downs, the key's down and up, modifier ups in reverse. A key with
 * text goes down as keyDown (keypress and input follow), any other as
 * rawKeyDown; under Control, Alt or Meta a key types no text (as Playwright).
 * `commands` (macOS editing commands such as "selectAll") are attached only
 * when given: Chromium runs them whatever the modifiers.
 */
export function keyPress(spec, { modifiers = [], commands } = {}) {
  const held = [...modifiers, ...(spec.shift && !modifiers.includes("Shift") ? ["Shift"] : [])];
  const events = [];
  let mask = 0;
  for (const name of held) {
    mask |= MODIFIERS[name];
    events.push(keyEvent("rawKeyDown", KEYS[name], mask));
  }
  const typesText = spec.text && !held.some((name) => name !== "Shift");
  const down = typesText
    ? keyEvent("keyDown", spec, mask, { text: spec.text, unmodifiedText: spec.text.toLowerCase() })
    : keyEvent("rawKeyDown", spec, mask);
  if (commands) down[1].commands = commands;
  events.push(down, keyEvent("keyUp", spec, mask));
  for (const name of [...held].reverse()) {
    mask &= ~MODIFIERS[name];
    events.push(keyEvent("keyUp", KEYS[name], mask));
  }
  return events;
}
