# emx daemon: agents outside Emacs

Every agent session runs under a long-lived `emx` daemon. Emacs connects to
the daemon over a Unix socket and keeps the display and the interaction:
session buffers, input, approvals and questions, canvas pages, review
buffers, and the editor operations agents call. The daemon owns the agent
processes, the session state and transcript, approval and collaboration
policy, configuration, and usage accounting. A remote project's agents run
under a daemon on their host; Emacs attaches to it the same way.

## Goal

Move everything about running an agent out of Emacs: the CLI process, its
protocol, history replay, retries, policy and accounting. Emacs never parses
an agent's stream, replays a history or runs a backend's state machine, so a
busy or broken agent cannot freeze the editor.

What this gives:

- **Sessions outlive Emacs.** Restarting Emacs, a failed reload, or a
  `cl-defstruct` change that requires a restart does not kill agents. Emacs
  reattaches and catches up from its cursor.
- **One place for policy.** Approvals, children and the mailbox, concurrency
  limits and usage live in the daemon and are tested with `node --test`. The
  differences between Claude, Codex, dsh and Pi are absorbed by one layer
  instead of three protocol implementations.
- **Configuration, not defcustoms.** Agents, profiles, start guidance, limits
  and polling live in `emx/config.json` and its runtime override.

Non-goals: a second front end (the protocol could make one possible, but
none exists), changing how sessions look, and moving the canvas or review UI
out of Emacs.

## Decisions

- **An independent daemon per checkout.** The daemon is not a child of
  Emacs. Emacs connects to it and may come and go; a worktree runs its own
  daemon and never shares the main checkout's.
- **One daemon per host for remote projects.** A remote project's agents
  run under a daemon on that host, one per user, host and client checkout.
  Emacs attaches to it like the local daemon.
- **One attached Emacs per daemon.** A daemon serves a single editor, as one
  Emacs server serves all its frames. A second Emacs saying `hello` takes
  over and the first is told it was replaced. Agents' MCP clients and the
  usage connection are not editors and may connect in any number.
- **The daemon owns policy.** Agents, profiles, approval and collaboration
  rules, limits and polling intervals are emx configuration. Lisp holds no
  policy fallbacks; it keeps display preferences.
- **TypeScript compiled to `emx/dist`.** A pinned local compiler
  (`npm install --prefix emx`) emits ESM JavaScript for ES2022 into a
  generated, git-ignored `emx/dist/`. `bin/emx` builds on demand from a
  source checkout and imports only compiled `.js`; a host install has no
  sources and imports the installed tree. `bin/emx` and the dsh plugin stay
  JavaScript.
- **Node 18.17+ or 20.3+.** `AbortSignal.any` is the limiting API. Node 19
  and Node 20.0–20.2 are not supported. Host installs check the actual Node
  in the home-directory bootstrap, independently of project program lookup.
- **The editor keeps its tools.** New agent-to-Emacs abilities are
  `agent-ui-defmethod`s reached through `editor/call`; only work that needs
  no Emacs state (the `config_*` file tools) runs in emx itself.
- **The UI stays in Emacs.** Canvas pages, review buffers, session buffers
  and the editor methods remain where they are.

## Processes and lifetime

```
                 Unix socket (owner-only)
 Emacs  <────────────────────────────────>  emx daemon ── claude -p ...
 (view, input,        JSON-RPC 2.0           (sessions,    codex app-server
  editor tools)       NDJSON both ways        policy,      dsh + emacs-bridge.mjs
                                              usage)
                                               ▲
  agent's MCP client ── emx mcp (stdio) ───────┘  a thin client of the daemon
```

### One daemon per checkout

The daemon's socket and state live under the checkout's `var/`:
`<var>/emx/daemon.sock`, or `$TMPDIR/emx-<hash of var>.sock` when the path
would exceed the Unix-socket limit (100 bytes; both macOS and Linux allow
more, macOS is the tighter). `agent-emx-var-directory` chooses `<var>`; the
default is the checkout's `var/`.

Emacs starts the daemon with:

```
node <checkout>/bin/emx daemon --var <var> --ensure
```

`--ensure` probes the socket with `ping`, starts a detached daemon if none
answers, waits up to five seconds and prints
`{socket, version, pid, started, stale}`. A second ensure reuses a live
daemon of the same version. `emx daemon --stop` stops it, as do the
daemon's `SIGTERM`/`SIGINT` handlers. Interactive Emacs runs ensure
asynchronously; batch Emacs may use `call-process`.

### Exit and hibernation

The daemon lives while it has something to keep: an attached editor, a
usage-only client, or a live agent process. With none of these for
`daemon.idleExit` (default 15 minutes) it writes its session table and
exits; the next client starts it again and finds the sessions there.

