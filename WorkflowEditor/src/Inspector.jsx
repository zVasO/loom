import React, { useRef } from "react";
import * as G from "./graph.js";

function Field({ label, hint, children }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {hint && <span className="field-hint">{hint}</span>}
    </label>
  );
}

function Checks({ items, selected, onChange, empty, disabled }) {
  if (!items.length) return <div className="muted small">{empty}</div>;
  const set = new Set(selected || []);
  return (
    <div className="checks">
      {items.map((item) => (
        <label key={item.value} className="check" title={item.hint || undefined}>
          <input type="checkbox" disabled={disabled} checked={set.has(item.value)}
            onChange={(e) => {
              const next = new Set(set);
              if (e.target.checked) next.add(item.value); else next.delete(item.value);
              onChange(items.map((i) => i.value).filter((v) => next.has(v)));
            }} />
          <span>{item.label}</span>
        </label>
      ))}
    </div>
  );
}

function PromptEditor({ value, onChange, groups, disabled }) {
  const ref = useRef(null);
  const insert = (variable) => {
    const area = ref.current;
    const token = `{{${variable}}}`;
    if (!area) { onChange(value + token); return; }
    const start = area.selectionStart ?? value.length;
    const end = area.selectionEnd ?? value.length;
    const next = value.slice(0, start) + token + value.slice(end);
    onChange(next);
    requestAnimationFrame(() => {
      area.focus();
      area.selectionStart = area.selectionEnd = start + token.length;
    });
  };
  return (
    <>
      <textarea ref={ref} className="prompt" rows={12} value={value} disabled={disabled}
        placeholder="What this step asks. Name what the run knows with {{…}} — click a variable below."
        onChange={(e) => onChange(e.target.value)} />
      {!disabled && groups.map((group) => (
        <div key={group.label} className="chips">
          <span className="chips-label">{group.label}</span>
          {group.items.map((item) => (
            <button key={item} type="button" className="chip" onClick={() => insert(item)}>{item}</button>
          ))}
        </div>
      ))}
    </>
  );
}

