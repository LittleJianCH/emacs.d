// emacs-bridge.mjs --- opencode's own server API behind a stdio RPC for Emacs.
//
// opencode has no headless protocol of its own; its real interface is the API
// of `opencode serve` (the TUI, the desktop app and the web client all speak
// it): JSON over HTTP plus an SSE event stream.  This bridge is one process
// per Emacs session (agent-opencode.el).  It starts a private `opencode serve`
// on an ephemeral port with its own password -- never the user's background
// service -- subscribes to /api/event and translates both directions into
// newline-delimited JSON-RPC 2.0 on stdio.
//
// The server reads an extra configuration source from
// OPENCODE_CONFIG_CONTENT (Emacs passes it in initialize): the emx MCP server,
// the skills Emacs provides and so on.  Nothing is written to the user's
// config, and the server is a child of this process, so it dies with it.
//
// Wire format.  Requests (Emacs -> bridge):
//   initialize {cwd, resume?, title?, model?, variant?, agent?, permissions?,
//               config?}
//                -> {sessionId, version, title, model, variant, agent,
//                    commands, models, history, warnings}
//   configure  {model?, variant?, agent?, permissions?}
//                -> {model, variant, agent, permissions}
//   prompt     {text, images?}                  -> {messageId}
//   steer      {text, images?}                  -> {messageId}
//   command    {name, text}                     -> {}
//   cancel     {}                               -> {}
//   sessions/list {cwds} -> {sessions: [{id, cwd, title, time}]}
//                                             (no initialize; time in seconds)
// A model travels as "providerID/modelID" and a variant as a plain string,
// because both can contain any character.  Images are absolute file paths.
//
// Notifications (bridge -> Emacs):
//   status    {status}            running / idle
//   user      {id, text, images}  replay only; live prompts are drawn by Emacs
//   text      {id, kind, delta}   kind: assistant / thinking
//   text/done {id, kind, text}
//   discard   {ids}               blocks that were abandoned, e.g. by an error
//   tool      {id, name, input}
//   tool/output {id, delta}       live output of a running shell tool
//   tool/done {id, isError, output?, error?}
//   permission {id, action, resources, save, message?, tool?}
//   permission/done {id, tool?, reply}   answered elsewhere (TUI, desktop app)
//   question  {id, title?, kind?, tool?, fields: [{key, title, question,
//              options: [{label, description, value}], multi, other, secret,
//              default}]}
//   question/done {id, tool?, answer?, cancelled?}   answered elsewhere
//   renamed   {title}
//   usage     {tokens, cost}
//   config    {model?, variant?, agent?, permissions?}
//   notice    {message, error?}
//
// Requests (bridge -> Emacs) carry the opencode id (per_... / frm_...) and
// expect the JSON-RPC result on the same id: for `permission` a decision
// {decision: once|always|reject}, for `question` either {answer: {KEY: VALUE}}
// or {cancel: true}.
//
// Requires Node 18+ (fetch, web streams) and `opencode` on PATH.

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";

let executable = "opencode";
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--opencode") executable = args[++i];
}

// ---------------------------------------------------------------- stdio

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const notify = (method, params) => send({ jsonrpc: "2.0", method, params });
const reply = (id, result) => send({ jsonrpc: "2.0", id, result: result ?? {} });
const replyError = (id, message) =>
  send({ jsonrpc: "2.0", id, error: { code: -32000, message: String(message) } });

const errorText = (error) => {
  if (error === undefined || error === null) return "unknown error";
  if (typeof error === "string") return error;
  if (typeof error.message === "string") return error.message;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
};

// ---------------------------------------------------------------- server

let server = null;
let base = null;
let auth = null;
let sessionID = null;
let running = false;
let ending = false;

// opencode expands ~ itself for some paths but not for config arrays, so do it
// here: paths in `config` come from Emacs, which names a remote host's paths
// with ~.
const expandHome = (value) =>
  typeof value === "string" && (value === "~" || value.startsWith("~/"))
    ? join(homedir(), value.slice(1))
    : value;

function expandConfig(config) {
  if (Array.isArray(config.skills)) config.skills = config.skills.map(expandHome);
  const servers = config.mcp?.servers ?? {};
  for (const server of Object.values(servers)) {
    if (Array.isArray(server.command)) server.command = server.command.map(expandHome);
  }
  return config;
}