Sessions are records, not processes. An idle session's CLI is stopped after
`sessions.hibernateAfter` (default 2 hours) and resumed on the next send
(`--resume`, thread resume, or the dsh bridge's resume). A session running a
turn or waiting on an approval or question keeps its process. No child is
hibernated: a child has no resumable transcript of its own, and it closes
with its task.

Claude's non-ambient background tasks also keep their CLI alive while the session
is idle, without blocking new messages or `session_ask`. The CLI's authoritative
`background_tasks_changed` list is published as `info.backgroundTasks` (including
ambient tasks for display). An idle `task_notification` protects the gap after
the task list empties until an assistant message or streamed `message_start`
starts an autonomous turn, or 15 seconds elapse without a wake; a user turn sent
in the gap keeps the guard, since it can end first. `system/init` alone never
starts a turn, and a send prepared while the autonomous turn begins defers any
restart. Autonomous replies use normal status and usage
accounting; task completion adds a `claude-task-done` notice.

While background work or its wake is pending, Claude defers process replacement
for effort, editor read-only tool changes and external-client history. A single
`claude-restart-deferred` notice explains the delay. Effort changes restart after
both the turn and pending work finish; tool/history changes retry on the next
send preparation. On stop or CLI exit the task list and wake guard are cleared.

A daemon that loses its editor does not stop its agents. They keep running
until the daemon stops, their session is stopped, they hibernate, or the
CLI exits. On a clean stop the daemon flushes the current turn to usage,
persists the session table and each transcript, stops the backends, and
exits. A crash loses the running processes but not the records: the table
is written on every change (with a short debounce) and synchronously on
shutdown.

### Stale code and restart

The daemon's version is a hash of its runtime files: `emx/dist/**/*.js`,
`*.json`, `bin/emx`, the dsh `.mjs`/`.yml` files, and the Pi bridge `.js`
file. A daemon reports it on `hello` and `ping`, and `--ensure` compares it with its own.

`reload` (the MCP tool, `bin/emx reload`, or `M-x my/reload-config`)
updates connected daemons as well as Lisp. It builds changed TypeScript sources
before reading the manifest, then compares each connected local/host daemon's
running version. A host's new content-addressed runtime is installed on this
explicit user/agent action, before requesting its restart. Timers never install
host files or open host connections.

A stale idle daemon hibernates its top-level sessions, persists transcripts and
native resume ids, closes its socket, then launches the target runtime through
`--ensure` with the same `--var` or host `--client`. Emacs receives a short Chinese
notice and reconnects through the existing hello/attach recovery path. Views keep
their buffers; recovering history does not start CLIs. The next send resumes each
native session with the new code.

If busy, `daemon/restart` records a pending target and returns immediately. The
old daemon continues serving new requests until every blocker clears: background
tasks or their pending wake (`background task pending`); running,
starting or disconnected turns/preparation; lifecycle operations; approvals and
questions; queued messages; live children (including finished children that have
not closed); child creation; pending `session_ask` replies and mailbox/outgoing
replies; asynchronous collaboration delivery; and MCP calls in flight. A live
idle top-level CLI alone is not a blocker. The daemon rechecks quiescence before
committing shutdown, so a new turn arriving in the meantime also delays it.
Children have no resumable transcript and must close before replacement.

The reload result keeps its `files` array and adds `emx`, one entry per connected
daemon: `{place, status, version?, waiting?, error?}`. Status is `restarted`,
`restart_scheduled`, `up_to_date`, or `failed`; `waiting` contains English
`{session?, reason}` blockers. Build/install errors are returned as failures
without stopping agents. A reload from an agent running in that daemon normally
reports `restart_scheduled`: its own turn and tool call must finish first. The
restart request's reply is written before shutdown can begin.

`M-x agent-emx-restart-daemon` remains the manual fallback, including for old
daemons without `capabilities.restart: 1`. Startup `--ensure` retains its
conservative `stopIfIdle` probe: it replaces stale daemons only when no agent
process is live. That probe never takes over the editor attachment; explicit
reload uses `daemon/restart` to support idle live processes and deferred restart.

### Locks and sockets

One daemon owns a state directory. It publishes `daemon.lock` by hard-linking
a complete owner record containing its PID, reclaims a lock whose owner is
gone under a small mutex directory, and removes the socket only while it
holds the lock. State and socket directories are mode 0700; the socket is
0600.

A host daemon uses the same lock under
`~/.cache/emacs-agent/emx/state/<client id>/emx/`. Its socket is
`~/.cache/emacs-agent/emx/run/<client id>.sock`; when that path is too long it
uses `$XDG_RUNTIME_DIR/emx-<hash of id>.sock`, or `/tmp/emx-<uid>/` when
`XDG_RUNTIME_DIR` is unset or also too long. The fallback directory must be
owned by the user, mode 0700, and not a symlink.

The client id is the first 16 hex digits of SHA-1 of the checkout's real
path, a NUL, and the machine name. The same worktree and the main checkout
therefore get separate daemons on one host, and two machines never share
one. `--client` and `--var` are mutually exclusive; `--stop --client <id>`
stops only that host/client daemon.

### Build on demand

`bin/emx` imports only compiled `.js` for `emx daemon` and `emx mcp`. In a
source checkout it hashes the source paths, contents and mtimes of
`emx/**/*.ts`, the config and tsconfigs, the package manifests, and the entry
itself. An unchanged stamp skips the compiler.

A hard-link owner lock, with recovery after a dead owner, serializes
builders; a waiter rechecks the stamp after acquiring the lock. A build goes
into `emx/.dist-stage-*`; compiler errors are printed and leave the previous
runtime intact. Edits during compilation cause a retry. A complete tree is
renamed to an immutable `.dist-build-*` generation, and a temporary symlink
is renamed over `emx/dist` to publish it atomically. A real `dist` directory
from a hand-run compiler is first renamed to a retained generation.
Importers take a PID lease under the publication lock and import the
resolved generation. Cleanup keeps the current, previous and live
generations. A host install has no sources and imports `dist` directly.

`bin/emx` builds before dispatching every command, including bare CLI help.
The compiled `cli/main.js` dispatches daemon/MCP or uses the bare emacsclient
transport. Host installs use the same entry with no compiler or sources.
The recursive runtime manifest includes all compiled `cli/` modules.

`node bin/emx daemon --manifest` prints the version and the runtime
manifest without starting a daemon. The check-only compiler is
`emx/node_modules/.bin/tsc -p emx`.

## Session model

A session record holds what the session UI needs, minus the buffer: agent,
root, status, info, settings, capabilities, queue, transcript, pending asks,
children, and backend state. The daemon assigns the id.

Each session has one operation queue. Start, stop, restart, hibernate,
configuration and process-changing send preparation run in request order;
each checks the current state when it begins. Environment resolution is part
of start. Stop is terminal: a later start or adapter restart cannot revive
the session. Hibernate only releases an idle process and the next send
resumes it. Model turns and their pending asks run outside the operation queue.

`session/open.creationId` identifies one creation attempt. Before resolving
the environment or starting a backend, the daemon atomically saves an
`opening` creation record alongside the session table. Concurrent retries
wait for the same initialization and final persistence. Success becomes
`open`; failure and explicit stop become `failed` and `closed` tombstones.
Retries of terminal keys fail rather than creating a new backend. A daemon
crash turns unfinished openings into failures. Intentional new opens use
fresh keys; only transport retries reuse one. Terminal records expire after
30 days, while active records do not expire.

Statuses are `starting`, `idle`, `running`, `disconnected` and `exited`.
`disconnected` is an editor-side condition for a remote session whose
transport is down; the agent itself keeps running under its daemon.

- **Info** is open-ended: model, tokens, title, handle, parent,
  parentSession, profile, native session id, skills context, and the Claude
  or Codex skill fields retained for process restarts.
- **Settings** are model, effort, mode and `beforePlan` (the permission mode
  retained beneath plan mode, including across resume). Null means the
  agent's default.
- **Capabilities** are the backend's models (id, name, description, efforts,
  default effort), modes and slash commands, in the backend's own terms.
- **The queue** holds messages accepted while a turn runs.
- **Asks** are pending approvals or questions (below).
- **The transcript** is an ordered list of blocks with stable ids: `user`
  (with optional images, image count and origin), `text` (assistant or
  thinking), `tool` and `notice`.

A tool block carries a normalized view computed by the backend adapter:
`kind` (`command`, `read`, `edit`, `search`, `web`, `task`, `question`,
`plan`, `mcp`, `other`), the agent's tool name, a short title, and per kind
`command`, `path`, a unified `diff`, or plan `items`. The daemon never writes
UI prose: see Localization.

Sessions persist as `<var>/emx/sessions.json` (`sessions`: id, agent, root,
info, settings, resume id; `creations`: key, id, state, update time, error) and one `<var>/emx/sessions/<id>.json` per transcript
(blocks, queue, capabilities). Writes are debounced and atomic. Children are
not persisted: after a daemon crash they have no resumable native
transcript, so the restored table contains only top-level sessions. A
restored session is `idle` with a new epoch, no asks and its queued messages;
its CLI starts on the next send.

## Protocol

JSON-RPC 2.0, one JSON object per line, both directions over the socket.
Requests may flow both ways; the contract is `emx/daemon/protocol.ts`.

### Requests