function OutputEditor({ fields, onChange, disabled }) {
  const update = (index, patch) => onChange(fields.map((f, i) => (i === index ? { ...f, ...patch } : f)));
  return (
    <div className="outputs">
      {fields.map((field, index) => (
        <div key={index} className="output-row">
          <div className="output-line">
            <input className="mono" value={field.name} placeholder="name" disabled={disabled}
              onChange={(e) => update(index, { name: e.target.value.replace(/[^A-Za-z0-9_]/g, "") })} />
            <select value={field.type} disabled={disabled} onChange={(e) => update(index, { type: e.target.value })}>
              {G.FIELD_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
            </select>
            <label className="check inline" title="Required">
              <input type="checkbox" checked={field.required !== false} disabled={disabled}
                onChange={(e) => update(index, { required: e.target.checked })} />
              <span>req.</span>
            </label>
            {!disabled && (
              <button type="button" className="icon" title="Remove the field"
                onClick={() => onChange(fields.filter((_, i) => i !== index))}>×</button>
            )}
          </div>
          <input value={field.description || ""} placeholder="What claude puts there" disabled={disabled}
            onChange={(e) => update(index, { description: e.target.value })} />
        </div>
      ))}
      {!disabled && (
        <button type="button" className="ghost"
          onClick={() => onChange([...fields, { name: `field${fields.length + 1}`, type: "text", description: "", required: true }])}>
          + Add a field
        </button>
      )}
    </div>
  );
}

function ConditionEditor({ condition, onChange, disabled, groups }) {
  const value = condition || { path: "", op: "isTrue", value: "" };
  const needsValue = !["isTrue", "isFalse", "isEmpty", "isNotEmpty"].includes(value.op);
  const paths = groups.flatMap((g) => g.items);
  return (
    <>
      <Field label="Tests" hint="A path the run knows, e.g. steps.coherence.stable">
        <input className="mono" list="condition-paths" value={value.path} disabled={disabled}
          onChange={(e) => onChange({ ...value, path: e.target.value })} />
        <datalist id="condition-paths">{paths.map((p) => <option key={p} value={p} />)}</datalist>
      </Field>
      <Field label="Holds when">
        <select value={value.op} disabled={disabled} onChange={(e) => onChange({ ...value, op: e.target.value })}>
          {G.OPERATORS.map((op) => <option key={op} value={op}>{op}</option>)}
        </select>
      </Field>
      {needsValue && (
        <Field label="Value">
          <input value={value.value} disabled={disabled} onChange={(e) => onChange({ ...value, value: e.target.value })} />
        </Field>
      )}
    </>
  );
}

function RunRecord({ record, onOpenSession }) {
  if (!record) return null;
  return (
    <div className="run-record">
      <div className={`status-pill status-${record.status}`}>{record.status}{record.pass > 1 ? ` · pass ${record.pass}` : ""}</div>
      {record.error && <div className="error-text">{record.error}</div>}
      {typeof record.costUSD === "number" && record.costUSD > 0 && <div className="muted small">{record.costUSD.toFixed(3)} $</div>}
      {record.sessionID && <button type="button" className="ghost" onClick={onOpenSession}>Open its session</button>}
      {(record.text || record.output) && (
        <details open>
          <summary>Answer</summary>
          <pre>{record.output ? JSON.stringify(record.output, null, 2) : record.text}</pre>
        </details>
      )}
    </div>
  );
}

/** The run's conductor (ADR-0018): a session that follows the run, questions and steers its steps. */
function OrchestratorPanel({ orchestrator, experts, disabled, run, onChange, onOpen }) {
  const on = !!orchestrator;
  const config = orchestrator || {};
  const set = (patch) => onChange({ ...config, ...patch });
  const whole = (value, max) => Math.max(0, Math.min(max, parseInt(value, 10) || 0));
  return (
    <section className="orchestrator">
      <label className="check orchestrator-toggle">
        <input type="checkbox" checked={on} disabled={disabled}
          onChange={(e) => onChange(e.target.checked ? G.defaultOrchestrator() : null)} />
        <span><b>Orchestrator</b></span>
      </label>
      <p className="muted small">
        A session of its own, under Sessions › Workflows, that follows each run: it reads every answer, asks a
        step a follow-up question, runs a step again with instructions, skips one or stops the run. You talk to it
        there.
      </p>
      {run && run.orchestrator && (
        <div className="run-record">
          <div className="muted small">
            {run.orchestrator.interventions} intervention(s){run.orchestrator.holding ? " · the run waits for it" : ""}
          </div>
          <button type="button" className="ghost" onClick={onOpen}>Open the orchestrator</button>
        </div>
      )}
      {on && (
        <>
          <Field label="Expert" hint="Its instructions and model; the lead reviewer suits a review.">
            <select value={config.expertID || ""} disabled={disabled}
              onChange={(e) => set({ expertID: e.target.value || null })}>
              <option value="">claude, as configured</option>
              {experts.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
            </select>
          </Field>
          <Field label="Model" hint="Over the expert's; empty keeps it.">
            <input value={config.model || ""} disabled={disabled} placeholder="opus, sonnet…"
              onChange={(e) => set({ model: e.target.value.trim() || null })} />
          </Field>
          <Field label="What it should watch" hint="Added to Loom's rules for it. {{pr.title}} and the other run variables work.">
            <textarea rows={6} value={config.instructions || ""} disabled={disabled}
              placeholder="Check that the experts agree; rerun one whose answer is vague…"
              onChange={(e) => set({ instructions: e.target.value })} />
          </Field>
          <div className="row">
            <Field label="Interventions" hint="Questions, reruns and skips in a run.">
              <input type="number" min={0} max={50} value={config.maxInterventions ?? 12} disabled={disabled}
                onChange={(e) => set({ maxInterventions: whole(e.target.value, 50) })} />
            </Field>
            <Field label="Reruns per step">
              <input type="number" min={0} max={5} value={config.maxRerunsPerStep ?? 2} disabled={disabled}
                onChange={(e) => set({ maxRerunsPerStep: whole(e.target.value, 5) })} />
            </Field>
          </div>
          <label className="check">
            <input type="checkbox" checked={config.reviewBeforeArtifact !== false} disabled={disabled}
              onChange={(e) => set({ reviewBeforeArtifact: e.target.checked })} />
            <span>The report waits for its go-ahead</span>
          </label>
        </>
      )}
    </section>
  );
}

export function Inspector({ workflow, node, state, readOnly, run, onChange, onDelete, onOpenSession,
  onWorkflowChange, onOpenOrchestrator }) {
  if (!node) {
    return (
      <div className="inspector">
        <h3>{workflow.name}</h3>
        <p className="muted small">
          Drag a step from the left, or click it to drop it in the middle. Link steps from the dot on the right
          of one to the left of another: several links out run in parallel, several in wait for all.
          A Loop step runs earlier steps again, a few times at most.
        </p>
        <OrchestratorPanel orchestrator={workflow.orchestrator || null} experts={state.experts || []}
          disabled={!!readOnly} run={run} onOpen={onOpenOrchestrator}
          onChange={(orchestrator) => onWorkflowChange && onWorkflowChange({ orchestrator })} />
        {state.issues && state.issues.length > 0 && (
          <div className="issues">
            {state.issues.map((issue) => (
              <div key={issue.id || issue.message} className={`issue ${issue.severity}`}>
                {issue.nodeID ? <b>{issue.nodeID}: </b> : null}{issue.message}
              </div>
            ))}
          </div>
        )}
      </div>
    );
  }
  const disabled = !!readOnly;
  const config = node.config || {};
  const set = (patch) => onChange({ ...node, ...patch });
  const setConfig = (patch) => onChange({ ...node, config: { ...config, ...patch } });
  const groups = G.variablesFor(workflow, node.id);
  const experts = state.experts || [];
  const connectors = state.connectors || [];
  const skills = state.skills || [];
  const record = run && run.nodes ? run.nodes[node.id] : null;
  const nodeIssues = (state.issues || []).filter((i) => i.nodeID === node.id);

  return (
    <div className="inspector">
      <div className="inspector-head">
        <span className={`kind kind-${node.type}`}>{G.KIND_LABELS[node.type]}</span>
        <span className="mono muted small" title="Templates name this step by its id">{node.id}</span>
      </div>
      <Field label="Title">
        <input value={node.title} disabled={disabled} onChange={(e) => set({ title: e.target.value })} />
      </Field>
      <p className="muted small">{G.KIND_HINTS[node.type]}</p>
      {nodeIssues.map((issue) => (
        <div key={issue.message} className={`issue ${issue.severity}`}>{issue.message}</div>
      ))}
      {record && <RunRecord record={record} onOpenSession={() => onOpenSession(node.id)} />}

      {node.type === "start" && (
        <Field label="May be started by">
          <Checks disabled={disabled} selected={config.triggers}
            items={[{ value: "manual", label: "Run button, ⌘K" }, { value: "pullRequest", label: "A PR's tab" },
              { value: "jiraTicket", label: "A Jira key alone" }, { value: "schedule", label: "A review schedule" }]}
            onChange={(triggers) => setConfig({ triggers })} />
        </Field>
      )}

      {node.type === "context" && (
        <>
          <Field label="Loads">
            <select value={config.source} disabled={disabled} onChange={(e) => {
              const source = e.target.value;
              const atlassian = connectors.find((c) => /atlassian/i.test(c.name));
              setConfig({ source, connectorIDs: source === "jiraTicket" && !(config.connectorIDs || []).length && atlassian
                ? [atlassian.id] : config.connectorIDs || [] });
            }}>
              <option value="pullRequest">The pull request — body, files, conversation, checks</option>
              <option value="jiraTicket">The Jira ticket — through an Atlassian connector</option>
              <option value="repository">The repository — tree, README, touched files</option>
            </select>
          </Field>
          {config.source === "jiraTicket" && (
            <Field label="Read through" hint="The ticket key comes from the PR (title, branch, body) or the Run sheet.">
              <Checks disabled={disabled} selected={config.connectorIDs}
                items={connectors.map((c) => ({ value: c.id, label: c.name }))}
                empty="No connector yet: add one in the sidebar, under Connectors."
                onChange={(connectorIDs) => setConfig({ connectorIDs })} />
            </Field>
          )}
        </>
      )}

      {node.type === "agent" && (
        <>
          <Field label="Expert" hint="Its instructions, skills, connectors and tools come along.">
            <select value={config.expertID || ""} disabled={disabled}
              onChange={(e) => setConfig({ expertID: e.target.value || null })}>
              <option value="">None — claude as configured</option>
              {experts.map((e) => <option key={e.id} value={e.id}>{e.name}{e.domain ? ` — ${e.domain}` : ""}</option>)}
            </select>
          </Field>
          <div className="row2">
            <Field label="Runs">
              <select value={config.mode || "headless"} disabled={disabled} onChange={(e) => setConfig({ mode: e.target.value })}>
                <option value="headless">Headless (claude -p)</option>
                <option value="visible">In a visible session</option>
              </select>
            </Field>
            <Field label="Model">
              <input list="models" value={config.model || ""} disabled={disabled}
                placeholder="expert's or default"
                onChange={(e) => setConfig({ model: e.target.value.trim() ? e.target.value.trim() : null })} />
              <datalist id="models"><option value="opus" /><option value="sonnet" /><option value="haiku" /></datalist>
            </Field>
          </div>
          <Field label="Prompt">
            <PromptEditor value={config.prompt || ""} disabled={disabled} groups={groups}
              onChange={(prompt) => setConfig({ prompt })} />
          </Field>
          <Field label="Answer fields" hint="What the next steps can name — claude answers one JSON object.">
            <OutputEditor fields={config.output || []} disabled={disabled} onChange={(output) => setConfig({ output })} />
          </Field>
          <Field label="Skills for this step" hint="Injected into this step only, on top of the expert's.">
            <Checks disabled={disabled} selected={config.skills}
              items={skills.map((s) => ({ value: s.name, label: s.name, hint: s.description }))}
              empty="No skill found in ~/.claude/skills or the project."
              onChange={(next) => setConfig({ skills: next })} />
          </Field>
          <Field label="Connectors for this step">
            <Checks disabled={disabled} selected={config.connectorIDs}
              items={connectors.map((c) => ({ value: c.id, label: c.name }))}
              empty="No connector yet."
              onChange={(connectorIDs) => setConfig({ connectorIDs })} />
          </Field>
          <Field label="Time limit (minutes)">
            <input type="number" min="1" max="240" disabled={disabled}
              value={Math.round((config.timeoutSeconds || 900) / 60)}
              onChange={(e) => setConfig({ timeoutSeconds: Math.max(1, Number(e.target.value) || 15) * 60 })} />
          </Field>
        </>
      )}

      {node.type === "condition" && (
        <ConditionEditor condition={config.condition} disabled={disabled} groups={groups}
          onChange={(condition) => setConfig({ condition })} />
      )}

      {node.type === "loop" && (
        <>
          <Field label="Runs again" hint="Every step on a path from these to the loop runs again.">
            <Checks disabled={disabled} selected={config.targets}
              items={G.loopCandidates(workflow, node.id).map((n) => ({ value: n.id, label: n.title }))}
              empty="Link steps into the loop first."
              onChange={(targets) => setConfig({ targets })} />
          </Field>
          <Field label="Extra passes, at most" hint="2 extra passes: three in all.">
            <input type="number" min="0" max="5" disabled={disabled} value={config.maxIterations ?? 2}
              onChange={(e) => setConfig({ maxIterations: Math.max(0, Math.min(5, Number(e.target.value) || 0)) })} />
          </Field>
          <label className="check">
            <input type="checkbox" disabled={disabled} checked={!!config.stopWhen}
              onChange={(e) => setConfig({ stopWhen: e.target.checked ? { path: "", op: "isTrue", value: "" } : null })} />
            <span>Stop early when…</span>
          </label>
          {config.stopWhen && (
            <ConditionEditor condition={config.stopWhen} disabled={disabled} groups={groups}
              onChange={(stopWhen) => setConfig({ stopWhen })} />
          )}
        </>
      )}

      {node.type === "artifact" && (
        <>
          <Field label="Template">
            <select value={config.template} disabled={disabled} onChange={(e) => setConfig({ template: e.target.value })}>
              {(state.templates || []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </Field>
          <Field label="Theme" hint="A Loom theme: add yours in Settings › Themes.">
            <select value={config.theme} disabled={disabled} onChange={(e) => setConfig({ theme: e.target.value })}>
              <option value="current">The app's theme</option>
              {(state.themes || []).map((t) => <option key={t} value={t}>{t}</option>)}
            </select>
          </Field>
          <label className="check">
            <input type="checkbox" disabled={disabled} checked={!!config.dark}
              onChange={(e) => setConfig({ dark: e.target.checked })} />
            <span>Dark variant</span>
          </label>
          <Field label="Title">
            <input value={config.title || ""} disabled={disabled} onChange={(e) => setConfig({ title: e.target.value })} />
          </Field>
          <label className="check">
            <input type="checkbox" disabled={disabled} checked={!!config.importToPRTab}
              onChange={(e) => setConfig({ importToPRTab: e.target.checked })} />
            <span>Fill the PR tab: summary, pending comments, suggested verdict</span>
          </label>
        </>
      )}

      {!disabled && (
        <button type="button" className="danger" onClick={() => onDelete(node.id)}>Delete this step</button>
      )}
    </div>
  );
}