function startServer(cwd, config) {
  return new Promise((resolve, reject) => {
    const password = randomBytes(24).toString("base64url");
    const env = { ...process.env, OPENCODE_SERVER_PASSWORD: password };
    if (config) env.OPENCODE_CONFIG_CONTENT = JSON.stringify(expandConfig(config));
    let child;
    try {
      child = spawn(executable, ["serve", "--hostname", "127.0.0.1", "--port", "0"], {
        cwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      reject(new Error(`cannot run ${executable}: ${error.message}`));
      return;
    }
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`${executable} serve did not report its address in 60 seconds`));
    }, 60000);
    let output = "";
    let errors = "";
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(new Error(`cannot run ${executable}: ${error.message}`));
    });
    child.stdout.on("data", (chunk) => {
      output += chunk.toString();
      const match = output.match(/server listening on (http:\/\/\S+)/);
      if (match && base === null) {
        clearTimeout(timer);
        base = match[1];
        auth = "Basic " + Buffer.from(`opencode:${password}`).toString("base64");
        resolve(child);
      }
    });
    child.stderr.on("data", (chunk) => {
      errors = (errors + chunk.toString()).slice(-4000);
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (ending) return;
      const tail = errors.trim().split("\n").filter(Boolean).slice(-3).join(" ");
      notify("notice", {
        message: `opencode serve exited (code ${code})${tail ? ": " + tail : ""}`,
        error: true,
      });
      shutdown(1);
    });
  });
}