| method | params | result |
|---|---|---|
| `ping` | `{}` | `{daemon, version, capabilities, liveAgents}` |
| `hello` | `{client, version, agents?, config?, tools?}` | `{daemon, version, capabilities, config, sessions}` |
| `sessions/list` | `{root?}` | `{sessions}` |
| `sessions/history` | `{agent, root}` | `{items}` |
| `session/open` | `{agent, root, settings?, resume?, parent?, handle?, skills?, claude?, codex?}` | `{id}` |
| `session/attach` | `{id, after?, turns?}` | snapshot (below) |
| `session/detach` | `{id}` | `{}` |
| `session/send` | `{id, text, images?, block?, handle?}` | `{queued}` |
| `session/steer` | `{id, text, images?, block?, handle?}` | `{accepted}` |
| `session/interrupt` | `{id}` | `{}` |
| `session/context` | `{id, skills}` | `{}` |
| `session/configure` | `{id, model?, effort?, mode?, beforePlan?}` | `{}` |
| `session/answer` | `{id, ask, choice?, answers?}` | `{stale}` |
| `session/earlier` | `{id, before, turns?}` | `{earlier}` |
| `session/stop` | `{id}` | `{}` |
| `config/get`, `config/reload` | `{}` | `{config, errors}` |
| `config/push` | `{config}` | `{config, errors}` (host daemon) |
| `config/call` | `{method, arguments}` | `string` (local daemon) |
| `usage/hello` | `{}` | `{daemon, version, capabilities, config}` |
| `usage/configure` | `{agents?, pollers?, pollInterval?}` | `{quotas}` |
| `usage/record` | `{id, record, source?, sequence?}` | receipt `{id, source?, sequence}` |
| `usage/quota` | `{id, reading, source?, sequence?}` | receipt |
| `usage/ack` | `{source?, sequence?, id?}` | `{}` (host daemon) |
| `usage/report` | `{range?, filter?, withoutCache?, now?}` | report |
| `usage/refresh` | `{force?}` | `{}` (polls asynchronously) |
| `usage/clear` | `{}` | `{}` (keeps quotas) |
| `collab/list` | `{}` | `{sessions}` |
| `collab/read` | `{id, last?, before?, tools?}` | text |
| `collab/ask` | `{id, prompt, route, origin}` | text |
| `collab/deliver` | `{id, route, mail}` | `{}` |
| `collab/retry` | `{}` | `{}` |
| `mcp/hello` | `{session}` | `{remote}` |
| `mcp/tools` | `{}` | `{tools}` |
| `mcp/call` | `{name, arguments?}` | method result |
| `daemon/restart` | `{version, runtime}` | `{status, version, waiting?}` |
| `daemon/stop` | `{ifIdle?, idleOnly?}` | `{stopped?}` |

`hello` is the editor role: it replaces any previous editor, returns the
session summaries and effective config, and starts a collaboration retry.
Its reply is followed by a `usage/quotas` snapshot, the host usage outbox
(when there is one), and the session list. `usage/hello` is a non-exclusive
usage role restricted to `usage/*` and `ping`. `mcp/hello` binds a
connection to one existing session. Neither can become the editor.

`session/open` reuses a live top-level session whose native resume id, agent
and root match instead of starting a second process. The `fork` field in
`OpenParams` is reserved but rejected; native forks go through
`session_start context=fork` (Collaboration).

### Events and cursors

Session events are notifications named by their type, with `{session, seq}`
in the params. `seq` increases by one per event of a session, and a new
epoch begins when a session is created or restored by another daemon
process. A seq means nothing without its epoch.

Session events:

- `status {status}`, `info {info}` (changed keys), `settings {settings}`
- `capabilities {capabilities}` (full replacement)
- `block/add {block, before?, history?}`
- `block/append {id, text}` (streamed text or tool output)
- `block/update {id, fields}`, `block/remove {ids}`
- `ask/add {ask}`, `ask/remove {id, resolution}`
- `queue {items}`
- `history/done {earlier}`

Usage and quota events (`usage/call`, `usage/end`, `quota`,
`quota/rate-limits`) are internal backend events. The daemon applies them to
accounting before logging an editor event; they never go over the socket and
never replay.

Global notifications:

- `sessions {sessions}` when the session list changes (debounced)
- `config {config, errors}`
- `usage/quotas {quotas}`, `usage/changed {}`
- `collab/closed {id}`
- `replaced {}` (another Emacs took over)
- `mcp/tools_changed {}` to MCP connections
- `usage/outbox {entries}` to a host daemon's editor, on hello and every
  five seconds while entries remain

Editor notifications are `editor/tools {tools, readOnly}` (changed editor
definitions and the private read-only classification), and the legacy
`usage/record` / `usage/quota` notifications. Current Emacs sends usage as
`usage/record` and `usage/quota` requests with a producer source and
sequence; the notification form remains for older editors.

### Attach, fresh views and earlier history

`session/attach` returns a snapshot: pending asks, queue, status, info,
settings, capabilities, `epoch`, `seq`, the replay mode, and whether earlier
turns remain.

- With no `after`, or an epoch the daemon no longer has, the mode is
  `fresh`. Emacs clears its view; the daemon then streams history blocks in
  order, ending with `history/done`. A fresh transfer is complete only at
  that event: an interrupted transfer must not keep the new cursor and
  attaches fresh again.
- With `after: {epoch, seq}` in the current epoch and a seq still in the
  per-session event log, the mode is `events` and exactly the events after
  the cursor are replayed in order. The log is a ring of the last 2,000
  events; when the cursor has fallen out of it, the daemon falls back to a
  snapshot.

History blocks sent for a fresh attach or for `session/earlier` carry
`history: true` and the seq they were sent at. They do not advance `seq`, and
neither does `history/done`. A fresh attach sends the last `turns` turns
(default 20), where a turn starts at a user block; if all turns were
selected, any preamble is included.

`session/earlier {id, before, turns?}` sends the turns before the block
`before` (the first block Emacs shows), default 20, with `before` set so
Emacs can insert them. The daemon keeps no paging state: a request lost with
the connection is simply made again. If the loaded transcript has fewer
turns than requested and the backend has a native transcript, the backend's
optional `loadEarlier` hook supplies the rest first. `history/done` reports
whether older turns remain.

### Editor calls

`editor/call {method, params, caller}` is a daemon-to-Emacs request. `caller`
is `{session, root, place}`; Emacs derives the place locally and does not
trust the wire's root text. The result uses agent-ui's envelope:
`{ok, result}`, `{ok, pending}` or `{ok, error}`.

The daemon sends editor calls for the tools agents call through MCP. It
keeps the editor's definitions and its private read-only classification in
`<var>/emx/tools.json` (written atomically and restored at startup), and
`editor/tools` updates them when methods are registered or a module loads.
A method that waits on the user returns a deferred id at once; the daemon
polls `_poll` every second and cancels with `_poll {id, cancel: true}` when
the caller goes away. With no editor attached, calls fail at once with
`Emacs is not attached`; editor disconnection or replacement aborts
outstanding calls rather than replaying their side effects on another
editor.

## MCP through the daemon

`emx mcp` requires `EMX_DAEMON_SOCKET` and `EMX_SESSION`, connects to that
socket and identifies itself with `mcp/hello {session}`. It cannot say
`hello`, take over the editor or control sessions. The daemon injects this
MCP server only into its own agent processes, never globally.

