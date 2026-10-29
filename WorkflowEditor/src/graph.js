// The editor's pure side (ADR-0017): a Loom workflow ⇄ React Flow's nodes
// and edges, the defaults of each kind of step, ids, and what a prompt may
// name. No DOM, no React: node --test runs it (Tests/WorkflowEditorJS).

export const NODE_TYPES = ["start", "context", "agent", "condition", "loop", "artifact", "approval", "forEach",
  "command"];

export const KIND_LABELS = {
  start: "Start",
  context: "Context",
  agent: "Agent",
  condition: "Condition",
  loop: "Loop",
  artifact: "Artifact",
  approval: "Approval",
  forEach: "For each",
  command: "Command",
};

export const KIND_HINTS = {
  start: "Where a run begins, and what may start it.",
  context: "Loads the PR, the Jira ticket or the repository — no LLM.",
  agent: "One step for an expert: a prompt, an answer with fields.",
  condition: "Takes the Yes or the No path, from what the run knows.",
  loop: "Runs steps again — at most a few times.",
  artifact: "Writes the report in a Loom theme.",
  approval: "You decide: the run waits, your answer picks the next link.",
  forEach: "Runs an agent once per item of a list, then gathers.",
  command: "Runs tests or a linter; pass or fail picks the next link.",
};

export const FIELD_TYPES = ["text", "list", "boolean", "number", "object"];
export const OPERATORS = ["isTrue", "isFalse", "equals", "notEquals", "contains", "isEmpty", "isNotEmpty",
  "greaterThan", "lessThan"];
export const TRIGGERS = ["manual", "pullRequest", "jiraTicket", "schedule"];
export const CONTEXT_SOURCES = ["pullRequest", "jiraTicket", "repository"];

/** `Revue sécurité!` → `revue-securite`; never empty. */
export function slugify(text) {
  const slug = String(text || "")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return slug || "step";
}

/** A step id not taken yet: `php`, then `php-2`… Templates name steps by it. */
export function uniqueId(base, taken) {
  const used = new Set(taken);
  const root = slugify(base);
  if (!used.has(root)) return root;
  let i = 2;
  while (used.has(`${root}-${i}`)) i += 1;
  return `${root}-${i}`;
}

/** The configuration a new step of a kind starts with. */
export function defaultConfig(type) {
  switch (type) {
    case "start": return { triggers: ["manual", "pullRequest"] };
    case "context": return { source: "pullRequest", connectorIDs: [] };
    case "agent": return {
      prompt: "", output: [{ name: "summary", type: "text", description: "", required: true }],
      mode: "headless", skills: [], connectorIDs: [], timeoutSeconds: 900,
    };
    case "condition": return { condition: { path: "", op: "isTrue", value: "" } };
    case "loop": return { targets: [], maxIterations: 2, stopWhen: null };
    case "artifact": return { template: "pr-review", theme: "current", dark: false, title: "{{pr.title}}",
      importToPRTab: false };
    case "approval": return { question: "", options: ["approuver", "refuser"], timeoutHours: null };
    case "forEach": return { items: "", maxItems: 10, concurrency: 3,
      agent: { prompt: "", output: [{ name: "summary", type: "text", description: "", required: true }],
        mode: "headless", skills: [], connectorIDs: [], timeoutSeconds: 900, rules: [], ruleSetIDs: [] } };
    case "command": return { command: "", timeoutSeconds: 600, passCodes: [0], allowOnPullRequests: false };
    default: return {};
  }
}

/** A workflow's orchestrator as it starts when switched on (ADR-0018). */
export function defaultOrchestrator() {
  return { expertID: null, model: null, instructions: "", maxInterventions: 12, maxRerunsPerStep: 2,
    reviewBeforeArtifact: true };
}