async function api(method, path, body) {
  const response = await fetch(base + path, {
    method,
    headers: { authorization: auth, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    let detail = text.slice(0, 300);
    try {
      detail = JSON.parse(text).message ?? detail;
    } catch {}
    throw new Error(`${method} ${path}: ${response.status} ${detail}`);
  }
  return text ? JSON.parse(text) : null;
}

// ---------------------------------------------------------------- events

const tools = new Map(); // tool call id -> {name, shellID}
const shells = new Map(); // shell id -> {file, offset, timer}

const textID = (data, kind) =>
  `${data.assistantMessageID}-${kind === "thinking" ? "reasoning" : "text"}-${data.ordinal ?? 0}`;

const toolText = (content) =>
  (Array.isArray(content) ? content : [])
    .map((part) => {
      if (part?.type === "text") return part.text ?? "";
      if (part?.type === "file") return `[${basename(part.path ?? part.name ?? "file")}]`;
      return "";
    })
    .filter(Boolean)
    .join("\n");

const streamToolOutput = () => {
  for (const [id, shell] of shells) {
    if (shell.timer === null) continue;
    let data;
    try {
      data = readFileSync(shell.file);
    } catch {
      continue; // not created yet, or already removed
    }
    if (data.length <= shell.offset) continue;
    const delta = data.subarray(shell.offset).toString("utf8");
    shell.offset = data.length;
    if (delta) notify("tool/output", { id: shell.tool, delta });
  }
};

// Follow the output file of a shell tool while it runs.
const streamShell = (shellID) => {
  const shell = shells.get(shellID);
  if (!shell || shell.timer !== null || !shell.file || !shell.tool) return;
  shell.timer = setInterval(streamToolOutput, 250);
  streamToolOutput();
};

const stopToolOutput = (toolID) => {
  if (!toolID) return;
  for (const shell of shells.values()) {
    if (shell.tool !== toolID) continue;
    if (shell.timer !== null) clearInterval(shell.timer);
    shell.timer = null;
  }
};

function handleEvent(event) {
  const data = event.data ?? {};
  if (data.sessionID && data.sessionID !== sessionID) return;
  switch (event.type) {
    case "session.execution.started":
      if (!running) {
        running = true;
        notify("status", { status: "running" });
      }
      break;
    case "session.execution.succeeded":
    case "session.execution.interrupted":
      if (running) {
        running = false;
        notify("status", { status: "idle" });
      }
      break;
    case "session.execution.failed": {
      running = false;
      notify("notice", {
        message: errorText(data.error ?? data.message ?? "the turn failed"),
        error: true,
      });
      notify("status", { status: "idle" });
      break;
    }
    case "session.text.delta":
    case "session.reasoning.delta":
      notify("text", {
        id: textID(data, event.type.includes("reasoning") ? "thinking" : "assistant"),
        kind: event.type.includes("reasoning") ? "thinking" : "assistant",
        delta: data.delta ?? "",
      });
      break;
    case "session.text.ended":
    case "session.reasoning.ended":
      notify("text/done", {
        id: textID(data, event.type.includes("reasoning") ? "thinking" : "assistant"),
        kind: event.type.includes("reasoning") ? "thinking" : "assistant",
        text: data.text ?? "",
      });
      break;
    case "session.tool.input.started": {
      // The block appears as soon as the model starts filling it in.
      const tool = tools.get(data.id) ?? {};
      tool.name = data.name;
      tools.set(data.id, tool);
      notify("tool", { id: data.id, name: data.name, input: null });
      break;
    }
    case "session.tool.called": {
      const tool = tools.get(data.id) ?? {};
      tool.name = data.name;
      tools.set(data.id, tool);
      notify("tool", { id: data.id, name: data.name, input: data.input ?? null });
      break;
    }
    case "session.tool.progress": {
      const shellID = data.metadata?.shellID;
      if (!shellID) break;
      const tool = tools.get(data.id) ?? { name: "shell" };
      tool.shellID = shellID;
      tools.set(data.id, tool);
      const shell = shells.get(shellID) ?? { file: null, offset: 0, timer: null, tool: data.id };
      shell.tool = data.id;
      shells.set(shellID, shell);
      streamShell(shellID);
      break;
    }
    case "session.tool.success": {
      tools.delete(data.id);
      const output = toolText(data.content);
      stopToolOutput(data.id);
      notify("tool/done", {
        id: data.id,
        isError: false,
        output,
        metadata: data.metadata ?? null,
      });
      break;
    }
    case "session.tool.failed": {
      tools.delete(data.id);
      const error = data.error ?? data;
      stopToolOutput(data.id);
      notify("tool/done", {
        id: data.id,
        isError: true,
        error: errorText(error),
        errorKind: error?.type ?? null,
      });
      break;
    }
    case "shell.created": {
      const shell = shells.get(data.info?.id) ?? { file: null, offset: 0, timer: null, tool: null };
      shell.file = data.info.file;
      shells.set(data.info.id, shell);
      streamShell(data.info.id);
      break;
    }
    case "shell.exited": {
      const shell = shells.get(data.id);
      if (!shell) break;
      if (shell.timer !== null) clearInterval(shell.timer);
      shells.delete(data.id);
      break;
    }
    case "permission.asked":
      askEmacs("permission", {
        id: data.id,
        action: data.action,
        resources: data.resources ?? [],
        save: data.save ?? [],
        message: data.message ?? null,
        tool: data.source?.type === "tool" ? data.source.id : null,
      });
      break;
    case "permission.replied":
    case "permission.rejected":
      settleAsk(data.requestID,
        // A rejection carries no chosen reply.
        { reply: data.reply ?? (event.type === "permission.rejected" ? "reject" : "once") },
        "permission/done");
      break;
    case "form.created":
      notifyQuestion(data.form);
      break;
    case "form.replied":
      settleAsk(data.id, { answer: data.answer ?? {} }, "question/done");
      break;
    case "form.cancelled":
      settleAsk(data.id, { cancelled: true }, "question/done");
      break;
    case "session.usage.updated": {
      const tokens = data.tokens ?? {};
      notify("usage", {
        tokens: (tokens.input ?? 0) + (tokens.output ?? 0) + (tokens.reasoning ?? 0),
        cost: data.cost ?? 0,
      });
      break;
    }
    case "session.renamed":
      notify("renamed", { title: data.title });
      break;
    case "session.model.selected":
      notify("config", {
        model: data.model ? modelString(data.model) : null,
        variant: variantOf(data.model),
      });
      break;
    case "session.step.started":
      // The model and variant a step really runs: the session object only
      // carries them when something selected one explicitly.  The agent is
      // left out on purpose -- it is a snapshot from the turn's start, and
      // `session.agent.selected' reports the real changes.
      notify("config", {
        model: data.model ? modelString(data.model) : null,
        variant: variantOf(data.model),
      });
      break;
    case "session.agent.selected":
      notify("config", { agent: data.agent ?? data.id ?? null });
      break;
    case "session.permissions":
      notify("config", { permissions: data.permissions ?? [] });
      break;
    case "session.error":
      notify("notice", { message: errorText(data.error ?? data), error: true });
      break;
    default:
      break;
  }
}

function notifyQuestion(form) {
  const fields = (form?.fields ?? []).map((field) => ({
    key: field.key,
    title: field.title ?? null,
    question: field.description ?? field.title ?? form.title ?? "",
    options: (field.options ?? []).map((option) => ({
      label: option.label ?? option.value,
      description: option.description ?? null,
      value: option.value ?? option.label,
    })),
    multi: field.type === "multiselect",
    other: Boolean(field.custom) || field.type === "string" || field.type === "number",
    secret: field.format === "password",
    default: field.default ?? null,
    type: field.type,
  }));
  askEmacs("question", {
    id: form.id,
    title: form.title ?? null,
    kind: form.metadata?.kind ?? null,
    tool: form.metadata?.tool?.id ?? null,
    fields,
  });
}

// ---------------------------------------------------------------- stream

async function subscribe() {
  const response = await fetch(base + "/api/event", {
    headers: { authorization: auth, accept: "text/event-stream" },
  });
  if (!response.ok) throw new Error(`event stream: ${response.status}`);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let index;
    while ((index = buffer.indexOf("\n\n")) >= 0) {
      const frame = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      const payload = frame
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).trim())
        .join("");
      if (!payload) continue;
      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue;
      }
      try {
        handleEvent(event);
      } catch (error) {
        notify("notice", { message: `event error: ${error.message}`, error: true });
      }
    }
  }
  throw new Error("event stream closed");
}

