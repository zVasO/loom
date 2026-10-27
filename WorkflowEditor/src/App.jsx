import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ReactFlow, ReactFlowProvider, Background, Controls, MiniMap, applyNodeChanges, applyEdgeChanges, useReactFlow,
  MarkerType,
} from "@xyflow/react";
import { call, onEvent } from "./bridge.js";
import * as G from "./graph.js";
import { Inspector } from "./Inspector.jsx";
import { NodeCard } from "./NodeCard.jsx";

const nodeTypes = { loom: NodeCard };
const defaultEdgeOptions = { markerEnd: { type: MarkerType.ArrowClosed, width: 16, height: 16 } };

export function App() {
  return (
    <ReactFlowProvider>
      <Editor />
    </ReactFlowProvider>
  );
}

/** Loom's palette as the page's custom properties: the editor wears the app's theme. */
function applyPalette(palette) {
  if (!palette) return;
  const root = document.documentElement;
  for (const [key, value] of Object.entries(palette)) {
    if (typeof value === "string") root.style.setProperty(`--${key}`, value);
  }
  root.dataset.light = palette.isLight ? "true" : "false";
}

function Editor() {
  const [state, setState] = useState(null);
  const [workflow, setWorkflow] = useState(null);
  const [issues, setIssues] = useState([]);
  const [estimate, setEstimate] = useState(null);
  const [run, setRun] = useState(null);
  const [selected, setSelected] = useState(null);
  const [nodes, setNodes] = useState([]);
  const [edges, setEdges] = useState([]);
  const [saving, setSaving] = useState("saved");
  const [, setTick] = useState(0);
  const history = useRef(new G.History());
  const saveTimer = useRef(null);
  const workflowRef = useRef(null);
  const nodesRef = useRef([]);
  const flow = useReactFlow();
  const readOnly = !!(state && state.readOnly);

  workflowRef.current = workflow;
  nodesRef.current = nodes;

  const apply = useCallback((next) => {
    if (!next || !next.workflow) return;
    applyPalette(next.palette);
    setState(next);
    setWorkflow(next.workflow);
    setIssues(next.issues || []);
    setEstimate(next.estimate || null);
    setRun(next.run || null);
    setSelected(null);
    setSaving("saved");
    history.current = new G.History();
    requestAnimationFrame(() => flow.fitView({ padding: 0.2, duration: 300 }));
  }, [flow]);

  useEffect(() => {
    call("state.get").then(apply).catch(() => {});
    return onEvent((event) => {
      if (event.type === "state") apply(event.state);
      if (event.type === "run") setRun(event.run);
      if (event.type === "library") {
        setState((current) => (current ? { ...current, ...event.library } : current));
      }
    });
  }, [apply]);

  // The flow follows the workflow; React Flow keeps the selection.
  useEffect(() => {
    if (!workflow || !state) return;
    const derived = G.toFlow(workflow, { experts: state.experts, issues, run });
    setNodes((current) => {
      const chosen = new Set(current.filter((n) => n.selected).map((n) => n.id));
      return derived.nodes.map((n) => ({ ...n, selected: chosen.has(n.id), draggable: !readOnly }));
    });
    setEdges(derived.edges);
  }, [workflow, issues, run, state, readOnly]);

  const save = useCallback((next) => {
    clearTimeout(saveTimer.current);
    setSaving("saving");
    saveTimer.current = setTimeout(() => {
      call("workflow.save", { workflow: next })
        .then((result) => {
          if (result) {
            setIssues(result.issues || []);
            setEstimate(result.estimate || null);
          }
          setSaving("saved");
        })
        .catch(() => setSaving("error"));
    }, 400);
  }, []);

  const update = useCallback((next) => {
    if (readOnly || !workflowRef.current) return;
    history.current.push(workflowRef.current);
    setWorkflow(next);
    save(next);
    setTick((t) => t + 1);
  }, [save, readOnly]);

  const undo = useCallback(() => {
    const previous = history.current.undo(workflowRef.current);
    if (previous) { setWorkflow(previous); save(previous); setTick((t) => t + 1); }
  }, [save]);

  const redo = useCallback(() => {
    const next = history.current.redo(workflowRef.current);
    if (next) { setWorkflow(next); save(next); setTick((t) => t + 1); }
  }, [save]);

  useEffect(() => {
    const onKey = (e) => {
      const target = e.target;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT")) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) redo(); else undo();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [undo, redo]);

  const onNodesChange = useCallback((changes) => {
    setNodes((current) => applyNodeChanges(changes, current));
    for (const change of changes) {
      if (change.type === "select" && change.selected) setSelected(change.id);
      if (change.type === "select" && !change.selected) setSelected((s) => (s === change.id ? null : s));
    }
    const removed = changes.filter((c) => c.type === "remove").map((c) => c.id);
    if (removed.length && workflowRef.current) {
      const gone = new Set(removed);
      const remaining = nodesRef.current.filter((n) => !gone.has(n.id));
      update(G.fromFlow(workflowRef.current, remaining, edges));
    }
  }, [edges, update]);

  const onEdgesChange = useCallback((changes) => {
    setEdges((current) => applyEdgeChanges(changes, current));
    const removed = changes.filter((c) => c.type === "remove").map((c) => c.id);
    if (removed.length && workflowRef.current) {
      const gone = new Set(removed);
      update(G.fromFlow(workflowRef.current, nodesRef.current, edges.filter((e) => !gone.has(e.id))));
    }
  }, [edges, update]);

  const onNodeDragStop = useCallback(() => {
    if (workflowRef.current) update(G.fromFlow(workflowRef.current, nodesRef.current, edges));
  }, [edges, update]);

  const onConnect = useCallback((connection) => {
    const current = workflowRef.current;
    if (!current || !G.canConnect(current, connection)) return;
    const branch = connection.sourceHandle === "yes" || connection.sourceHandle === "no" ? connection.sourceHandle : null;
    const edge = { id: `${connection.source}->${connection.target}${branch ? ":" + branch : ""}`,
      from: connection.source, to: connection.target };
    if (branch) edge.branch = branch;
    update({ ...current, edges: [...current.edges, edge] });
  }, [update]);

  const isValidConnection = useCallback((connection) => !!workflowRef.current && G.canConnect(workflowRef.current, connection), []);

  const addNode = useCallback((type, position) => {
    const current = workflowRef.current;
    if (!current) return;
    const node = G.newNode(type, current, position);
    update({ ...current, nodes: [...current.nodes, node] });
    setSelected(node.id);
  }, [update]);

  const onDrop = useCallback((event) => {
    event.preventDefault();
    const type = event.dataTransfer.getData("application/loom-node");
    if (!G.NODE_TYPES.includes(type)) return;
    addNode(type, flow.screenToFlowPosition({ x: event.clientX, y: event.clientY }));
  }, [addNode, flow]);

  const addAtCenter = (type) => {
    const box = document.querySelector(".canvas").getBoundingClientRect();
    addNode(type, flow.screenToFlowPosition({ x: box.left + box.width / 2 - 100, y: box.top + box.height / 2 - 40 }));
  };

  const selectedNode = useMemo(
    () => (workflow && selected ? workflow.nodes.find((n) => n.id === selected) || null : null),
    [workflow, selected]);

  const changeNode = useCallback((node) => {
    const current = workflowRef.current;
    if (!current) return;
    update({ ...current, nodes: current.nodes.map((n) => (n.id === node.id ? node : n)) });
  }, [update]);

  const deleteNode = useCallback((id) => {
    const current = workflowRef.current;
    if (!current) return;
    const remaining = nodesRef.current.filter((n) => n.id !== id);
    update(G.fromFlow(current, remaining, edges));
    setSelected(null);
  }, [edges, update]);

  if (!state || !workflow) {
    return <div className="empty">Choose or create a workflow in the sidebar.</div>;
  }

  const errors = issues.filter((i) => i.severity === "error").length;
  const setMeta = (patch) => update({ ...workflow, ...patch });

  return (
    <div className="editor">
      <header className="bar">
        <span className="dot" style={{ background: workflow.color || "var(--accent)" }} />
        <input className="name" value={workflow.name} disabled={readOnly} aria-label="Workflow name"
          onChange={(e) => setMeta({ name: e.target.value })} />
        <input className="summary" value={workflow.summary || ""} disabled={readOnly} placeholder="What it is for"
          onChange={(e) => setMeta({ summary: e.target.value })} />
        <input className="tags" value={(workflow.tags || []).join(", ")} disabled={readOnly} placeholder="tags"
          onChange={(e) => setMeta({ tags: e.target.value.split(",").map((t) => t.trim()).filter(Boolean) })} />
        <span className="spacer" />
        {!readOnly && (
          <>
            <button type="button" className="icon" title="Undo (⌘Z)" disabled={!history.current.canUndo} onClick={undo}>↶</button>
            <button type="button" className="icon" title="Redo (⇧⌘Z)" disabled={!history.current.canRedo} onClick={redo}>↷</button>
            <span className={`save save-${saving}`}>{saving === "saving" ? "Saving…" : saving === "error" ? "Not saved" : "Saved"}</span>
          </>
        )}
        {estimate && <span className="estimate" title="An order of magnitude, before the run">{G.formatEstimate(estimate)}</span>}
        {errors > 0 && <span className="errors" title={issues.filter((i) => i.severity === "error").map((i) => i.message).join("\n")}>{errors} to fix</span>}
        {readOnly ? (
          <span className="run-banner">Run {run ? run.status : ""} — read only</span>
        ) : (
          <button type="button" className="primary" disabled={errors > 0} onClick={() => call("run.request", {})}>Run…</button>
        )}
      </header>
      <div className="body">
        {!readOnly && (
          <aside className="palette">
            {G.NODE_TYPES.map((type) => (
              <button key={type} type="button" className={`palette-item kind-${type}`} draggable
                title={G.KIND_HINTS[type]}
                onDragStart={(e) => { e.dataTransfer.setData("application/loom-node", type); e.dataTransfer.effectAllowed = "move"; }}
                onClick={() => addAtCenter(type)}>
                <b>{G.KIND_LABELS[type]}</b>
                <span>{G.KIND_HINTS[type]}</span>
              </button>
            ))}
          </aside>
        )}
        <div className="canvas" onDrop={onDrop} onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; }}>
          <ReactFlow
            nodes={nodes} edges={edges} nodeTypes={nodeTypes} defaultEdgeOptions={defaultEdgeOptions}
            onNodesChange={onNodesChange} onEdgesChange={onEdgesChange} onConnect={onConnect}
            onNodeDragStop={onNodeDragStop} isValidConnection={isValidConnection}
            onPaneClick={() => setSelected(null)}
            nodesConnectable={!readOnly} nodesDraggable={!readOnly} elementsSelectable
            deleteKeyCode={readOnly ? null : ["Backspace", "Delete"]}
            snapToGrid snapGrid={[20, 20]} minZoom={0.2} maxZoom={1.6} proOptions={{ hideAttribution: true }}>
            <Background gap={20} size={1.2} />
            <MiniMap pannable zoomable className="minimap" nodeStrokeWidth={2} />
            <Controls showInteractive={false} />
          </ReactFlow>
        </div>
        <Inspector workflow={workflow} node={selectedNode} state={{ ...state, issues }} readOnly={readOnly} run={run}
          onChange={changeNode} onDelete={deleteNode}
          onOpenSession={(nodeID) => call("node.open", { nodeID })} />
      </div>
    </div>
  );
}
