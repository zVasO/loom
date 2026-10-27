// The editor's pure side (ADR-0017): a Loom workflow ⇄ React Flow's nodes
// and edges, the defaults of each kind of step, ids, and what a prompt may
// name. No DOM, no React: node --test runs it (Tests/WorkflowEditorJS).

export const NODE_TYPES = ["start", "context", "agent", "condition", "loop", "artifact"];

export const KIND_LABELS = {
  start: "Start",
  context: "Context",
  agent: "Agent",
  condition: "Condition",
  loop: "Loop",
  artifact: "Artifact",
};

export const KIND_HINTS = {
  start: "Where a run begins, and what may start it.",
  context: "Loads the PR, the Jira ticket or the repository — no LLM.",
  agent: "One step for an expert: a prompt, an answer with fields.",
  condition: "Takes the Yes or the No path, from what the run knows.",
  loop: "Runs steps again — at most a few times.",
  artifact: "Writes the report in a Loom theme.",
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

/** React Flow's nodes and edges for a workflow; a run's state lights them. */
export function toFlow(workflow, { experts = [], issues = [], run = null, selected = null } = {}) {
  const byNode = new Map();
  for (const issue of issues) {
    if (!issue.nodeID) continue;
    if (!byNode.has(issue.nodeID)) byNode.set(issue.nodeID, []);
    byNode.get(issue.nodeID).push(issue);
  }
  const nodes = workflow.nodes.map((node) => {
    const expert = node.type === "agent" && node.config && node.config.expertID
      ? experts.find((e) => e.id === node.config.expertID) : null;
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
      },
    };
  });
  const edges = workflow.edges.map((edge) => ({
    id: edge.id || `${edge.from}->${edge.to}${edge.branch ? ":" + edge.branch : ""}`,
    source: edge.from,
    target: edge.to,
    sourceHandle: edge.branch || null,
    label: edge.branch === "yes" ? "Yes" : edge.branch === "no" ? "No" : undefined,
    animated: !!(run && run.nodes && run.nodes[edge.from] && run.nodes[edge.from].status === "running"),
    data: { branch: edge.branch || null },
  }));
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
  const edges = [];
  const seen = new Set();
  for (const edge of flowEdges) {
    if (edge.data && edge.data.loopBack) continue;
    if (!kept.has(edge.source) || !kept.has(edge.target)) continue;
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

/** Whether a link may be drawn: no self-link, no duplicate, nothing into Start. */
export function canConnect(workflow, connection) {
  const { source, target, sourceHandle } = connection;
  if (!source || !target || source === target) return false;
  if (sourceHandle === "back") return false;
  const targetNode = workflow.nodes.find((n) => n.id === target);
  if (!targetNode || targetNode.type === "start") return false;
  const branch = sourceHandle === "yes" || sourceHandle === "no" ? sourceHandle : null;
  return !workflow.edges.some((e) => e.from === source && e.to === target && (e.branch || null) === branch)
    && !createsCycle(workflow, source, target);
}

/** The link source → target would close a circle (loops go through a Loop step). */
export function createsCycle(workflow, source, target) {
  const next = new Map();
  for (const e of workflow.edges) {
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

/** The variables a step's prompt may use, grouped for the inspector's chips. */
export function variablesFor(workflow, id) {
  const groups = [
    { label: "PR", items: ["pr.number", "pr.title", "pr.url", "pr.author", "pr.base", "pr.head", "pr.body"] },
    { label: "Run", items: ["ticket.key", "repo.name", "repo.path", "run.note", "iteration"] },
  ];
  const steps = [];
  for (const node of upstream(workflow, id)) {
    if (node.type === "start" || node.type === "condition" || node.type === "loop") continue;
    let fields = [];
    if (node.type === "agent") fields = (node.config.output || []).map((f) => f.name);
    if (node.type === "context") fields = CONTEXT_FIELDS[node.config.source] || [];
    for (const field of [...fields, "text"]) steps.push(`steps.${node.id}.${field}`);
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