async function keepSubscribed() {
  for (;;) {
    try {
      await subscribe();
    } catch (error) {
      if (ending) return;
      notify("notice", { message: `event stream interrupted: ${error.message}` });
    }
    if (ending) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
    // A missed turn boundary would leave the UI running forever.
    try {
      const active = await api("GET", "/api/session/active");
      const now = Boolean(sessionID && active?.data?.[sessionID]);
      if (now !== running) {
        running = now;
        notify("status", { status: now ? "running" : "idle" });
      }
    } catch {
      /* the next attempt reports the failure */
    }
  }
}

// ---------------------------------------------------------------- models

const modelString = (ref) =>
  ref?.providerID && ref?.id ? `${ref.providerID}/${ref.id}` : null;

// "default" is opencode's name for the model's own default.
const variantOf = (ref) => {
  const variant = ref?.variant;
  return variant && variant !== "default" ? variant : null;
};

// "providerID/modelID", split at the first slash: a model id may contain one.
function parseModel(value) {
  if (typeof value !== "string" || !value.includes("/")) return null;
  const index = value.indexOf("/");
  return { providerID: value.slice(0, index), id: value.slice(index + 1) };
}

async function models() {
  const result = await api("GET", "/api/model");
  return (result?.data ?? [])
    .filter((model) => model.enabled !== false)
    .map((model) => ({
      id: `${model.providerID}/${model.id}`,
      name: model.name ?? model.id,
      description: model.providerID,
      efforts: (model.variants ?? []).map((variant) => variant.id),
      defaultEffort: null,
      context: model.limit?.context ?? null,
    }));
}

async function commandList() {
  const result = await api("GET", "/api/command");
  return (result?.data ?? []).map((command) => ({
    name: command.name,
    description: command.description ?? null,
  }));
}

async function commands() {
  // The first query can land before the location's configuration is loaded;
  // the query itself triggers the load.
  let list = await commandList();
  if (list.length === 0) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    list = await commandList();
  }
  return list;
}

// ---------------------------------------------------------------- history

