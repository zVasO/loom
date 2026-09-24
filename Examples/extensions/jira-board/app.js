// @ts-check
/// <reference path="../loom.d.ts" />

// Jira Board — a Loom extension (docs/extensions.md). Shows the active sprint
// (or the kanban board) of a Jira Cloud board and starts a Loom session from
// a ticket. Everything remote is rendered with textContent, never innerHTML:
// ticket text is written by other people.

(() => {
  "use strict";

  const SECRET_TOKEN = "apiToken";
  const KEY_CONFIG = "config"; // { site, email }
  const KEY_BOARD = "board"; // board id
  const KEY_PROJECTS = "boardProjects"; // { [boardId]: loomProjectId }
  const KEY_SESSIONS = "issueSessions"; // { [issueKey]: sessionId }
  const FIELDS = "summary,status,assignee,issuetype,priority,description";

  /** @typedef {{ site: string, email: string }} Config */
  /** @typedef {{ id: number, name: string, type: string }} Board */
  /** @typedef {{ name: string, statusIds: string[] }} Column */
  /**
   * @typedef {{ key: string, summary: string, statusId: string, statusName: string,
   *   type: string, priority: string, assignee: string, description: string }} Issue
   */

  const state = {
    /** @type {Config | null} */ config: null,
    /** @type {string | null} */ token: null,
    /** @type {Board[]} */ boards: [],
    /** @type {number | null} */ boardId: null,
    /** @type {Column[]} */ columns: [],
    /** @type {Issue[]} */ issues: [],
    /** @type {Loom.Project[]} */ projects: [],
    /** @type {Record<string, string>} */ boardProjects: {},
    /** @type {Record<string, string>} */ issueSessions: {},
    /** @type {Map<string, Loom.Session>} */ sessions: new Map(),
    /** @type {Issue | null} */ selected: null,
    loading: false,
  };

  /** @param {string} id */
  function $(id) {
    const element = document.getElementById(id);
    if (!element) throw new Error("missing #" + id);
    return element;
  }

  /**
   * @param {string} tag
   * @param {{ className?: string, text?: string, title?: string }} [options]
   * @param {Node[]} [children]
   */
  function el(tag, options = {}, children = []) {
    const element = document.createElement(tag);
    if (options.className) element.className = options.className;
    if (options.text !== undefined) element.textContent = options.text;
    if (options.title) element.title = options.title;
    for (const child of children) element.append(child);
    return element;
  }

  /** @param {string} message @param {"info" | "error"} [kind] */
  function setStatus(message, kind = "info") {
    const status = $("status");
    status.textContent = message;
    status.classList.toggle("error", kind === "error");
  }

  // MARK: - Jira

  /** "https://acme.atlassian.net/jira" or "acme" → "acme.atlassian.net". */
  /** @param {string} input */
  function normalizeSite(input) {
    let site = input.trim().toLowerCase();
    site = site.replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    if (site && !site.includes(".")) site += ".atlassian.net";
    return site;
  }

  /** Basic auth for any Unicode e-mail or token: btoa takes Latin-1 only. */
  /** @param {string} email @param {string} token */
  function basicAuth(email, token) {
    const bytes = new TextEncoder().encode(email + ":" + token);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return "Basic " + btoa(binary);
  }

  class JiraError extends Error {
    /** @param {number} status @param {string} message */
    constructor(status, message) {
      super(message);
      this.status = status;
    }
  }

  /** @param {string} path */
  async function jira(path) {
    if (!state.config || !state.token) throw new JiraError(401, "Not connected");
    const response = await loom.http.fetch("https://" + state.config.site + path, {
      headers: { Accept: "application/json", Authorization: basicAuth(state.config.email, state.token) },
    });
    if (response.status === 401 || response.status === 403) {
      throw new JiraError(response.status, "Jira refused the credentials (" + response.status + ")");
    }
    if (!response.ok) {
      throw new JiraError(response.status, "Jira answered " + response.status + " for " + path.split("?")[0]);
    }
    return response.json();
  }

  async function loadBoards() {
    /** @type {Board[]} */
    const boards = [];
    let startAt = 0;
    for (let page = 0; page < 20; page++) {
      const result = await jira("/rest/agile/1.0/board?maxResults=50&startAt=" + startAt);
      for (const board of result.values || []) {
        boards.push({ id: board.id, name: board.name, type: board.type });
      }
      if (result.isLast || !result.values || result.values.length === 0) break;
      startAt += result.values.length;
    }
    return boards;
  }

  /** @param {number} boardId @returns {Promise<Column[]>} */
  async function loadColumns(boardId) {
    const configuration = await jira("/rest/agile/1.0/board/" + boardId + "/configuration");
    const columns = (configuration.columnConfig && configuration.columnConfig.columns) || [];
    return columns.map((/** @type {any} */ column) => ({
      name: String(column.name),
      statusIds: (column.statuses || []).map((/** @type {any} */ status) => String(status.id)),
    }));
  }

  /** @param {Board} board @returns {Promise<Issue[]>} */
  async function loadIssues(board) {
    let raw = [];
    if (board.type === "scrum") {
      const sprints = await jira("/rest/agile/1.0/board/" + board.id + "/sprint?state=active");
      for (const sprint of sprints.values || []) {
        const result = await jira("/rest/agile/1.0/sprint/" + sprint.id + "/issue?maxResults=100&fields=" + FIELDS);
        raw.push(...(result.issues || []));
      }
    } else {
      const result = await jira("/rest/agile/1.0/board/" + board.id + "/issue?maxResults=100&fields=" + FIELDS);
      raw = result.issues || [];
    }
    return raw.map(toIssue);
  }

  /** @param {any} issue @returns {Issue} */
  function toIssue(issue) {
    const fields = issue.fields || {};
    return {
      key: String(issue.key),
      summary: String(fields.summary || ""),
      statusId: fields.status ? String(fields.status.id) : "",
      statusName: fields.status ? String(fields.status.name) : "",
      type: fields.issuetype ? String(fields.issuetype.name) : "",
      priority: fields.priority ? String(fields.priority.name) : "",
      assignee: fields.assignee ? String(fields.assignee.displayName) : "",
      description: adfToText(fields.description).trim(),
    };
  }

  /** Atlassian Document Format (API v3) or a plain string (v2) → text. */
  /** @param {any} node @returns {string} */
  function adfToText(node) {
    if (node === null || node === undefined) return "";
    if (typeof node === "string") return node;
    if (Array.isArray(node)) return node.map(adfToText).join("");
    switch (node.type) {
      case "text":
        return String(node.text || "");
      case "hardBreak":
        return "\n";
      case "mention":
      case "emoji":
        return String((node.attrs && (node.attrs.text || node.attrs.shortName)) || "");
      case "inlineCard":
        return String((node.attrs && node.attrs.url) || "");
      case "listItem":
        return "• " + adfToText(node.content).trim() + "\n";
      case "codeBlock":
        return "\n" + adfToText(node.content) + "\n\n";
      case "paragraph":
      case "heading":
      case "blockquote":
        return adfToText(node.content) + "\n\n";
      default:
        return adfToText(node.content);
    }
  }

  /** @param {string} name */
  function initials(name) {
    return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0].toUpperCase()).join("");
  }

  // MARK: - Loom

  /** The prompt the session starts with — the user reads and edits it in Loom's sheet. */
  /** @param {Issue} issue */
  function promptFor(issue) {
    const lines = [
      "Work on the Jira issue " + issue.key + ": " + issue.summary,
      "",
      [issue.type && "Type: " + issue.type, issue.priority && "Priority: " + issue.priority]
        .filter(Boolean).join(" · "),
      state.config ? "Link: https://" + state.config.site + "/browse/" + issue.key : "",
    ];
    if (issue.description) {
      lines.push("", "Description:", issue.description.slice(0, 6000));
    }
    lines.push("", "Start by reading the relevant code and propose a plan before changing anything.");
    return lines.filter((line, index, all) => !(line === "" && all[index - 1] === "")).join("\n").trim();
  }

  /** @param {string} key */
  function sessionFor(key) {
    const id = state.issueSessions[key];
    return id ? state.sessions.get(id) || null : null;
  }

  /** @param {Loom.Session | null} session */
  function isLive(session) {
    return !!session && ["starting", "working", "needs_input", "idle"].includes(session.state);
  }

  /** @param {string} value */
  function stateLabel(value) {
    return value === "needs_input" ? "needs input" : value;
  }

  async function refreshSessions() {
    try {
      const sessions = await loom.sessions.list();
      state.sessions = new Map(sessions.map((session) => [session.id, session]));
    } catch (error) {
      console.warn("[jira] sessions", error);
    }
  }

  /** @param {Issue} issue */
  async function startSession(issue) {
    const projectId = state.boardId !== null ? state.boardProjects[String(state.boardId)] : undefined;
    try {
      const result = await loom.sessions.launch({
        projectId,
        prompt: promptFor(issue),
        title: issue.key + " · " + issue.summary,
        badges: [issue.key],
      });
      if (result.launched && result.sessionId) {
        state.issueSessions[issue.key] = result.sessionId;
        await loom.storage.set(KEY_SESSIONS, state.issueSessions);
        await refreshSessions();
        setStatus("Session started for " + issue.key);
      } else {
        setStatus("Launch cancelled");
      }
    } catch (error) {
      setStatus(describe(error), "error");
    }
    render();
  }

  /** @param {unknown} error */
  function describe(error) {
    if (error instanceof JiraError) return error.message;
    if (error && typeof error === "object" && "code" in error) {
      const loomError = /** @type {Loom.LoomError} */ (error);
      return loomError.code === "network" ? "Jira is unreachable: " + loomError.message : loomError.message;
    }
    return String(error);
  }

  // MARK: - Screens

  /** @param {boolean} visible */
  function showSetup(visible) {
    $("setup").hidden = !visible;
    $("board").hidden = visible;
    $("board-select").hidden = visible || state.boards.length === 0;
    $("project-picker").hidden = visible || state.boards.length === 0;
    $("refresh").hidden = visible;
    $("settings").hidden = visible;
    $("setup-cancel").hidden = !(visible && state.config && state.token);
    if (visible) {
      $("detail").hidden = true;
      const site = /** @type {HTMLInputElement} */ ($("site"));
      const email = /** @type {HTMLInputElement} */ ($("email"));
      site.value = state.config ? state.config.site : "";
      email.value = state.config ? state.config.email : "";
    }
  }

  /** @param {string} message */
  function setupError(message) {
    const error = $("setup-error");
    error.textContent = message;
    error.hidden = !message;
  }

  /** @param {SubmitEvent} event */
  async function onSetupSubmit(event) {
    event.preventDefault();
    const site = normalizeSite(/** @type {HTMLInputElement} */ ($("site")).value);
    const email = /** @type {HTMLInputElement} */ ($("email")).value.trim();
    const token = /** @type {HTMLInputElement} */ ($("token")).value.trim();
    if (!site.endsWith(".atlassian.net")) {
      setupError("This extension reaches Jira Cloud sites only (…atlassian.net).");
      return;
    }
    setupError("");
    const previous = { config: state.config, token: state.token };
    state.config = { site, email };
    state.token = token;
    try {
      const me = await jira("/rest/api/3/myself");
      await loom.secrets.set(SECRET_TOKEN, token);
      await loom.storage.set(KEY_CONFIG, state.config);
      /** @type {HTMLInputElement} */ ($("token")).value = "";
      setStatus("Connected as " + (me.displayName || email));
      showSetup(false);
      await loadBoard(true);
    } catch (error) {
      state.config = previous.config;
      state.token = previous.token;
      setupError(describe(error));
    }
  }

  /** @param {boolean} reloadBoards */
  async function loadBoard(reloadBoards) {
    if (state.loading) return;
    state.loading = true;
    setStatus("Loading…");
    try {
      if (reloadBoards || state.boards.length === 0) {
        state.boards = await loadBoards();
        renderBoardPicker();
      }
      if (state.boards.length === 0) {
        state.columns = [];
        state.issues = [];
        setStatus("No board on this site");
        return;
      }
      const board = state.boards.find((candidate) => candidate.id === state.boardId) || state.boards[0];
      state.boardId = board.id;
      /** @type {HTMLSelectElement} */ ($("board-select")).value = String(board.id);
      renderProjectPicker();
      const [columns, issues] = await Promise.all([loadColumns(board.id), loadIssues(board)]);
      state.columns = columns;
      state.issues = issues;
      await refreshSessions();
      setStatus(issues.length + " issue" + (issues.length === 1 ? "" : "s"));
    } catch (error) {
      if (error instanceof JiraError && (error.status === 401 || error.status === 403)) {
        showSetup(true);
        setupError(error.message + " — check the e-mail and the token.");
      }
      setStatus(describe(error), "error");
    } finally {
      state.loading = false;
      render();
    }
  }

  function renderBoardPicker() {
    const select = /** @type {HTMLSelectElement} */ ($("board-select"));
    select.replaceChildren(
      ...state.boards.map((board) => {
        const option = /** @type {HTMLOptionElement} */ (el("option", { text: board.name + " (" + board.type + ")" }));
        option.value = String(board.id);
        return option;
      })
    );
    select.hidden = state.boards.length === 0;
  }

  function renderProjectPicker() {
    const picker = $("project-picker");
    const select = /** @type {HTMLSelectElement} */ ($("project-select"));
    const none = /** @type {HTMLOptionElement} */ (el("option", { text: "Ask when starting" }));
    none.value = "";
    select.replaceChildren(
      none,
      ...state.projects.map((project) => {
        const option = /** @type {HTMLOptionElement} */ (el("option", { text: project.name }));
        option.value = project.id;
        return option;
      })
    );
    select.value = (state.boardId !== null && state.boardProjects[String(state.boardId)]) || "";
    picker.hidden = state.boards.length === 0;
  }

  function render() {
    const board = $("board");
    if (state.columns.length === 0) {
      board.replaceChildren(el("p", { className: "muted empty", text: state.loading ? "" : "Nothing to show." }));
    } else {
      const placed = new Set();
      const columns = state.columns.map((column) => {
        const issues = state.issues.filter((issue) => column.statusIds.includes(issue.statusId));
        issues.forEach((issue) => placed.add(issue.key));
        return renderColumn(column.name, issues);
      });
      const unplaced = state.issues.filter((issue) => !placed.has(issue.key));
      if (unplaced.length > 0) columns.push(renderColumn("Other", unplaced));
      board.replaceChildren(...columns);
    }
    renderDetail();
  }

  /** @param {string} name @param {Issue[]} issues */
  function renderColumn(name, issues) {
    return el("div", { className: "column" }, [
      el("div", { className: "column-head" }, [
        el("span", { text: name }),
        el("span", { className: "count", text: String(issues.length) }),
      ]),
      el("div", { className: "cards" }, issues.map(renderCard)),
    ]);
  }

  /** @param {Issue} issue */
  function renderCard(issue) {
    const session = sessionFor(issue.key);
    const footer = el("div", { className: "card-foot" }, [
      el("span", { className: "key", text: issue.key }),
      el("span", { className: "type", text: issue.type }),
    ]);
    if (session) {
      footer.append(el("span", {
        className: "chip state-" + session.state,
        text: stateLabel(session.state),
        title: "Loom session: " + session.title,
      }));
    }
    footer.append(el("span", { className: "avatar", text: initials(issue.assignee) || "–", title: issue.assignee || "Unassigned" }));
    const card = el("button", { className: "card" + (state.selected && state.selected.key === issue.key ? " selected" : "") }, [
      el("div", { className: "summary", text: issue.summary }),
      footer,
    ]);
    card.setAttribute("type", "button");
    card.dataset.key = issue.key;
    card.addEventListener("click", () => {
      state.selected = issue;
      render();
    });
    return card;
  }

  function renderDetail() {
    const detail = $("detail");
    const issue = state.selected && state.issues.find((candidate) => candidate.key === state.selected?.key);
    if (!issue) {
      detail.hidden = true;
      return;
    }
    detail.hidden = false;
    $("detail-key").textContent = issue.key;
    $("detail-summary").textContent = issue.summary;
    $("detail-meta").textContent = [issue.type, issue.statusName, issue.priority, issue.assignee || "Unassigned"]
      .filter(Boolean).join(" · ");
    $("detail-description").textContent = issue.description || "No description.";
    const link = /** @type {HTMLAnchorElement} */ ($("detail-link"));
    link.href = state.config ? "https://" + state.config.site + "/browse/" + encodeURIComponent(issue.key) : "#";
    const session = sessionFor(issue.key);
    const live = isLive(session);
    $("detail-open").hidden = !live;
    $("detail-start").textContent = session ? "Start another session" : "Start a session";
    $("detail-session").textContent = session
      ? "Loom session “" + session.title + "” — " + stateLabel(session.state)
      : "";
  }

  // MARK: - Wiring

  async function boot() {
    $("setup-form").addEventListener("submit", (event) => onSetupSubmit(/** @type {SubmitEvent} */ (event)));
    $("setup-cancel").addEventListener("click", () => showSetup(false));
    $("settings").addEventListener("click", () => showSetup(true));
    $("refresh").addEventListener("click", () => loadBoard(false));
    $("detail-close").addEventListener("click", () => {
      state.selected = null;
      render();
    });
    $("detail-start").addEventListener("click", () => {
      if (state.selected) startSession(state.selected);
    });
    $("detail-open").addEventListener("click", async () => {
      const session = state.selected && sessionFor(state.selected.key);
      if (!session) return;
      try {
        await loom.sessions.open(session.id);
      } catch (error) {
        setStatus(describe(error), "error");
      }
    });
    $("board-select").addEventListener("change", async (event) => {
      state.boardId = Number(/** @type {HTMLSelectElement} */ (event.target).value);
      state.selected = null;
      await loom.storage.set(KEY_BOARD, state.boardId);
      loadBoard(false);
    });
    $("project-select").addEventListener("change", async (event) => {
      if (state.boardId === null) return;
      const value = /** @type {HTMLSelectElement} */ (event.target).value;
      if (value) state.boardProjects[String(state.boardId)] = value;
      else delete state.boardProjects[String(state.boardId)];
      await loom.storage.set(KEY_PROJECTS, state.boardProjects);
    });

    loom.on("session.stateChanged", async ({ sessionId, state: next }) => {
      const known = state.sessions.get(sessionId);
      if (known) known.state = next;
      else await refreshSessions();
      render();
    });
    loom.on("sessions.changed", ({ sessions }) => {
      state.sessions = new Map(sessions.map((session) => [session.id, session]));
      render();
    });
    loom.on("command", ({ id }) => {
      if (id === "refresh") loadBoard(true);
    });

    const [config, token, boardId, boardProjects, issueSessions, projects] = await Promise.all([
      loom.storage.get(KEY_CONFIG),
      loom.secrets.get(SECRET_TOKEN),
      loom.storage.get(KEY_BOARD),
      loom.storage.get(KEY_PROJECTS),
      loom.storage.get(KEY_SESSIONS),
      loom.projects.list().catch(() => []),
    ]);
    state.config = /** @type {Config | null} */ (config);
    state.token = token;
    state.boardId = typeof boardId === "number" ? boardId : null;
    state.boardProjects = /** @type {Record<string, string>} */ (boardProjects || {});
    state.issueSessions = /** @type {Record<string, string>} */ (issueSessions || {});
    state.projects = projects;

    if (!state.config || !state.token) {
      showSetup(true);
      return;
    }
    showSetup(false);
    await loadBoard(true);
  }

  window.addEventListener("DOMContentLoaded", () => {
    boot().catch((error) => setStatus(describe(error), "error"));
  });
})();