/** What the orchestrator did to a step, as its card says it: "rerun ×2", "skipped", "asked 1". */
export function interventionMarks(record) {
  if (!record) return [];
  const marks = [];
  if (record.reruns > 0) marks.push(record.reruns > 1 ? `rerun ×${record.reruns}` : "rerun");
  if (record.skippedByOrchestrator) marks.push("skipped");
  if (record.asked > 0) marks.push(record.asked > 1 ? `asked ${record.asked}×` : "asked");
  return marks;
}

/** A new step at a position, with an id nobody uses. */
export function newNode(type, workflow, position) {
  const ids = workflow.nodes.map((n) => n.id);
  const title = KIND_LABELS[type] || type;
  return { id: uniqueId(type === "agent" ? "agent" : type, ids), title, type,
    position: { x: Math.round(position.x), y: Math.round(position.y) }, config: defaultConfig(type) };
}

/** A step placed from a block of the palette: linked to it, with nothing of its own yet (ADR-0019). */
export function newBlockNode(block, workflow, position) {
  const ids = workflow.nodes.map((n) => n.id);
  return { id: uniqueId(block.name, ids), title: block.name, type: "agent",
    position: { x: Math.round(position.x), y: Math.round(position.y) },
    config: { blockID: block.id, prompt: "", output: [], mode: "headless", skills: [], connectorIDs: [],
      timeoutSeconds: 900, rules: [], ruleSetIDs: [] } };
}

/** A new block's template: a prompt, a summary field, a verdict. */
export function defaultBlock(name = "Nouveau bloc") {
  return { name, summary: "", color: "#6E56CF", rules: [], ruleSetIDs: [],
    template: { prompt: "", output: [{ name: "summary", type: "text", description: "", required: true }],
      mode: "headless", skills: [], connectorIDs: [], timeoutSeconds: 900,
      verdict: { options: ["ok", "à revoir"], guidance: "" } } };
}