Bare `emx <method>` commands do not use the daemon: they go through
`emacsclient` and `agent-ui-rpc`.

The stdio facade implements `initialize`, `ping`, `tools/list` and
`tools/call`. `mcp/tools` is served from the daemon, including without an
editor and after a daemon restart. `mcp/tools_changed` becomes MCP
`notifications/tools/list_changed`; Claude and dsh act on it, while Codex
restarts its saved thread before the next send when its tool list changed.
`notifications/cancelled` aborts the corresponding socket call, and tool
failures are MCP `isError` results.

An MCP connection binds once to an existing session; a second `mcp/hello` on
the same connection is an error, even for the same session. The session id
routes calls. It is not an authentication token: the owner-only socket
trusts every process running as the user, and an agent could already run
`emacsclient` itself.

On a host daemon, the injected definitions include `config_read`,
`config_edit` and `config_write`, because the agent's own file tools work on
the project host and cannot reach the machine running Emacs. Calls go over
the editor connection like other editor calls, and Emacs forwards them to
the local daemon's `config/call`. The local daemon does the file I/O, so it
never blocks Emacs; Emacs is asked only about buffers visiting the file
(`_config_modified`, `_config_written`). Paths are confined to the
configuration checkout outside `.git`, exact replacement is checked,
numbered reads are preserved, and a buffer with unsaved changes causes a
refusal. This is a guardrail against editing the wrong host's files, not a
sandbox: `eval` remains unrestricted.

## Backends

Each backend is a daemon module with the same interface: `start(resume)`,
`send`, `steer`, `interrupt`, `configure`, `stop`, `alive`, `resumeId`, the
optional `reattached`, `hasEarlier`/`loadEarlier`, and `flush` before a fork.
It turns its CLI's stream into the session events above. A fake `echo`
backend exists for tests.

`sessions/history {agent, root}` discovers past native sessions without
opening one: Claude's JSONL transcripts (including Desktop worktrees),
Codex's `thread/list` and dsh's `sessions/list`, grouped by git worktree and
run on the daemon that owns the host. Emacs maps host roots back through its
transport.

All adapters accept an executable override from their effective agent
configuration and from an environment variable used by installations and
protocol fixtures (`EMX_CLAUDE_EXECUTABLE`, `EMX_CODEX_EXECUTABLE`,
`EMX_DSH_EXECUTABLE`, `EMX_PI_EXECUTABLE`). No credentials pass through those options.

### dsh

The adapter is the peer of the bridge plugin,
`lisp/agent/backend/dsh/emacs-bridge.mjs`, mounted by `emacs.yml` into dsh's
`sdk` profile:

```
dsh --profile sdk --patch <checkout>/lisp/agent/backend/dsh/emacs.yml \
    [--patch <checkout>/lisp/agent/backend/dsh/no-subagents.yml]
```

The bridge replaces dsh's own SDK JSON-RPC server and drives one dsh agent
through dsh's internal API. It speaks the same line-delimited JSON-RPC the
adapter expects, so the adapter maps `initialize`, `configure`, `prompt`,
`steer`, `cancel` and `flush` onto dsh and turns the bridge's `status`,
`text`/`text/done`, `discard`, `tool`/`tool/done`, `turn/end`, `usage`,
`config` and `error` notifications into blocks and events. `initialize`
reports the session id, title, models, presets, plan availability, commands,
history (on resume), warnings and dsh's version; a version other than the
one the bridge was written for is shown as a notice. `balance` supplies the
account balance for usage; failures there never interrupt a turn.

The hard parts: the bridge depends on dsh internals and needs adjusting when
dsh is upgraded; dsh asks about an MCP call only when a hook does, so the
bridge asks about every emx call except the read-only methods given in
`readOnly`, unless the preset is Full access, or Auto, whose reviewer judges
each call first; plan review arrives as a `question` with intent
`{kind: "plan-review", approve: label}`; and the API key stays in dsh's own
credentials file. Native subagents are disabled by the second patch unless
`agents.dsh.nativeSubagents` is true, and emx is mounted per agent.

### Claude

The adapter runs the CLI with stream-json input and output, partial
messages, `--permission-prompt-tool stdio`, a per-process `--mcp-config`
pointing at `emx mcp` with the daemon socket and session id, the permission
mode, disallowed native subagent tools, the model, effort, skill directory
and skill overrides. It answers `control_request` approvals and
AskUserQuestion, switches model and permission mode through control
requests, and reads the CLI's `result`, `assistant`, `user`, `stream_event`
and `rate_limit_event` messages.

The hard parts shape the adapter:

- **Effort changes need a restart** with `--resume`; it happens at once when
  idle or after the active turn, and a non-persistent child reports a notice
  instead.
- **A transcript is written by other clients too.** A directory watch
  coalesces writes for 500 ms and turns entries from entrypoints other than
  `sdk-cli` into blocks. Before the next send the CLI is restarted with
  `--resume` so its context catches up; that restart forgets the usage
  baseline.
- **History is read in two streaming passes**, retaining only the last
  page's turn offsets and display blocks. The saved byte boundary survives
  daemon persistence, and `session/earlier` pages further back without
  reading the whole file. The same reader pauses on a partial final line.
- **Usage totals are cumulative across a resumed process.** `modelUsage`
  totals become deltas against a baseline; the first report of a process
  must prove where it started, and an ambiguous report falls back to the
  turn's own counters.
- **Permissions compare their own JSON.** Approval replies splice the
  original raw `input` and `permission_suggestions` arguments, including
  false, null, arrays and empty objects, so the CLI's comparison still
  matches; an `always` answer carries the suggestions and a denial keeps the
  `declined` status.

Children run with `--no-session-persistence`. A native fork uses
`--resume <parent> --fork-session`; images are sent as base64 content.

### Pi

The adapter runs Pi 1.3.0 (`@earendil-works/pi-coding-agent`) with
`--mode rpc -e <checkout>/lisp/agent/backend/pi/emacs-extension.js`.
The thin extension registers direct `mcp__emacs__*` tools using the daemon
socket/session environment and forwards every tool call through an RPC
select dialog. The daemon owns approval policy: read-only builtins and
its audited MCP set pass in every mode; plan denies all other tools; ask
asks; edits additionally allows writes/edits contained in the project after
path expansion and symlink resolution; auto also allows bash; full allows
all tools. An always grant is per tool for this session, with plan taking
precedence. This is tool arbitration, not an operating-system sandbox.

`agents.pi.defaultModel` defaults to `opencode-go/kimi-k3`. The regex
`models.include`/`exclude` filters default to OpenCode Go without contributor,
free or preview routes. Model choices are validated even while hibernated;
each prompt reconciles the native route before submission. Thinking choices
come from each model's non-null `thinkingLevelMap` entries. Model, thinking,
and permission settings change live. Streaming uses LF-only JSONL framing,
authoritative final message content, tool execution results, retry notices,
and per-assistant usage; only `agent_settled` makes the session idle.

