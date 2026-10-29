import React, { memo } from "react";
import { Handle, Position } from "@xyflow/react";
import { KIND_LABELS } from "./graph.js";

const ICONS = { start: "▶", context: "◎", agent: "✦", condition: "◇", loop: "↻", artifact: "▤", approval: "✋",
  forEach: "⋯", command: "›_" };

const STATUS_LABELS = {
  pending: "Pending", running: "Running", waitingOnUser: "Waiting on you", done: "Done",
  failed: "Failed", skipped: "Skipped",
};

function summary(node, expert, block) {
  const config = node.config || {};
  if (node.type === "agent" && block) {
    return [`Block «${block.name}»`, expert ? expert.name : null].filter(Boolean).join(" · ");
  }
  switch (node.type) {
    case "start": return (config.triggers || []).join(" · ");
    case "context": return { pullRequest: "Pull request", jiraTicket: "Jira ticket", repository: "Repository" }[config.source] || "";
    case "agent": {
      const parts = [expert ? expert.name : "claude"];
      if (config.mode === "visible") parts.push("visible session");
      if (config.model) parts.push(config.model);
      return parts.join(" · ");
    }
    case "condition": return config.condition && config.condition.path ? `${config.condition.path} ${config.condition.op}` : "Not set";
    case "loop": return `up to ${config.maxIterations ?? 2} more pass(es) · ${(config.targets || []).length} step(s)`;
    case "artifact": return `${config.template || "pr-review"} · theme ${config.theme || "current"}`;
    case "approval": return config.question ? config.question.slice(0, 60) : "No question yet";
    case "forEach": return config.items ? `each of ${config.items} · ≤ ${config.maxItems ?? 10}` : "No list yet";
    case "command": return config.command ? config.command.split("\n")[0].slice(0, 48) : "No command yet";
    default: return "";
  }
}

function NodeCardView({ data, selected }) {
  const { node, expert, issues, status, pass, error, marks = [], block = null, blockMissing = false,
    verdicts = [], verdict = null, ruleCount = 0 } = data;
  const errors = issues.filter((i) => i.severity === "error").length;
  const warnings = issues.length - errors;
  const classes = ["loom-node", `kind-${node.type}`];
  if (selected) classes.push("selected");
  if (status) classes.push(`status-${status}`);
  return (
    <div className={classes.join(" ")} title={error || issues.map((i) => i.message).join("\n") || undefined}>
      {node.type !== "start" && <Handle type="target" position={Position.Left} />}
      <Handle type="target" id="back" position={Position.Bottom} className="handle-back" isConnectable={false} />
      <div className="loom-node-head">
        <span className="loom-node-icon"
          style={block && block.color ? { background: block.color } : expert && expert.color ? { background: expert.color } : undefined}>
          {ICONS[node.type]}
        </span>
        <span className="loom-node-kind">{KIND_LABELS[node.type]}</span>
        {errors > 0 && <span className="loom-node-badge error">{errors}</span>}
        {errors === 0 && warnings > 0 && <span className="loom-node-badge warning">{warnings}</span>}
      </div>
      <div className="loom-node-title">{node.title}</div>
      <div className="loom-node-summary">{blockMissing ? "Its block was deleted" : summary(node, expert, block)}</div>
      {(verdicts.length > 0 || ruleCount > 0) && (
        <div className="loom-node-verdicts" title="The verdicts its links may follow">
          {verdicts.map((option) => (
            <span key={option} className={`verdict-chip${verdict && verdict.toLowerCase() === option.toLowerCase() ? " given" : ""}`}>
              {option}
            </span>
          ))}
          {ruleCount > 0 && <span className="rule-chip" title="Rules of this step">§ {ruleCount}</span>}
        </div>
      )}
      <div className="loom-node-id">{node.id}</div>
      {status && (
        <div className={`loom-node-status status-${status}`}>
          {STATUS_LABELS[status] || status}{pass && pass > 1 ? ` · pass ${pass}` : ""}
        </div>
      )}
      {marks.length > 0 && (
        <div className="loom-node-marks" title="What the orchestrator did to this step">
          {marks.map((mark) => <span key={mark} className="loom-node-mark">{mark}</span>)}
        </div>
      )}
      {node.type === "condition" ? (
        <>
          <Handle type="source" id="yes" position={Position.Right} style={{ top: "35%" }} />
          <Handle type="source" id="no" position={Position.Right} style={{ top: "70%" }} />
          <span className="branch-label yes">Yes</span>
          <span className="branch-label no">No</span>
        </>
      ) : node.type !== "artifact" ? (
        <Handle type="source" position={Position.Right} />
      ) : null}
      {node.type === "loop" && (
        <Handle type="source" id="back" position={Position.Bottom} className="handle-back" isConnectable={false} />
      )}
      {node.type !== "loop" && (
        <Handle type="source" id="retry" position={Position.Bottom} className="handle-retry"
          isConnectable={verdicts.length > 0} title="Drag up to a step before: go back there on a verdict" />
      )}
    </div>
  );
}

export const NodeCard = memo(NodeCardView);