function cleanOptions(options) {
  const seen = new Set();
  return (options || []).map((o) => String(o).trim()).filter((o) => {
    const key = o.toLowerCase();
    if (!o || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** What a step placed from a block runs — Loom's BlockResolver, for the editor's chips. */
export function effectiveAgent(config, blocks = []) {
  const block = config && config.blockID ? blocks.find((b) => b.id === config.blockID) : null;
  if (!block) return config || {};
  const own = (config.prompt || "").trim();
  const t = block.template || {};
  return { ...t, blockID: block.id,
    prompt: own ? `${t.prompt || ""}\n\n## For this step\n${own}` : t.prompt || "",
    expertID: config.expertID || t.expertID || null, model: config.model || t.model || null,
    rules: config.rules || [], ruleSetIDs: config.ruleSetIDs || [] };
}

/** The verdict options a step answers; empty: it has none. */
export function verdictOptions(node, blocks = []) {
  if (!node) return [];
  const config = node.config || {};
  switch (node.type) {
    case "agent": return cleanOptions((effectiveAgent(config, blocks).verdict || {}).options);
    case "forEach": return cleanOptions((effectiveAgent(config.agent || {}, blocks).verdict || {}).options);
    case "approval": return cleanOptions(config.options);
    case "command": return ["pass", "fail"];
    default: return [];
  }
}

/** A link's words on the canvas: "if ok", "otherwise", "↺ à revoir ≤2×", "· 2 rules". */
export function edgeLabel(edge) {
  let text;
  if (edge.branch) text = edge.branch === "yes" ? "Yes" : "No";
  else if (edge.retry) text = `↺ ${edge.when || "?"} ≤${edge.retry.max ?? 2}×`;
  else if (edge.when) text = `if ${edge.when}`;
  else if (edge.otherwise) text = "otherwise";
  const rules = (edge.rules || []).filter((r) => String(r).trim()).length + (edge.ruleSetIDs || []).length;
  if (rules) text = (text ? `${text} · ` : "") + `${rules} rule${rules === 1 ? "" : "s"}`;
  return text;
}

/** React Flow's nodes and edges for a workflow; a run's state lights them. */
export function toFlow(workflow, { experts = [], issues = [], run = null, selected = null, blocks = [],
  selectedEdge = null } = {}) {
  const byNode = new Map();
  for (const issue of issues) {
    if (!issue.nodeID) continue;
    if (!byNode.has(issue.nodeID)) byNode.set(issue.nodeID, []);
    byNode.get(issue.nodeID).push(issue);
  }
  const nodes = workflow.nodes.map((node) => {
    const agentConfig = node.type === "agent" ? effectiveAgent(node.config || {}, blocks) : null;
    const expert = agentConfig && agentConfig.expertID ? experts.find((e) => e.id === agentConfig.expertID) : null;
    const block = node.type === "agent" && node.config && node.config.blockID
      ? blocks.find((b) => b.id === node.config.blockID) : null;
    const record = run && run.nodes ? run.nodes[node.id] : null;
    return {
      id: node.id,
      type: "loom",
      position: node.position || { x: 0, y: 0 },
      selected: selected === node.id,
      data: {
        node,
        expert: expert ? { name: expert.name, color: expert.color } : null,
        issues: byNode.get(node.id) || [],
        status: record ? record.status : null,
        pass: record ? record.pass : null,
        error: record ? record.error : null,
        marks: interventionMarks(record),
        block: block ? { name: block.name, color: block.color } : null,
        blockMissing: !!(node.type === "agent" && node.config && node.config.blockID && !block),
        verdicts: verdictOptions(node, blocks),
        verdict: record ? record.verdict || null : null,
        ruleCount: ((node.config && node.config.rules) || []).filter((r) => String(r).trim()).length
          + ((node.config && node.config.ruleSetIDs) || []).length,
      },
    };
  });
  const edges = workflow.edges.map((edge) => {
    const id = edge.id || `${edge.from}->${edge.to}${edge.branch ? ":" + edge.branch : ""}`;
    const classes = [edge.retry ? "retry-edge" : null, edge.when || edge.otherwise ? "conditional-edge" : null,
      selectedEdge === id ? "edge-selected" : null].filter(Boolean);
    return {
      id,
      source: edge.from,
      target: edge.to,
      sourceHandle: edge.retry ? "retry" : edge.branch || null,
      targetHandle: edge.retry ? "back" : null,
      label: edgeLabel(edge),
      className: classes.join(" ") || undefined,
      selected: selectedEdge === id,
      animated: !!(run && run.nodes && run.nodes[edge.from] && run.nodes[edge.from].status === "running"),
      data: { edgeId: id, branch: edge.branch || null, retry: !!edge.retry },
    };
  });
  // A loop's way back, drawn — not a link the user edits.
  for (const node of workflow.nodes) {
    if (node.type !== "loop" || !node.config) continue;
    for (const target of node.config.targets || []) {
      edges.push({
        id: `loop:${node.id}->${target}`, source: node.id, target, sourceHandle: "back", targetHandle: "back",
        selectable: false, deletable: false, focusable: false, className: "loop-edge",
        label: `≤ ${node.config.maxIterations ?? 2}×`, data: { loopBack: true },
      });
    }
  }
  return { nodes, edges };
}

/** Positions and links back from React Flow into the workflow. */
export function fromFlow(workflow, flowNodes, flowEdges) {
  const positions = new Map(flowNodes.map((n) => [n.id, n.position]));
  const kept = new Set(flowNodes.map((n) => n.id));
  const nodes = workflow.nodes
    .filter((n) => kept.has(n.id))
    .map((n) => (positions.has(n.id)
      ? { ...n, position: { x: Math.round(positions.get(n.id).x), y: Math.round(positions.get(n.id).y) } } : n));
  // A link keeps what it carries (its verdict, its rules, its way back); a new one is plain.
  const original = new Map(workflow.edges.map((e) => [e.id || `${e.from}->${e.to}${e.branch ? ":" + e.branch : ""}`, e]));
  const edges = [];
  const seen = new Set();
  for (const edge of flowEdges) {
    if (edge.data && edge.data.loopBack) continue;
    if (!kept.has(edge.source) || !kept.has(edge.target)) continue;
    const known = original.get((edge.data && edge.data.edgeId) || edge.id);
    if (known) {
      if (seen.has(known.id || edge.id)) continue;
      seen.add(known.id || edge.id);
      edges.push(known);
      continue;
    }
    const branch = edge.sourceHandle === "yes" || edge.sourceHandle === "no" ? edge.sourceHandle : null;
    const id = `${edge.source}->${edge.target}${branch ? ":" + branch : ""}`;
    if (seen.has(id)) continue;
    seen.add(id);
    edges.push(branch ? { id, from: edge.source, to: edge.target, branch } : { id, from: edge.source, to: edge.target });
  }
  // A deleted step leaves no loop pointing at it.
  const cleaned = nodes.map((n) => (n.type === "loop" && n.config
    ? { ...n, config: { ...n.config, targets: (n.config.targets || []).filter((t) => kept.has(t)) } } : n));
  return { ...workflow, nodes: cleaned, edges };
}

/**
 * What a link drawn from source to target would be: "forward", a "retry" (it
 * goes back up, from a step with a verdict — ADR-0019), or null (refused:
 * into Start, a duplicate, a circle with no verdict to stop it).
 */
export function connectionKind(workflow, connection, blocks = []) {
  const { source, target, sourceHandle } = connection;
  if (!source || !target || sourceHandle === "back") return null;
  const targetNode = workflow.nodes.find((n) => n.id === target);
  const sourceNode = workflow.nodes.find((n) => n.id === source);
  if (!targetNode || !sourceNode || targetNode.type === "start") return null;
  const goesBack = source === target || createsCycle(workflow, source, target);
  if (goesBack || sourceHandle === "retry") {
    if (!verdictOptions(sourceNode, blocks).length) return null;
    if (workflow.edges.some((e) => e.retry && e.from === source && e.to === target)) return null;
    return goesBack ? "retry" : null;
  }
  const branch = sourceHandle === "yes" || sourceHandle === "no" ? sourceHandle : null;
  if (workflow.edges.some((e) => !e.retry && e.from === source && e.to === target && (e.branch || null) === branch)) {
    return null;
  }
  return "forward";
}

/** Whether a link may be drawn at all. */
export function canConnect(workflow, connection, blocks = []) {
  return connectionKind(workflow, connection, blocks) !== null;
}

/** A way back up as it is first drawn: on the second option (the first that is not good), twice at most. */
export function newRetryEdge(workflow, source, target, blocks = []) {
  const options = verdictOptions(workflow.nodes.find((n) => n.id === source), blocks);
  return { id: `${source}->${target}:retry`, from: source, to: target, when: options[1] || options[0],
    retry: { max: 2 } };
}

/** The link source → target would close a circle (the ways back up aside). */
export function createsCycle(workflow, source, target) {
  const next = new Map();
  for (const e of workflow.edges) {
    if (e.retry) continue;
    if (!next.has(e.from)) next.set(e.from, []);
    next.get(e.from).push(e.to);
  }
  const stack = [target];
  const seen = new Set();
  while (stack.length) {
    const id = stack.pop();
    if (id === source) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    for (const n of next.get(id) || []) stack.push(n);
  }
  return false;
}

/** Steps that run before `id` — what its prompt may name with `steps.*`. */
export function upstream(workflow, id) {
  const previous = new Map();
  for (const e of workflow.edges) {
    if (e.retry) continue;
    if (!previous.has(e.to)) previous.set(e.to, []);
    previous.get(e.to).push(e.from);
  }
  const seen = new Set();
  const stack = [...(previous.get(id) || [])];
  while (stack.length) {
    const n = stack.pop();
    if (seen.has(n)) continue;
    seen.add(n);
    for (const p of previous.get(n) || []) stack.push(p);
  }
  return workflow.nodes.filter((n) => seen.has(n.id));
}

const CONTEXT_FIELDS = {
  pullRequest: ["title", "body", "files", "fileStats", "conversation", "reviews", "checks"],
  jiraTicket: ["found", "key", "summary", "status", "description", "acceptanceCriteria", "comments", "links"],
  repository: ["path", "tree", "readme", "touched"],
};

/** The fields a step answers, whatever its kind. */
export function answerFields(node, blocks = []) {
  const config = node.config || {};
  const withVerdict = (agent) => {
    const effective = effectiveAgent(agent || {}, blocks);
    const fields = (effective.output || []).map((f) => f.name);
    return effective.verdict ? [...fields, "verdict", "verdictReason"] : fields;
  };
  switch (node.type) {
    case "agent": return withVerdict(config);
    case "context": return CONTEXT_FIELDS[config.source] || [];
    case "forEach": return ["items", "results", "verdicts", "count", "failed", "verdict"];
    case "approval": return ["verdict", "comment"];
    case "command": return ["verdict", "exitCode", "stdout", "stderr"];
    default: return [];
  }
}

/** The variables a step's prompt may use, grouped for the inspector's chips. */
export function variablesFor(workflow, id, blocks = []) {
  const groups = [
    { label: "PR", items: ["pr.number", "pr.title", "pr.url", "pr.author", "pr.base", "pr.head", "pr.body"] },
    { label: "Run", items: ["ticket.key", "repo.name", "repo.path", "run.note", "iteration"] },
  ];
  const self = workflow.nodes.find((n) => n.id === id);
  if (self && self.type === "forEach") groups.push({ label: "This item", items: ["item", "index"] });
  const direct = workflow.edges.filter((e) => !e.retry && e.to === id)
    .map((e) => workflow.nodes.find((n) => n.id === e.from)).filter(Boolean);
  const inputs = new Set(["in.text"]);
  for (const node of direct) for (const field of answerFields(node, blocks)) inputs.add(`in.${field}`);
  groups.push({ label: "Right before (in)", items: [...inputs] });
  const steps = [];
  for (const node of upstream(workflow, id)) {
    if (node.type === "start" || node.type === "condition" || node.type === "loop") continue;
    for (const field of [...answerFields(node, blocks), "text"]) steps.push(`steps.${node.id}.${field}`);
  }
  if (steps.length) groups.push({ label: "Steps before", items: steps });
  const previous = workflow.nodes
    .filter((n) => n.type === "agent" && n.id !== id)
    .map((n) => `previous.${n.id}`);
  if (previous.length) groups.push({ label: "Previous pass", items: previous });
  return groups;
}

/** Steps a loop may run again: those before it. */
export function loopCandidates(workflow, loopID) {
  return upstream(workflow, loopID).filter((n) => n.type !== "start");
}

/** Bounded undo history of workflow snapshots. */
export class History {
  constructor(limit = 60) {
    this.limit = limit;
    this.past = [];
    this.future = [];
  }
  push(snapshot) {
    const text = JSON.stringify(snapshot);
    if (this.past.length && this.past[this.past.length - 1] === text) return;
    this.past.push(text);
    if (this.past.length > this.limit) this.past.shift();
    this.future = [];
  }
  undo(current) {
    if (!this.past.length) return null;
    this.future.push(JSON.stringify(current));
    return JSON.parse(this.past.pop());
  }
  redo(current) {
    if (!this.future.length) return null;
    this.past.push(JSON.stringify(current));
    return JSON.parse(this.future.pop());
  }
  get canUndo() { return this.past.length > 0; }
  get canRedo() { return this.future.length > 0; }
}

/** "≈ 17 claude runs · 0.80–4.00 $" */
export function formatEstimate(estimate) {
  if (!estimate) return "";
  const runs = `≈ ${estimate.runs} claude run${estimate.runs === 1 ? "" : "s"}`;
  if (typeof estimate.lowUSD !== "number" || typeof estimate.highUSD !== "number") return runs;
  return `${runs} · ${estimate.lowUSD.toFixed(2)}–${estimate.highUSD.toFixed(2)} $`;
}
