/*
 * Loom Daily — an Obsidian plugin.
 *
 * Every N minutes (30 by default) it reads what the Claude Code sessions on
 * this Mac said since the last pass — Loom's sessions are Claude Code
 * sessions, and their conversations live in ~/.claude/projects/<folder>/
 * <session>.jsonl — asks claude for a line or two per session, and appends
 * them under a heading of today's daily note. Nothing moved: nothing is asked,
 * nothing is written.
 *
 * Plain CommonJS, no build step: Obsidian loads this file as it is. The pure
 * part (`core`) is exported for the tests, which run without Obsidian.
 */
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const childProcess = require("child_process");

let obsidian = null;
try {
  obsidian = require("obsidian");
} catch (_) {
  // The tests: no Obsidian, only the pure part.
}

// ---------------------------------------------------------------------------
// The pure part
// ---------------------------------------------------------------------------

const core = {
  /** The longest a tool's detail is quoted, and a message. */
  detailLimit: 160,
  textLimit: 600,

  /**
   * What a slice of a session's JSONL says: who said what, after `sinceMs`.
   * Returns `{ cwd, branch, sessionId, items: [{ role, text, at }] }`; an
   * unreadable line is skipped.
   */
  readActivity(text, sinceMs) {
    const activity = { cwd: null, branch: null, sessionId: null, items: [] };
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch (_) {
        continue;
      }
      if (entry.cwd) activity.cwd = entry.cwd;
      if (entry.gitBranch) activity.branch = entry.gitBranch;
      if (entry.sessionId) activity.sessionId = entry.sessionId;
      const at = entry.timestamp ? Date.parse(entry.timestamp) : NaN;
      if (!Number.isFinite(at) || at <= sinceMs) continue;
      if (entry.isMeta || entry.isSidechain) continue;
      const message = entry.message;
      if (!message) continue;
      if (entry.type === "user") {
        for (const said of core.userTexts(message.content)) {
          activity.items.push({ role: "user", text: said, at });
        }
      } else if (entry.type === "assistant" && Array.isArray(message.content)) {
        for (const block of message.content) {
          if (block.type === "text" && block.text && block.text.trim()) {
            activity.items.push({ role: "claude", text: core.clip(block.text, core.textLimit), at });
          } else if (block.type === "tool_use") {
            activity.items.push({ role: "tool", text: core.toolLine(block.name, block.input || {}), at });
          }
        }
      }
    }
    return activity;
  },

  /** A user's words: not a tool's result, not a slash command's plumbing. */
  userTexts(content) {
    const texts = [];
    const take = (raw) => {
      if (typeof raw !== "string") return;
      const text = raw.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim();
      if (!text || text.startsWith("<command-") || text.startsWith("<local-command")) return;
      texts.push(core.clip(text, core.textLimit));
    };
    if (typeof content === "string") {
      take(content);
    } else if (Array.isArray(content)) {
      for (const block of content) {
        if (block && block.type === "text") take(block.text);
      }
    }
    return texts;
  },

  /** "Bash: swift test", "Edit: Sources/App.swift". */
  toolLine(name, input) {
    const detail = input.command || input.file_path || input.path || input.pattern || input.url
      || input.description || "";
    const short = core.clip(String(detail).split("\n")[0], core.detailLimit);
    return short ? `${name}: ${short}` : name;
  },

  clip(text, limit) {
    const flat = String(text).replace(/\s+/g, " ").trim();
    return flat.length > limit ? flat.slice(0, limit - 1) + "…" : flat;
  },

  /** "loom (claude/fix-cache)": a session as the note names it. */
  sessionLabel(activity) {
    const project = activity.cwd ? path.basename(activity.cwd) : "session";
    return activity.branch && activity.branch !== "HEAD" ? `${project} (${activity.branch})` : project;
  },

  /**
   * What claude is asked: each session's last moves, at most `budget`
   * characters in all, the latest kept when there is more.
   */
  buildPrompt(sessions, { language = "French", budget = 14000 } = {}) {
    const perSession = Math.max(800, Math.floor(budget / Math.max(1, sessions.length)));
    const parts = sessions.map((session) => {
      const lines = session.items.map((item) => `${item.role}: ${item.text}`);
      let body = lines.join("\n");
      if (body.length > perSession) body = "…\n" + body.slice(body.length - perSession);
      return `### ${core.sessionLabel(session)}\n${body}`;
    });
    return [
      `Below is what happened in ${sessions.length} Claude Code session(s) over the last minutes.`,
      `Write, in ${language}, one Markdown bullet per session for a daily note: what was done or decided,`,
      `in one short sentence (two at most), past tense, concrete (files, features, bugs), no preamble,`,
      `no closing remark, nothing else than the bullets. Start each bullet with "- **<label>** : " using`,
      `the label after "###". Skip a session where nothing meaningful happened.`,
      "",
      parts.join("\n\n"),
    ].join("\n");
  },

  /** The note's text with `block` added at the end of the `heading` section. */
  insertUnderHeading(note, heading, block) {
    const text = note.replace(/\s+$/, "");
    const lines = text ? text.split("\n") : [];
    const level = (heading.match(/^#+/) || ["#"])[0].length;
    const start = lines.findIndex((line) => line.trim() === heading.trim());
    if (start === -1) {
      return (text ? text + "\n\n" : "") + heading + "\n" + block.replace(/\s+$/, "") + "\n";
    }
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
      const match = lines[i].match(/^(#+)\s/);
      if (match && match[1].length <= level) {
        end = i;
        break;
      }
    }
    // After the section's last non-blank line.
    let insertAt = end;
    while (insertAt > start + 1 && !lines[insertAt - 1].trim()) insertAt--;
    const added = block.replace(/\s+$/, "").split("\n");
    lines.splice(insertAt, 0, ...added);
    return lines.join("\n") + "\n";
  },

  /** "14:30" and the bullets under it. */
  formatBlock(time, summary) {
    const bullets = summary.trim().split("\n").filter((line) => line.trim()).map((line) => {
      const trimmed = line.trim();
      return trimmed.startsWith("- ") || trimmed.startsWith("* ") ? "  " + trimmed : "  - " + trimmed;
    });
    return [`- ${time}`, ...bullets].join("\n");
  },

  /** The part of a file read since `offset` that ends on a whole line. */
  wholeLines(text) {
    const last = text.lastIndexOf("\n");
    return last === -1 ? { text: "", consumed: 0 } : { text: text.slice(0, last + 1), consumed: last + 1 };
  },
};

// ---------------------------------------------------------------------------
// The plugin
// ---------------------------------------------------------------------------

const DEFAULTS = {
  enabled: true,
  intervalMinutes: 30,
  heading: "## Loom",
  language: "French",
  model: "haiku",
  claudePath: "",
  projectsDir: "~/.claude/projects",
  dailyFolder: "",
  dailyFormat: "",
  // Kept by the plugin.
  lastRun: 0,
  offsets: {},
};

/** Where a summary is asked from: never itself summarized. */
const WORKDIR = path.join(os.tmpdir(), "loom-daily");

function expand(p) {
  return p && p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

/** claude, where an installer puts it: Obsidian's PATH is the GUI's, short. */
function findClaude(configured) {
  const candidates = [
    configured,
    path.join(os.homedir(), ".local/bin/claude"),
    path.join(os.homedir(), ".claude/local/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ].filter(Boolean).map(expand);
  return candidates.find((candidate) => {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return true;
    } catch (_) {
      return false;
    }
  });
}

function runClaude(binary, model, prompt) {
  fs.mkdirSync(WORKDIR, { recursive: true });
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn(binary, ["-p", "--model", model, "--output-format", "text"], {
      cwd: WORKDIR,
      env: { ...process.env, PATH: `${process.env.PATH || ""}:/opt/homebrew/bin:/usr/local/bin` },
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), 180000);
    child.stdout.on("data", (chunk) => (out += chunk));
    child.stderr.on("data", (chunk) => (err += chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0 && out.trim()) resolve(out.trim());
      else reject(new Error(err.trim() || `claude exited with ${code}`));
    });
    child.stdin.end(prompt);
  });
}

if (obsidian) {
  const { Plugin, PluginSettingTab, Setting, Notice, normalizePath, moment } = obsidian;

  class LoomDailyPlugin extends Plugin {
    async onload() {
      this.settings = Object.assign({}, DEFAULTS, await this.loadData());
      this.running = false;
      this.addSettingTab(new LoomDailySettings(this.app, this));
      this.addCommand({
        id: "summarize-now",
        name: "Summarize the sessions now",
        callback: () => this.pass(true),
      });
      this.schedule();
    }

    schedule() {
      if (this.timer) window.clearInterval(this.timer);
      this.timer = null;
      if (!this.settings.enabled) return;
      const minutes = Math.max(5, Number(this.settings.intervalMinutes) || 30);
      this.timer = window.setInterval(() => this.pass(false), minutes * 60000);
      this.registerInterval(this.timer);
    }

    async save() {
      await this.saveData(this.settings);
    }

    /** The daily note's path, as the Daily notes core plugin names it unless set here. */
    dailyPath() {
      const daily = this.app.internalPlugins?.getPluginById?.("daily-notes")?.instance?.options || {};
      const folder = (this.settings.dailyFolder || daily.folder || "").replace(/\/+$/, "");
      const format = this.settings.dailyFormat || daily.format || "YYYY-MM-DD";
      const name = moment().format(format) + ".md";
      return normalizePath(folder ? `${folder}/${name}` : name);
    }

    /**
     * What every session wrote since the last pass, and where each file was
     * read up to — kept only once the summary is in the note: a pass that
     * fails leaves the activity for the next one.
     */
    collect(sinceMs) {
      const root = expand(this.settings.projectsDir);
      const sessions = [];
      const offsets = {};
      sessions.offsets = offsets;
      let folders = [];
      try {
        folders = fs.readdirSync(root);
      } catch (_) {
        return sessions;
      }
      for (const folder of folders) {
        const dir = path.join(root, folder);
        let files = [];
        try {
          files = fs.readdirSync(dir).filter((name) => name.endsWith(".jsonl"));
        } catch (_) {
          continue;
        }
        for (const name of files) {
          const file = path.join(dir, name);
          let stat;
          try {
            stat = fs.statSync(file);
          } catch (_) {
            continue;
          }
          if (stat.mtimeMs <= sinceMs) continue;
          // From where the last pass stopped; a file that shrank is read again.
          let offset = this.settings.offsets[file] || 0;
          if (offset > stat.size) offset = 0;
          if (offset === stat.size) continue;
          const length = stat.size - offset;
          const buffer = Buffer.alloc(length);
          const fd = fs.openSync(file, "r");
          try {
            fs.readSync(fd, buffer, 0, length, offset);
          } finally {
            fs.closeSync(fd);
          }
          const { text, consumed } = core.wholeLines(buffer.toString("utf8"));
          offsets[file] = offset + consumed;
          const activity = core.readActivity(text, sinceMs);
          if (activity.cwd && path.resolve(activity.cwd).startsWith(WORKDIR)) continue;
          if (activity.items.some((item) => item.role !== "tool")) sessions.push(activity);
        }
      }
      return sessions;
    }

    async pass(asked) {
      if (this.running) return;
      this.running = true;
      try {
        const now = Date.now();
        // The first pass starts at the beginning of the day, not of history.
        const since = this.settings.lastRun || moment().startOf("day").valueOf();
        const sessions = this.collect(since);
        const commit = () => Object.assign(this.settings.offsets, sessions.offsets);
        if (!sessions.length) {
          commit();
          this.settings.lastRun = now;
          await this.save();
          if (asked) new Notice("Loom Daily: nothing new since the last pass.");
          return;
        }
        const binary = findClaude(this.settings.claudePath);
        if (!binary) {
          new Notice("Loom Daily: claude was not found — set its path in the plugin's settings.");
          return;
        }
        const summary = await runClaude(binary, this.settings.model,
          core.buildPrompt(sessions, { language: this.settings.language }));
        await this.append(core.formatBlock(moment(now).format("HH:mm"), summary));
        commit();
        this.settings.lastRun = now;
        await this.save();
        if (asked) new Notice(`Loom Daily: ${sessions.length} session(s) summarized.`);
      } catch (error) {
        new Notice(`Loom Daily: ${error.message || error}`);
      } finally {
        this.running = false;
      }
    }

    async append(block) {
      const target = this.dailyPath();
      const vault = this.app.vault;
      let file = vault.getAbstractFileByPath(target);
      if (!file) {
        const folder = target.includes("/") ? target.slice(0, target.lastIndexOf("/")) : "";
        if (folder && !vault.getAbstractFileByPath(folder)) await vault.createFolder(folder);
        file = await vault.create(target, "");
      }
      await vault.process(file, (text) => core.insertUnderHeading(text, this.settings.heading, block));
    }
  }

  class LoomDailySettings extends PluginSettingTab {
    constructor(app, plugin) {
      super(app, plugin);
      this.plugin = plugin;
    }

    display() {
      const { containerEl } = this;
      const plugin = this.plugin;
      const settings = plugin.settings;
      containerEl.empty();
      const text = (name, desc, key, placeholder, after) =>
        new Setting(containerEl).setName(name).setDesc(desc).addText((field) =>
          field.setPlaceholder(placeholder || "").setValue(String(settings[key] ?? "")).onChange(async (value) => {
            settings[key] = value;
            await plugin.save();
            if (after) after();
          }));

      new Setting(containerEl).setName("Summarize automatically").addToggle((toggle) =>
        toggle.setValue(settings.enabled).onChange(async (value) => {
          settings.enabled = value;
          await plugin.save();
          plugin.schedule();
        }));
      text("Every (minutes)", "How often the sessions are summarized. 5 at least.", "intervalMinutes", "30",
        () => plugin.schedule());
      text("Heading", "The section of the daily note the summaries go under.", "heading", "## Loom");
      text("Language", "The language the summaries are written in.", "language", "French");
      text("Model", "claude's model for the summaries: haiku is quick and cheap.", "model", "haiku");
      text("claude", "Path to the claude command, when it is not found by itself.", "claudePath",
        "~/.local/bin/claude");
      text("Conversations", "Where Claude Code keeps its sessions.", "projectsDir", "~/.claude/projects");
      text("Daily notes folder", "Empty: the Daily notes plugin's folder.", "dailyFolder", "");
      text("Daily note format", "Empty: the Daily notes plugin's format (moment.js).", "dailyFormat", "YYYY-MM-DD");
      new Setting(containerEl).setName("Summarize now").setDesc("What happened since the last pass.")
        .addButton((button) => button.setButtonText("Run").onClick(() => plugin.pass(true)));
    }
  }

  module.exports = LoomDailyPlugin;
  module.exports.default = LoomDailyPlugin;
}

module.exports = module.exports || {};
module.exports.core = core;
