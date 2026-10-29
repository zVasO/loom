// The editor ⇄ Loom (ADR-0017): requests through WebKit's message handler
// `loomWorkflows` (JSON text in, JSON text out), events pushed by Loom
// through `window.loomWorkflowsEvent`. Outside Loom (a test page, a browser)
// a stand-in answers from memory, so the editor still runs.

const listeners = new Set();

window.loomWorkflowsEvent = (event) => {
  for (const listener of listeners) listener(event);
};

export function onEvent(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function handler() {
  return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loomWorkflows;
}

export async function call(method, params = {}) {
  const native = handler();
  if (!native) return standIn(method, params);
  const reply = await native.postMessage(JSON.stringify({ method, params }));
  const parsed = typeof reply === "string" ? JSON.parse(reply) : reply;
  if (!parsed || parsed.ok !== true) throw new Error((parsed && parsed.error) || "Loom did not answer.");
  return parsed.result;
}

// MARK: Stand-in

let memory = null;

function standIn(method, params) {
  if (!memory) memory = window.__loomWorkflowsStandIn || null;
  switch (method) {
    case "state.get": return Promise.resolve(memory);
    case "workflow.save":
      if (memory) memory.workflow = params.workflow;
      return Promise.resolve({ issues: [], estimate: null });
    case "block.create": {
      const block = { ...(params.config ? { template: params.config } : {}), id: `block-${Date.now()}`,
        name: params.name || "Nouveau bloc", summary: "", color: "#6E56CF", rules: [], ruleSetIDs: [],
        template: params.config || { prompt: "", output: [{ name: "summary", type: "text", required: true }],
          verdict: { options: ["ok", "à revoir"], guidance: "" } } };
      if (memory) memory.blocks = [...(memory.blocks || []), block];
      return Promise.resolve(block);
    }
    case "block.save":
      if (memory) memory.blocks = (memory.blocks || []).map((b) => (b.id === params.block.id ? params.block : b));
      return Promise.resolve({ issues: [], estimate: null });
    case "block.usage": return Promise.resolve(0);
    case "block.delete":
      if (memory) memory.blocks = (memory.blocks || []).filter((b) => b.id !== params.id);
      return Promise.resolve(null);
    default: return Promise.resolve(null);
  }
}