Native sessions persist and resume through `--session`; forks use `--fork`
and fresh ephemeral children use `--no-session`. Pi 1.3 gives that flag
precedence over `--fork`, so fork children retain a native session file.
A persistent session restarts and
resumes before sending after its editor tools change; children retain their
original set. Pi writes session entries synchronously; a `get_state` RPC
barrier is sufficient before fork. Installed emx skills use `--no-skills`
plus an explicit `--skill <skillsDir>/.claude/skills` so superseded native
workflows cannot shadow the editor set. Without that context, native skill
discovery remains enabled. No `--approve` override is added: saved trust and
Pi's `defaultProjectTrust` apply; an unanswered default ask in RPC skips
protected project resources. Credentials remain in Pi's native auth store;
quota polling is not implemented.

### Codex

The adapter runs `codex app-server` and speaks its JSON-RPC: `initialize`,
`model/list`, `thread/start`, `thread/resume`, `thread/fork`,
`thread/turns/list`, `turn/start`, `turn/steer`, `turn/interrupt`,
`account/rateLimits/read` and `skills/extraRoots/set`. It injects the emx MCP
server per process with `-c mcp_servers.emacs.*` and the daemon socket and
session id, and sets a 1,800-second tool timeout. Every turn carries the
model, effort, approval policy, sandbox and reviewer from the mode mapping.
It maps app-server items (reasoning, commands and their streamed output,
file diffs, MCP calls, plans, web searches), approvals and user questions
into blocks and asks.

The hard parts: app-server takes settings on `turn/start`, so changes apply
to the next turn; a saved thread whose editor tools changed is restarted in
a new process and resumed before the next send, while an ephemeral child
keeps the tools it started with; the user's developer instructions must be
preserved from `config/read` before the Emacs context is appended; and token
usage is read from changed thread totals only inside a turn, so replayed or
duplicate notifications never count. Resume fetches all pages of
`thread/turns/list` once; the session layer serves the requested page and
`session/earlier`. Rate limits arrive as sparse account readings. Native
subagents are disabled unless `agents.codex.nativeSubagents` is true.

## Approvals

The daemon decides the policy; Emacs shows the request and returns the
answer. There are two ask types:

- `approval`: one of the backend's choices (`allow`, `always` where it
  supports a session-wide answer, or `deny`), with the tool view and the
  agent's own description.
- `question`: one or more questions with options, multi-select, custom
  answers, a numeric range, secrecy, and an optional `intent` object that
  selects a specialized UI (dsh's plan review uses Emacs's native plan
  approval footer).

The first answer wins; a late answer gets `{stale: true}`. An interrupted or
stopped session cancels its asks.

The daemon builds one sorted, caller-independent read-only set for each
place: editor methods explicitly audited with `:read-only` (`context`,
`buffers`, `read_buffer`, `diagnostics`), collaboration's `sessions` and
`session_read`, and `config_read` on host daemons. These calls need no
approval. Claude receives exact comma-separated `mcp__emacs__<name>` entries
in `--allowedTools`, after other flags, without wildcards. Codex receives
`-c mcp_servers.emacs.tools.<name>.approval_mode="approve"` for each name,
with unique TOML keys. dsh keeps its bridge gate using the same set. This
private classification is never an MCP `readOnlyHint`; tool annotations do
not determine the allowlist.

A CLI keeps the set it started with. Before the next send, a persistent
Claude session whose set changed restarts with `--resume`; Codex reuses its
tools-change path to resume the saved thread in a new process. Revoking a
read-only classification therefore removes pre-approval before that send,
even if the tool definition stays the same. Non-persistent children keep
their original process and set. Flags depend only on configuration and
place, so a fork gets the same read-only flags as its parent under the same
configuration, preserving its prompt cache.

The permission modes are the same names in Emacs and the daemon: `ask`,
`edits`, `auto`, `full`, `plan`.
Each backend maps them to its own settings. `auto` delegates to that
backend's reviewer (Claude's classifier, Codex's `auto_review`, dsh's
auto-review), and what a reviewer refuses or cannot decide reaches the user.

A child's mode never exceeds its parent's. A child's own confirmations and
questions are shown in the child and mirrored in the parent's footer; the
user answers in either place. The daemon never asks the parent agent to
approve a child's request. A child that needs more permission reports what
it needs, and the parent, which has the wider permissions, does it or starts
a session that can.

## Collaboration

The daemon serves the five collaboration tools directly:
`sessions`, `session_read`, `session_ask`, `session_start` and
`session_stop`. Their definitions come from `collab.tools` in configuration;
`session_start`'s description is extended with `collab.startGuidance` and
the profiles available at the caller's place. Definitions depend on
configuration and where the caller runs, never on who is calling: a forked
session must see exactly its parent's tools to keep its prompt cache.

Profiles are filtered by the enabled agents Emacs sends on `hello` and by
whether their executable is runnable in that place's environment. They are
sorted by `profileCost`, preserving configuration order within a tier.
`mcp/hello` supplies a short cost-grouped profile summary for MCP instructions.
MCP has no instructions-changed notification: this summary stays fixed for the MCP process lifetime while tool descriptions update via `tools/list_changed`.

A daemon names a first submission with the configured cheap commands (the agent's own
`collab.agentHandleCommands[agent]` first, then `collab.handleCommand`),
cleans the model's answer into a handle, and makes handles unique. The
session title defaults to the first 80 characters of its first message.
Users mention sessions as `@handle`.

Each session summary includes its handle, session id, agent, place, title,
project root, status (`awaiting-approval` when an ask is pending), turn
count, whether it is the caller's own, and its parent and children.

### Children and context

`session_start` starts a child of a profile, or a fork of the caller:

| context | The child gets | Harness and model |
|---|---|---|
| `fresh` | the task alone | the profile's |
| `handoff` | a text copy of the parent's conversation, then the task | the profile's |
| `fork` | the parent's own conversation, up to the `session_start` call | the caller's agent, model and settings |

Only sessions the user opened can start sessions. A child can start no
further sessions, takes no `session_ask`, and sends none; it does one task
and reports its final reply. Its mode is capped at the caller's. At most
`collab.maxActive` children of one parent may be working at once, counting
pending starts; `collab.confirm` or a profile's `confirm` asks the user
first. A dsh fork flushes the parent's native log first; every fork requires
a live native conversation. Children inherit the caller's skills context.

A handoff is cached per parent turn. Within `collab.handoffLimit`
characters it keeps the latest turn (cut from the front if need be), the
first user message, then as many intervening turns as fit, newest first,
with a note naming what was left out. The task always comes last.

Children live in their parent's daemon. Closing a parent closes its
children. A child is not resumable after a daemon crash, and it is closed
when its reply has been delivered unless it failed or the user is looking at
it (`_session_visible`; an unresponsive visibility query conservatively
keeps it open). `session_stop` closes only a session the caller started.

### Mailbox

A reply to `session_ask` or a child's final reply is a mailbox message for
the asker. Pending work is persisted in `<var>/emx/collab.json`; long replies
are saved under `<var>/replies/` and clipped in the message. When the asker
is idle, the mailbox delivers every waiting reply as one message, with a
hidden note saying it came from Emacs rather than the user. Hidden notes and
the visible user text are kept separately in the transcript and queue, so a
later echo of the user block cannot reveal a note.