async function replay(session) {
  const result = await api(
    "GET",
    `/api/session/${session}/message?order=desc&limit=100`,
  );
  const messages = (result?.data ?? []).slice().reverse();
  const history = [];
  for (const message of messages) {
    if (message.type === "user") {
      history.push({
        method: "user",
        params: {
          id: message.id,
          text: message.text ?? "",
          images: (message.files ?? []).length,
        },
      });
      continue;
    }
    if (message.type !== "assistant") continue;
    (message.content ?? []).forEach((part, index) => {
      if (part.type === "text") {
        history.push({
          method: "text/done",
          params: { id: `${message.id}-text-${index}`, kind: "assistant", text: part.text },
        });
      } else if (part.type === "reasoning") {
        history.push({
          method: "text/done",
          params: { id: `${message.id}-reasoning-${index}`, kind: "thinking", text: part.text },
        });
      } else if (part.type === "tool") {
        const state = part.state ?? {};
        history.push({
          method: "tool",
          params: { id: part.id, name: part.name, input: state.input ?? null },
        });
        if (state.status === "completed") {
          history.push({
            method: "tool/done",
            params: { id: part.id, isError: false, output: toolText(state.content) },
          });
        } else if (state.status === "error") {
          history.push({
            method: "tool/done",
            params: { id: part.id, isError: true, error: errorText(state.error) },
          });
        }
      }
    });
  }
  return history;
}

// ---------------------------------------------------------------- requests

// Requests the bridge sends to Emacs, by request id; answered by Emacs in the
// usual flow, or dropped when another client answered them first.
const asks = new Map();

function askEmacs(method, params) {
  asks.set(params.id, { kind: method, tool: params.tool ?? null });
  send({ jsonrpc: "2.0", id: params.id, method, params });
}

// Report a request answered elsewhere (the TUI, the desktop app), naming the
// tool it belongs to; silence when Emacs answered it itself.
function settleAsk(id, params, method) {
  const ask = asks.get(id);
  if (!ask) return;
  asks.delete(id);
  notify(method, { id, tool: ask.tool, ...params });
}

async function replyPermission(id, result) {
  const decision = ["once", "always", "reject"].includes(result?.decision)
    ? result.decision
    : "reject";
  await api("POST", `/api/session/${sessionID}/permission/${id}/reply`, {
    decision,
    message: result?.message ?? undefined,
  });
}

async function replyQuestion(id, result) {
  if (result?.cancel) {
    await api("DELETE", `/api/session/${sessionID}/form/${id}`);
  } else {
    await api("POST", `/api/session/${sessionID}/form/${id}/reply`, {
      answer: result?.answer ?? {},
    });
  }
}

async function initialize(params) {
  const cwd = params.cwd;
  server = await startServer(cwd, params.config ?? null);
  keepSubscribed();
  const warnings = [];
  let session = null;

  if (params.resume) {
    try {
      session = (await api("GET", `/api/session/${params.resume}`)).data;
    } catch {
      warnings.push(`session ${params.resume} not found, starting a new one`);
    }
  }
  if (!session) {
    const body = { location: { directory: cwd } };
    if (params.title) body.title = params.title;
    const model = parseModel(params.model);
    if (model) body.model = { ...model, ...(params.variant ? { variant: params.variant } : {}) };
    if (params.agent) body.agent = params.agent;
    if (params.permissions) body.permissions = params.permissions;
    session = (await api("POST", "/api/session", body)).data;
  }
  sessionID = session.id;
  const history = params.resume ? await replay(sessionID) : [];
  if (params.resume && (params.model || params.agent || params.permissions)) {
    // A resumed session keeps its own settings; Emacs' current ones win.
    await configure({
      model: params.model,
      variant: params.variant,
      agent: params.agent,
      permissions: params.permissions,
    });
  }

  const result = { sessionId: sessionID, history, warnings };
  const info = await api("GET", "/api/info").catch(() => null);
  result.version = info?.version ?? info?.data?.version ?? null;
  const listed = await api("GET", `/api/session/${sessionID}`).catch(() => null);
  const current = listed?.data ?? session;
  result.title = current.title ?? null;
  result.model = modelString(current.model);
  result.variant = variantOf(current.model);
  result.agent = current.agent ?? params.agent ?? null;
  result.commands = await commands();
  result.models = await models();
  running = false;
  return result;
}

