// Turns a wire recording (Connection.startRecording) into the trace format
// LoomChromium's SettleMachine tests replay (fixtures/traces/*.json):
// one tab's events, the action's commands and replies, times in ms from the
// mark (negative before it), ids replaced by stable tokens — F1 for a frame,
// L1 for a loader (a navigation's Document request keeps its loader's token:
// Chromium gives both the same id), R1 for any other request — and the
// fixture server's origin by "{origin}". Only the fields a settle decision
// reads are kept.
const PAGE_EVENTS = new Set([
  "Page.frameAttached", "Page.frameDetached", "Page.frameRequestedNavigation", "Page.frameStartedNavigating",
  "Page.frameStartedLoading", "Page.frameStoppedLoading", "Page.frameNavigated", "Page.navigatedWithinDocument",
  "Page.documentOpened", "Page.lifecycleEvent", "Page.domContentEventFired", "Page.loadEventFired",
  "Page.javascriptDialogOpening", "Page.javascriptDialogClosed", "Page.fileChooserOpened", "Page.downloadWillBegin",
  "Inspector.targetCrashed",
]);
const NETWORK_EVENTS = new Set([
  "Network.requestWillBeSent", "Network.responseReceived", "Network.loadingFinished", "Network.loadingFailed",
  "Network.requestServedFromCache",
]);

const round = (ms) => Math.round(ms * 10) / 10;

export function makeTokenizer(origin, loaders = new Set()) {
  const tokens = new Map();
  const counters = { F: 0, L: 0, R: 0 };
  const token = (prefix, id) => {
    if (id === undefined || id === null || id === "") return id;
    if (!tokens.has(id)) tokens.set(id, `${prefix}${++counters[prefix]}`);
    return tokens.get(id);
  };
  const url = (value) => (typeof value === "string" ? value.split(origin).join("{origin}") : value);
  // A navigation's Document request has its loader's id: it keeps the loader's token.
  const request = (id) => (loaders.has(id) ? token("L", id) : token("R", id));
  return { token, url, request };
}

/** The fields kept of each event's params, ids and URLs normalised. */
function pick(method, params, { token, url, request }) {
  const frame = (id) => token("F", id);
  const loader = (id) => token("L", id);
  switch (method) {
    case "Page.frameAttached": return { frameId: frame(params.frameId), parentFrameId: frame(params.parentFrameId) };
    case "Page.frameDetached": return { frameId: frame(params.frameId), reason: params.reason };
    case "Page.frameRequestedNavigation": return { frameId: frame(params.frameId), reason: params.reason, url: url(params.url), disposition: params.disposition };
    case "Page.frameStartedNavigating": return { frameId: frame(params.frameId), url: url(params.url), loaderId: loader(params.loaderId), navigationType: params.navigationType };
    case "Page.frameStartedLoading":
    case "Page.frameStoppedLoading":
    case "Page.documentOpened":
      return { frameId: frame(params.frameId ?? params.frame?.id) };
    case "Page.frameNavigated": return {
      frame: { id: frame(params.frame.id), parentId: frame(params.frame.parentId), loaderId: loader(params.frame.loaderId), url: url(params.frame.url) },
      type: params.type,
    };
    case "Page.navigatedWithinDocument": return { frameId: frame(params.frameId), url: url(params.url), navigationType: params.navigationType };
    case "Page.lifecycleEvent": return { frameId: frame(params.frameId), loaderId: loader(params.loaderId), name: params.name };
    case "Page.domContentEventFired":
    case "Page.loadEventFired":
      return {};
    case "Page.javascriptDialogOpening": return { type: params.type, message: params.message, url: url(params.url) };
    case "Page.javascriptDialogClosed": return { result: params.result };
    case "Page.fileChooserOpened": return { frameId: frame(params.frameId), mode: params.mode };
    case "Page.downloadWillBegin": return { frameId: frame(params.frameId), url: url(params.url) };
    case "Network.requestWillBeSent": {
      const kept = {
        requestId: request(params.requestId), loaderId: loader(params.loaderId), frameId: frame(params.frameId),
        type: params.type, request: { method: params.request.method, url: url(params.request.url) },
      };
      if (params.redirectResponse) kept.redirectResponse = { status: params.redirectResponse.status };
      return kept;
    }
    case "Network.responseReceived": return {
      requestId: request(params.requestId), loaderId: loader(params.loaderId), frameId: frame(params.frameId),
      type: params.type, response: { status: params.response.status, url: url(params.response.url) },
    };
    case "Network.loadingFinished": return { requestId: request(params.requestId) };
    case "Network.loadingFailed": return {
      requestId: request(params.requestId), type: params.type, errorText: params.errorText,
      canceled: params.canceled ?? false, ...(params.blockedReason ? { blockedReason: params.blockedReason } : {}),
    };
    case "Network.requestServedFromCache": return { requestId: request(params.requestId) };
    case "Inspector.targetCrashed": return {};
    default: return params;
  }
}

/**
 * entries: the recording; sessionId: the tab's; mark: performance.now() at
 * the mark; refs: Map(command id → label, e.g. "click.moved", "barrier").
 */
export function buildTrace({ entries, sessionId, mark, refs, origin }) {
  const loaders = new Set();
  for (const entry of entries) {
    if (entry.sessionId !== sessionId || entry.dir !== "event") continue;
    const params = entry.params || {};
    for (const id of [params.loaderId, params.frame?.loaderId]) if (id) loaders.add(id);
  }
  const tokenizer = makeTokenizer(origin, loaders);
  const out = [];
  let markWritten = false;
  for (const entry of entries) {
    if (!markWritten && entry.at >= mark) {
      out.push({ t: 0, mark: true });
      markWritten = true;
    }
    const t = round(entry.at - mark);
    if (entry.dir === "event") {
      if (entry.sessionId !== sessionId) continue;
      if (!PAGE_EVENTS.has(entry.method) && !NETWORK_EVENTS.has(entry.method)) continue;
      out.push({ t, event: entry.method, params: pick(entry.method, entry.params || {}, tokenizer) });
    } else if (refs.has(entry.id)) {
      const ref = refs.get(entry.id);
      if (entry.dir === "send") {
        const params = entry.method === "Input.dispatchMouseEvent"
          ? { ...entry.params, x: round(entry.params.x), y: round(entry.params.y) }
          : entry.method === "Runtime.callFunctionOn" ? { functionDeclaration: entry.params.functionDeclaration } : entry.params;
        out.push({ t, send: entry.method, ref, params });
      } else {
        const reply = { t, reply: ref };
        if (entry.error) reply.error = entry.error;
        else if (ref === "barrier" && entry.result?.result?.value) reply.value = JSON.parse(entry.result.result.value);
        if (reply.value?.url) reply.value.url = tokenizer.url(reply.value.url);
        out.push(reply);
      }
    }
  }
  if (!markWritten) out.push({ t: 0, mark: true });
  return { entries: out, token: tokenizer.token };
}