`session_read` formats the latest turns with `tools` set to `none`,
`summary` or `full`, clips text at `collab.textLimit`, and pages backwards
with `before`.

### Across daemons

The attached Emacs is the hub. A daemon answers `sessions` with its own
sessions and asks Emacs (`_collab_sessions`) for the others; Emacs queries
every other attached editor connection with `collab/list`, labels rows with
their place, and qualifies external handles with a stable daemon route.
Emacs uses existing connections and never connects to a host to list
sessions.

For an external `session_read` or `session_ask`, the caller's daemon invokes
`_collab_read` or `_collab_ask`; Emacs resolves the destination and forwards
`collab/read` or `collab/ask` over that daemon's editor connection. A plain
handle works when it names one external session; ambiguous handles require
the qualified id. Confirmation, when configured, belongs to the asking
daemon. The receiving daemon checks that the target is idle and not a child.

The receiving daemon persists the pending ask and then its outgoing reply.
`_collab_deliver` carries the reply through Emacs to `collab/deliver` on the
asking daemon, whose mailbox owns final delivery. An acknowledgment follows
a durable mailbox write; persisted receipt ids suppress duplicate delivery.
Replies that cannot be delivered stay queued and are retried when editor
connections return (`hello`, `collab/retry`, and each settle). Cross-daemon
calls fail with an English error when Emacs is not attached. Children never
move between daemons.

Emacs also enriches user input: a mentioned `@handle` gets a note naming the
session and its agent, using the wording cached from the daemon's config.

## Configuration

There are two files:

- `<checkout>/emx/config.json` is tracked and shipped with the runtime.
- `<var>/emx/config.json` is an optional, git-ignored override.

Objects merge deeply; arrays, scalars and null replace. Unknown fields,
malformed JSON and invalid types report a `config.<path>` error and keep the
last good effective configuration. Both files are polled every 250 ms,
including atomic replacement; a reload is debounced by 75 ms. `config/get`
and `config/reload` return `{config, errors}`; a change pushes a global
`config` notification and `mcp/tools_changed` to MCP peers.

The schema:

| Section | Keys |
|---|---|
| `agents` | `title`, `executable`, `extraArgs`, `nativeSubagents`; Claude also `disallowedTools`, `historyTurns` |
| `profiles` | `agent`, `model`, `effort`, `mode`, `cost`, `description`, `confirm` |
| `usage` | `pollInterval` (seconds) |
| `daemon` | `idleExit` (seconds) |
| `sessions` | `hibernateAfter` (seconds) |

`collab` holds `startGuidance`, `maxActive`, `handoffLimit`, `closeFinished`,
`confirm`, `textLimit`, `replyLimit`, `confirmTimeout`, `handleTimeout`,
`handleCommand`, `agentHandleCommands`, the five `tools` definitions, and
`prompts` (task, handoff, mailbox and naming text).

Modes are `plan`, `ask`, `edits`, `auto` and `full`; a profile's cost is
`minimal`, `low`, `medium`, `high` or `premium`. The default durations are
900 seconds for `usage.pollInterval` and `daemon.idleExit`, and 7,200 for
`sessions.hibernateAfter`.

`my/agents` in `init.el` chooses which agent registration modules Emacs
loads; on `hello` the daemon receives that enabled list and uses it for
collaboration profiles and usage, and Emacs requests history only for
enabled agents. The configuration holds settings for every configured
agent.

Emacs caches the effective config as it arrives (`agent-emx-config.el`) and
uses it only for display: agent titles, executable names and the wording of
input notes. It never makes a blocking config request for policy, and policy
does not come from Lisp defcustoms. A disconnected editor keeps its last
snapshot until it reconnects.

On a host daemon the local file is the source. Emacs sends the effective
config in `hello.config` and again with `config/push` on change or local
reconnection, preserving JSON empty objects, false and null. The host
persists the pushed base in `<state>/emx/client-config.json`, so it survives
an editor or daemon restart. `~/.config/emx/config.json` on the host may
override only `agents.<name>.executable`; any other override is rejected and
the last good config retained. Host config notifications never overwrite
Emacs's local cache.

Environment overrides remain for installations and protocol fixtures:
`EMX_CLAUDE_CONFIG`, `EMX_CLAUDE_PROJECTS_DIR`, `EMX_CODEX_CONFIG` and the
three executable variables above. File values apply on the next spawn;
existing processes keep their launch flags.

## Usage

### One writer

The local daemon's `UsageService` (`emx/usage/`) is the single writer of the
authoritative ledger and quota files:

- `<var>/agent-usage.jsonl`, one JSON record per model per turn:
  `{time, agent, root, session, model, turns, child?, input, cache_read,
  cache_write, output}`. Input excludes cached tokens. A cut-short last line
  is skipped and the next append starts its own line.
- `<var>/agent-quota.json`, the latest reading per agent and host:
  `{agent, host, time, plan?, credits?, balance?, windows: [{id, label,
  minutes, used, resets, history}]}`. A window keeps up to 300 readings of
  its current period (same reset time within ten minutes).
- `<var>/agent-usage.jsonl.watermarks.json` is the delivery watermark index.

There are no prices: the accounts are mostly subscription plans. Only
sessions the daemon runs are counted; a CLI run elsewhere is not. A host
daemon keeps its own ledger and quota file as a cache for local freshness
and reporting, and an outbox for delivery; the local ledger remains
authoritative.

### Accounting

Backend usage events are applied at the producer boundary, before any editor
event is logged. Attach, history replay, catch-up and reconnection cannot
charge usage. Accounting continues while Emacs is disconnected.

Claude's cumulative `modelUsage` totals become deltas against a per-process
baseline, with the first report of a resumed process proving where it
started (see Claude). A restart for external transcript writes forgets the
baseline. Codex and dsh report one call at a time; calls are summed per
model inside a turn and flushed by `usage/end` or an exit. Exit flushes a
partial turn once. Records carry the editor's handle, a `child` marker for
children, and a home-abbreviated root.

### Polling and reports

Quota pollers are derived from the effective agent executables, not from
editor-supplied commands: Claude through `claude -p /usage --output-format
json --no-session-persistence`, Codex through `codex app-server` and
`account/rateLimits/read`, dsh through its patched bridge and `balance`.
Polling settings are persisted in `<var>/emx/usage.json`, so polls continue
without an editor or across a daemon restart. `usage/configure` carries the
enabled agent list for display order; it does not override the poller
commands or the interval, which come from configuration.

The service checks every `min(usage.pollInterval, 60)` seconds and polls a
source only when its last reading is older than `usage.pollInterval`
(default 900 seconds). A failure backs off exponentially up to an hour.
`usage/refresh {force: true}` polls everything now; opening the usage page
forces a poll, and sending a message polls only the stale sources.

`usage/report` takes `range` (`today`, `week`, `month` or all), an exact
`filter`, `withoutCache` and `now`. It returns the total, sums grouped by
agent, model and root, calendar buckets, and the quota snapshot. Each window
carries a `forecast` or a `wait` (seconds until readings suffice). The rate
comes from the last seventh of the window (at least an hour; a day for a
weekly window) so idle days do not make the rest look plentiful. A window
forecasts once its readings cover half of that span.