async function configure(params) {
  const result = {};
  if (params.model !== undefined) {
    const ref = parseModel(params.model);
    if (ref) {
      const chosen = { ...ref, ...(params.variant ? { variant: params.variant } : {}) };
      await api("POST", `/api/session/${sessionID}/model`, { model: chosen });
      result.model = params.model;
      result.variant = params.variant ?? null;
    }
  }
  if (params.agent !== undefined) {
    await api("POST", `/api/session/${sessionID}/agent`, { agent: params.agent });
    result.agent = params.agent;
  }
  if (params.permissions !== undefined) {
    await api("PATCH", `/api/session/${sessionID}`, { permissions: params.permissions });
    result.permissions = params.permissions;
  }
  return result;
}

function attachments(images) {
  return (images ?? []).map((path) => ({
    uri: pathToFileURL(path).href,
    name: basename(path),
  }));
}

async function prompt(params, delivery) {
  const body = { text: params.text ?? "" };
  if (params.images?.length) body.files = attachments(params.images);
  if (delivery) body.delivery = delivery;
  const result = await api("POST", `/api/session/${sessionID}/prompt`, body);
  return { messageId: result?.data?.id ?? null };
}

async function command(params) {
  if (params.name === "compact") {
    await api("POST", `/api/session/${sessionID}/compact`, {
      delivery: params.delivery ?? undefined,
    });
    return {};
  }
  const body = { name: params.name, text: params.text ?? "" };
  if (params.delivery) body.delivery = params.delivery;
  await api("POST", `/api/session/${sessionID}/command`, body);
  return {};
}

// A fresh server only to list past sessions of the given directories.
async function listSessions(params) {
  if (server === null) await startServer(params.cwds?.[0] ?? process.cwd(), null);
  const seen = new Set();
  const sessions = [];
  for (const cwd of params.cwds ?? []) {
    let result;
    try {
      result = await api("GET", `/api/session?limit=50&directory=${encodeURIComponent(cwd)}`);
    } catch {
      continue;
    }
    for (const item of result?.data ?? []) {
      if (seen.has(item.id)) continue;
      seen.add(item.id);
      sessions.push({
        id: item.id,
        cwd: item.location?.directory ?? cwd,
        title: item.title ?? "",
        time: Math.floor((item.time?.updated ?? item.time?.created ?? 0) / 1000),
      });
    }
  }
  sessions.sort((a, b) => b.time - a.time);
  return { sessions: sessions.slice(0, 50) };
}

async function dispatch(method, params) {
  switch (method) {
    case "initialize":
      return initialize(params);
    case "configure":
      return configure(params);
    case "prompt":
      return prompt(params, params.delivery);
    case "steer":
      return prompt(params, "steer");
    case "command":
      return command(params);
    case "cancel":
      await api("POST", `/api/session/${sessionID}/interrupt`);
      return {};
    case "sessions/list":
      return listSessions(params);
    default:
      throw new Error(`unsupported method: ${method}`);
  }
}

// ---------------------------------------------------------------- main

function shutdown(code) {
  if (ending) return;
  ending = true;
  for (const shell of shells.values()) {
    if (shell.timer !== null) clearInterval(shell.timer);
  }
  if (server && !server.killed) server.kill();
  process.exit(code);
}

async function handle(message) {
  if (message.method === undefined) {
    // A reply to a request of ours.
    const ask = asks.get(message.id);
    if (ask === undefined) return;
    asks.delete(message.id);
    try {
      if (message.error) throw new Error(errorText(message.error));
      if (ask.kind === "permission") await replyPermission(message.id, message.result ?? {});
      else if (ask.kind === "question") await replyQuestion(message.id, message.result ?? {});
    } catch (error) {
      notify("notice", { message: `could not answer ${ask.kind}: ${error.message}`, error: true });
    }
    return;
  }
  try {
    const result = await dispatch(message.method, message.params ?? {});
    if (message.id !== undefined) reply(message.id, result);
  } catch (error) {
    if (message.id !== undefined) replyError(message.id, errorText(error));
    else notify("notice", { message: errorText(error), error: true });
  }
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
  let index;
  while ((index = input.indexOf("\n")) >= 0) {
    const line = input.slice(0, index).trim();
    input = input.slice(index + 1);
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      notify("notice", { message: "the bridge could not parse a request line", error: true });
      continue;
    }
    handle(message);
  }
});
process.stdin.on("end", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));