### Outboxes and watermarks

Delivery is acknowledged and replayable in both directions.

- **A host outbox** (`<state>/emx/usage-outbox.json`) gives every producer a
  stable `source`, a monotonically increasing `sequence`, and entries
  (`{id, source, sequence, method, params}`) written before delivery. On
  hello, and every five seconds while entries remain, it offers them to
  Emacs. Emacs forwards each entry to the local daemon with the same source
  and sequence, adding the host label (quota) or remote root prefix (record),
  and acknowledges the host only after the local daemon's receipt.
- **An editor outbox** (`<var>/emx/editor-usage-<source hash>.el`) does the
  same for entries the editor still produces, including pending pre-upgrade
  records and quota readings. Each Emacs process has its own source and
  file. Recovery scans for files whose recorded process is gone on this
  host, or that have no recorded PID, merges their entries preserving
  delivery identities, saves the complete result before deleting the old
  files, and never allocates new sequence numbers from a dead source.
  Duplicate ids are removed.
- **The ledger owner refuses gaps.** A source's expected sequence is its
  watermark plus one, and anything at or below the watermark is a duplicate.
  A ledger record stores its delivery identity (`_delivery`) in the same
  append as its counters; a quota entry stores each producer's watermark
  (`_watermarks`). Startup rebuilds the watermarks from those operations if a
  crash preceded the separate index or the acknowledgment. A watermark only
  advances after a successful apply, so an uncertain reply is retried.
- **Legacy ids remain supported.** Ledger records can carry the old `id`;
  migration scans the whole ledger for ids without delivery identity, so a
  receipt older than any cache is not charged twice. Host array outboxes are
  migrated once to source/sequence entries.

### Emacs

Emacs only displays and forwards. It keeps the latest pushed quota snapshot
and draws:

- the echo line (`agent-usage-echo-mode`, in ` *Minibuf-0*`) with the 5-hour
  and weekly windows and account balances, right-aligned and clickable;
- the usage page (`C-c a u`), from one `usage/report`, with the accounts'
  allowances, headline numbers, timeline, and usage by agent, model and
  project. `RET` on a row filters to it; `r`, `d`, `w`, `m`, `a`, `c` change
  the range or cache toggle.
- `usage/changed` refetches a visible page; `usage/quotas` updates the echo
  line and page.

`agent-usage-clear` deletes the ledger after confirmation and keeps quotas.
`agent-usage-restart-service` reconnects and reapplies poll settings without
stopping agents; code changes go through the daemon's normal version and
restart path.

## Remote projects

A remote project is an `/rpc:` root. Its agent CLI runs on the project's
host, so it uses the host's toolchain, credentials and history. Emacs stays
local and attaches to the host's daemon through a forwarded socket.

```
 this machine                              │ host
                                           │
 Emacs ── Unix socket ── ssh -O forward -L ── Unix socket ── emx daemon ── agent CLIs
   │      (private dir)     over the tramp-rpc              (~/.cache/       │
   │                        ControlMaster                    emacs-agent/)   └ emx mcp
   └── local emx daemon (local sessions, config_* tools, usage ledger)
```

### Install

The runtime is content-addressed by the version `hello` reports. On user
action, Emacs reads `bin/emx daemon --manifest` (version, runtime paths, byte
sizes and SHA-256 hashes), copies each file into a unique private staging
directory under `~/.cache/emacs-agent/emx/<version>.stage-*` on the host,
verifies every size and hash, writes `.complete` containing the version, and
atomically renames the directory to `~/.cache/emacs-agent/emx/<version>/`.
A concurrent completed publication wins and the staging copy is removed.
Repairs publish a fresh `<version>.install-*` directory and atomically switch
the `<version>.current` symlink, retaining every published directory an
existing daemon might still import.

The manifest covers `emx/dist/**/*.js` and `*.json`, `bin/emx`, and the dsh
`.mjs`/`.yml` files, not sources, tsconfigs, dependency manifests, build
stamps, `node_modules` or tests. The version hashes exactly those paths and
bytes, so source mtimes or erased comments can rebuild without changing the
runtime version. A host never compiles or installs npm dependencies, and
needs no python3.

The home-directory bootstrap checks the actual Node (18.17+ or 20.3+) and the
marker/hash integrity, then runs `node <dir>/bin/emx daemon --client <id>
--ensure`. Exit 44 (missing or mismatched marker) and 45 (verified corrupt
files) trigger one install and retry; other failures surface their stderr.
The agents' credentials stay the host's own.

### Connecting

1. Emacs runs the bootstrap on the host through tramp-rpc, from the home
   directory so the daemon's base environment has no project direnv. It
   starts the daemon detached unless one answers, and prints the socket path
   and running code version.
2. Emacs forwards a private local socket to the remote one over the
   ControlMaster: `ssh -S <control> -O forward -L <local>:<remote> <host>`.
   The local directory is mode 0700.
3. Emacs connects to the local end and speaks exactly the local protocol.
   Nothing in the protocol knows it crosses a host.

Emacs shares one connection per host prefix and local var directory, with
sessions keyed by project. Separate projects on one host therefore share the
daemon's exclusive editor role, while local sessions and the usage-only
connection remain independent. Tool descriptions use the connection's
project place. The forward belongs to the ControlMaster; a new master gets a
new forward and the old one is cancelled.

### Losing the connection

When SSH drops, the forwarded socket closes. Emacs marks that host's
sessions `disconnected`; the daemon and agents keep running, approvals and
questions wait there, and editor calls fail at once with `Emacs is not
attached`. Once tramp-rpc is connected again, a 10-second timer notices it
without opening a connection itself; a new forward is made and each session
reattaches with `after: {epoch, seq}`, so it receives exactly the events it
missed, pending asks included. Sending to a disconnected session reconnects
first.

Automatic reconnect reuses the socket path and version remembered from the
last successful ensure. It never runs a host process, starts a remote
command or copies files; if the daemon no longer answers, the session stays
disconnected until a send or `M-x agent-emx-reconnect` runs ensure again. A
silent automatic hello times out locally after two seconds. Only existing
session ids reattach automatically; opening new sessions and copying skills
require user action. A changed master replaces and cancels the old forward
and its private local directory.

### Paths and editor calls

Paths stay in the host's terms on the wire; Emacs maps them to
`/rpc:<host>:...` names (`agent-session-expand-file-name`). Before
asynchronous opening, Emacs expands a remote root (including `~`) once on
the host and retains its `/rpc:` prefix for editor mapping. Editor results
have the remote prefix stripped before they go back to the agent. Pasted
image attachments are uploaded with `agent-remote-upload` before send or
steer, so the wire contains readable host paths.

A remote agent's MCP client runs `node <dir>/bin/emx mcp` on the host and
talks to the host daemon. Its editor calls travel over the client connection
to Emacs. The `config_*` tools are the exception described under MCP.

### Project environments

The daemon keeps the environment it was started with, from the host home
directory, as its base. For each project root it computes an overlay by
running `direnv export json` in that root. Direnv enforces `.envrc`
authorization; an unavailable or blocked direnv leaves the base environment
unchanged and shows a notice. The overlay keeps the same essential variables
as tramp-rpc (PATH, compiler, Rust, Python and Node paths, and similar), so
program lookup and the spawned CLI/MCP agree. Each CLI and the `emx mcp` it
launches inherit the project environment.

Results are cached per root for five minutes and invalidated by changes to
`.envrc` and `.direnv` entries in the root or its ancestors. Filesystem
inspection and direnv run asynchronously in Node, never on an Emacs timer.
The cached environment is used for tool descriptions and start validation;
an explicit session start refreshes that root's MCP clients, not a timer.

## Recovery after an Emacs restart

`hello` returns the session summaries before new session requests are
processed. Emacs rebuilds live top-level views by creation id and daemon id, then adopts
their children; a fresh `session/attach` replays transcripts and pending
asks into those views. This path is shared by local and host connections.
An existing view is reused when its daemon id or its native resume id, agent
and root match, so a restart does not open a second CLI.

Each editor start has a distinct identity token, so a late `session/open`
reply after switching agents is stopped rather than attached to a new view.
Stops that could not be delivered are retained and sent after the next hello.
Closing a view before its open reply arrives retains its creation id on the
connection, even after the buffer dies. After hello, `session/cancel` uses
the durable creation record to stop that attempt (or tombstone an opening
that has not arrived yet), before recovery runs. Cancelled summaries are
excluded from that hello's recovery. Recovery and attach choose one existing
view by creation id or daemon id and kill duplicates without stopping the
shared daemon session or letting the last attach steal its event route.

Skill roots travel as backend-neutral session context on `session/open` and
`session/context`, including for dsh parents; children inherit it, and Claude
and Codex translate it to their own launch flags and skill roots. Editor
tools are re-sent on hello and after a method or module change, so the daemon
and its MCP peers see the current catalog. The editor usage outbox is
restored and flushed; a host connection is re-established only on demand or
by the connected-host timer. If the daemon itself restarted, the session
table and transcripts are restored idle with a new epoch and no asks, and
the next send resumes each session.

## Security model

Owner-only sockets and directories on both ends, no other authentication.
Any process that can act as the user can drive that user's daemon, just as
it could drive the agent CLIs directly. The same applies to a host.

The editor role is exclusive, but that is routing, not authorization. MCP
connections are bound to one session and may only list and call tools;
usage connections may only use usage methods. The session id is not a
secret. Editor calls can only be answered by the attached editor; Emacs
derives the caller's root and place locally and does not trust wire text.
The daemon injects MCP only into its own agent processes.

The `config_*` tools are confined to the Emacs configuration checkout
outside `.git`, with symlink resolution through the deepest existing
ancestor, exact replacement checks, numbered reads, unsaved-buffer refusal
and visiting-buffer refresh. This is a guardrail against editing the wrong
host's files, not a sandbox: `eval` is unrestricted.

Host installs and forwarded sockets are owner-only. The host config may
override only executables. Agent credentials never pass through emx; they
stay in each CLI's own credential store.

## Localization

Agent-facing text is English: replies, tool names and output, prompts,
errors returned to agents, and MCP descriptions. UI text is Chinese.

The daemon does not render conversation text. Notices and tool views are
structured: `{kind: "effort-after-turn"}`, `{kind: "restart-for-external"}`,
a tool view with `kind: "plan"`, and the like. Emacs maps notice kinds to
its own strings (`agent-emx-notice-formats`) and falls back to showing an
unknown kind dimly. Tool titles are the agent's own command, path or query;
Emacs words the few it knows (`todo_write` / `TodoWrite`, `exit_plan_mode`,
`skill`) in Chinese. The short UI labels the daemon does build (quota window
labels such as `5h` and `周`, and collaboration confirmation titles) are
Chinese. Errors the daemon returns to agents stay English.

## Code layout

```
bin/emx                  launcher: locate/build and pin dist, import cli/main.js
emx/cli/main.ts          command dispatch, help and MCP instructions
emx/cli/args.ts          positional/flag arguments, JSON files and stdin
emx/cli/emacsclient.ts   bare CLI agent-ui-rpc transport and deferred polling
emx/config.json          tracked configuration
emx/config.ts            validation, merge, push, watched reloads
emx/daemon/              socket server, sessions, events, editor calls, locks
emx/daemon/collab.ts     children, naming, mailbox, session_* tools
emx/daemon/config-files.ts  local checkout file tools for host daemons
emx/backends/            backend interface; claude.ts, codex.ts, dsh.ts;
                         history.ts for native past-session discovery
emx/usage/               ledger, quotas, forecasts, polls and turn accounting
emx/remote/              project environments and durable host usage outbox
emx/mcp.ts               stdio MCP facade over the daemon socket
emx/package.json         pinned local TypeScript and Node types
emx/tsconfig.json        check-only config, including the TypeScript tests
emx/tsconfig.build.json  ESM build with rewritten imports
emx/dist/                generated runtime; only the manifest's files ship
lisp/agent/agent-emx.el  daemon client, session views, editor-call handling
lisp/agent/agent-emx-remote.el  host install, forwarding, config and usage
lisp/agent/agent-emx-config.el  cached display policy
lisp/agent/agent-collab.el  mention enrichment and child progress in the UI
lisp/agent/agent-usage.el   quota display and durable usage producer
lisp/agent/agent-ui.el      editor methods, deferred results, tool catalog
lisp/agent/backend/agent-{claude,codex,dsh}.el  enabled-agent registration
lisp/agent/backend/dsh/emacs-bridge.mjs  the dsh plugin; emacs.yml,
                         no-subagents.yml
test/emx/                node --test suites, with fake CLIs
test/agent-emx-*.el      ERT suites: daemon client, host simulation, smoke
```

## Known limitations and open questions

- **Lifecycle operations wait in order.** A stuck environment lookup,
  backend initialization or submission RPC (including a dsh slash command)
  delays later stop requests until that operation settles; the queue does not interrupt an in-flight operation. Adapter RPC
  timeouts still apply. Terminal creation keys are retained for 30 days;
  replay after expiry may create a new session. Atomic file replacement
  covers process crashes, not power-loss durability (no fsync).

- **`session/open.fork` is rejected.** Native forks exist only through
  `session_start context=fork`, and only for a caller with a live native
  conversation.
- **Real-host transport is simulated in tests.** The remote path is covered
  by a temporary home, stubbed tramp/SSH and a local host simulation. Actual
  tramp-rpc/sshd behavior, stream-local forwarding policy, socket-path limits
  and ControlMaster replacement still need confirming on a real host. The
  `emx connect` pipe fallback for hosts that disable stream-local forwarding
  is not built.
- **Children do not survive a daemon crash.** They are not resumable and are
  deliberately left out of the restored session table.
- **Usage counts only daemon sessions.** Work in a terminal or another
  client is not counted, and the ledger has no prices, since the accounts are
  subscription plans.
- **Configuration is JSON without comments.** Whether the configuration
  format needs comments remains open.
