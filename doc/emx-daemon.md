# emx daemon: agents outside Emacs

Status: phases 1–7 implemented on `claude/emx-daemon`.
Agent execution remains opt-in through `agent-emx-agents`; all usage now shares
the daemon. Mixed Lisp/daemon and cross-daemon collaboration have the
limitations below. Remote transport is tested with a locally simulated host;
a real tramp-rpc/sshd test is still required.

## Goal

Move everything about running agents out of Emacs into a long-lived emx
daemon. Emacs keeps the display and the interaction: session buffers,
input, the footer's confirmations and questions, canvas pages, review
buffers, and the editor operations agents call (`open`, `read_buffer`,
`context`, `eval`, ...).

What we get:

- Emacs never parses an agent's stream, replays a history or runs a
  backend's state machine, so a busy agent can't freeze it. (Today large
  histories already had to move into python3 scripts for that reason.)
- Sessions outlive Emacs. Restarting Emacs, a failed reload, or a
  `cl-defstruct` change that needs a restart no longer kills agents;
  Emacs attaches again and catches up. Only remote sessions get this today,
  through `agent-keeper.py`.
- Policy lives in one place and is tested with `node --test`: approvals,
  children and their mailbox, concurrency limits, usage. The differences
  between Claude, Codex and dsh (like dsh's MCP calls needing our own gate)
  are absorbed by one layer instead of three Lisp files.
- Profiles, agents and policy become emx configuration, not defcustoms.

Non-goals: a second front end (it should become possible, but nothing is
built for it), changing how sessions look, moving canvas or review UI.

## Decisions taken

- **Independent daemon.** It is not a child of Emacs. Emacs connects to it
  and may come and go.
- **Agent configuration is emx's.** Agents, profiles (roles), start
  guidance, limits and approval policy move from `agent-collab-profiles`
  and friends into an emx config file.
- **TypeScript, run by Node directly.** Node strips the types itself
  (22.18 and later), so there is no build step; only erasable syntax (no
  `enum`, `namespace` or parameter properties). `tsc --noEmit` joins the
  checks, with `@types/node` as the only development dependency
  (`emx/package.json`, `emx/node_modules/` ignored). `bin/emx` and the
  dsh plugin remain JavaScript. Usage is now TypeScript under `emx/usage/`; the plugin runs inside dsh and stays JavaScript.
- **A daemon on every host.** A remote project's agents run under a daemon
  on that host, which Emacs attaches to like the local one (see Remote
  projects). It replaces the keeper and the MCP relay.
- **Assumed, to confirm:** canvas rendering and the review UI stay in
  Emacs; review's data and git work may move later.

## Processes

```
                 Unix socket (owner-only)
 Emacs  <───────────────────────────────>  emx daemon ── claude -p ...
 (view, input,        JSON-RPC 2.0          (sessions,    codex app-server
  editor tools)       NDJSON both ways       policy,       dsh + emacs-bridge.mjs
                                            usage)
                                              ▲
 agent's MCP client ── emx mcp (stdio) ───────┘  thin client of the daemon
```

- **One daemon per checkout.** Its socket and state live under the
  checkout's `var/` (`var/emx/daemon.sock`, falling back to
  `$TMPDIR/emx-<hash of checkout>.sock` when the path is too long for a
  Unix socket). A worktree therefore runs its own daemon and never touches
  the one the user's Emacs uses: that is how this branch is developed.
- **Start:** Emacs runs `emx daemon` detached (`setsid`) when it finds no
  live socket; a second start finds the socket and exits. `emx daemon
  --stop` and `M-x` equivalents stop it.
- **Lifetime:** like tmux, it lives while it has something to keep: an
  attached client or a live agent process. With neither for
  `daemon.idleExit` (default 15 minutes) it writes its session table and
  exits; the next client starts it again and finds the sessions there.
  Sessions are records, not processes: an idle session's CLI is stopped
  after `sessions.hibernateAfter` (default 2 hours) and resumed on the
  next send (`--resume`, thread resume, dsh resume), a few seconds that
  cost no cache since the prompt cache has expired by then. A session
  running a turn or waiting on an approval or a question keeps its process.
  Children keep theirs too: Claude's and Codex's save no transcript
  (`--no-session-persistence`, ephemeral threads), so they can't resume,
  and no child is hibernated; they close when done anyway.
- **Stale code:** a daemon reports the hash of the code it runs on
  `hello`. When the client's differs, a daemon with no live agent restarts
  at once; otherwise the client says so and the daemon restarts once every
  agent is idle, hibernating them first. Current implementation: `--ensure`
  compares `codeVersion()` with `ping`; when ping advertises
  `capabilities.stopIfIdle: 1`, it requests `daemon/stop {ifIdle: true}`.
  The daemon atomically refuses with `{stopped: false}` if an agent is live
  or starting (including a pending child start); otherwise it commits to
  shutdown before returning `{stopped: true}`. Refusal returns `stale: true`.
  Emacs displays a Chinese notice offering `M-x agent-emx-restart-daemon`. This explicit command requires idle,
  resumable sessions, persists and stops them, then starts current code; active
  turns, asks and ephemeral children must finish first. Automatic restart when
  all agents become idle remains deferred. Daemons without `stopIfIdle`
  are always left running with `stale: true`; only the explicit restart
  command may stop them. Probes never take over the editor connection.
- **One Emacs.** A daemon serves a single Emacs, as one Emacs server
  serves all its frames and emacsclients. A second Emacs saying `hello`
  takes over and the first is told it was replaced. Agents' `emx mcp`
  processes also connect to the socket, any number of them, but only to
  run tools. Usage producers/subscribers instead say `usage/hello`: any number
  can publish records/readings and receive quota snapshots without taking over
  the editor. Only sessions and editor tools require the exclusive role.
- **Crash:** agent processes die with the daemon (they are its children).
  The session table (`var/emx/sessions.json`) is written on every change,
  so the next daemon lists the sessions and resumes them on the next send,
  as after hibernation. A crash is noticed by the client losing the
  socket; Emacs starts a daemon again and reattaches.

## Session model (owned by the daemon)

A session record holds what `agent-session` holds today, minus the buffer:
agent, root, status (`starting`, `idle`, `running`, `disconnected`,
`exited`), info (model, tokens, title, handle, parent, profile...),
settings (model, effort, mode), the queue, the transcript, pending asks,
children, and backend state.

The **transcript** is an ordered list of blocks with stable ids:
`user`, `text` (assistant), `thinking`, `tool`, `notice`. A tool block
carries a normalized view computed by the backend adapter (what
`agent-claude--tool-view` and its peers compute today): `kind` (`command`,
`read`, `edit`, `search`, `web`, `task`, `question`, `plan`, `mcp`,
`other`), `title`, and per kind `command`, `path`, `diff` (unified diff
text) or `items` (plan entries with status). Labels are never prose from
the daemon: see Localization.

## Protocol

JSON-RPC 2.0, one JSON object per line, both directions over the socket.

### Client → daemon

| method | params | result |
|---|---|---|
| `hello` | `{client, version, tools?}` | `{daemon, version, config}` |
| `sessions/list` | `{root?}` | live sessions (summary) |
| `sessions/history` | `{root, agent?}` | resumable past sessions |
| `session/open` | `{agent, root, resume?, fork?, settings?, parent?}` | `{id}` |
| `session/attach` | `{id, after?, turns?}` (`turns` defaults to 20) | snapshot, then events (below) |
| `session/detach` | `{id}` | `{}` |
| `session/send` | `{id, text, images?}` | `{}` (queued while running) |
| `session/steer` | `{id, text, images?}` | `{accepted}` |
| `session/interrupt` | `{id}` | `{}` |
| `session/configure` | `{id, model?, effort?, mode?}` | `{}` |
| `session/answer` | `{id, ask, choice?, answers?}` | `{stale?}` |
| `session/earlier` | `{id, turns?}` | `{}` (blocks arrive as events) |
| `session/stop` | `{id}` | `{}` |
| `config/get` | `{}` | `{config, errors}` |
| `config/reload` | `{}` | `{config, errors}` |
| `usage/configure` | `{agents?, pollInterval?, pollers?: {source: {command: argv}}}` | `{quotas}` |
| `usage/report` | `{range?, filter?, withoutCache?, now?}` | report (unchanged format) |
| `usage/refresh` | `{force?}` | `{}` (polls asynchronously) |
| `usage/clear` | `{}` | `{}` (keeps quotas) |

### Daemon → client (notifications, per attached session)

Every event carries `{session, seq}`; `seq` increases by one per session.

- `status {status}`, `info {info}` (changed keys), `settings {settings}`
- `capabilities {capabilities}`: complete models (id, name, description,
  efforts, defaultEffort), modes, and slash commands (name, description,
  hint); also included in `AttachResult` and persisted with the transcript
- Usage call/end and raw quota readings are internal backend events. The
  daemon records and merges them before logging editor events; they never
  go over the socket or replay. Emacs receives only the global quota and
  report-invalidation notifications below.
- `block/add {block, after?}` (`after` places it, e.g. earlier history)
- `block/append {id, text}` (streamed text), `block/done {id}`
- `block/update {id, ...fields}` (tool result, output, error)
- `block/remove {ids}` (an abandoned attempt)
- `ask/add {ask}`, `ask/remove {id, resolution}` (see Approvals)
- `notice {kind, ...fields}`
- `queue {items}`, `children {ids}`
- `usage/quotas {quotas}` (global, also sent after hello)
- `usage/changed {}` (global, after appending/clearing ledger records)

Phase 2 additions are data only: questions carry an optional `intent`
object unchanged (dsh's `{kind: "plan-review", approve: label}` selects
Emacs's plan approval UI). Phase 3 removes `OpenParams.mcpServers`:
the dsh backend builds its own `node <checkout>/bin/emx mcp` spec using
the daemon socket, daemon session id, cached read-only names and the
same 1,800,000 ms timeout as the Lisp backend. No editor socket, buffer
name or stamp path is persisted in a session. `Settings.beforePlan`
retains the permission mode beneath plan mode, including on open/resume.
A history user block may carry `imageCount` when original file paths are
unavailable; Emacs renders its image labels.

The implemented contract is `emx/daemon/protocol.ts`. In particular,
`session/send` returns `{queued}`, `session/earlier` takes `{id, before,
turns?}`, insertions use `block/add {block, before?}`, completion uses
`block/update {id, fields}`, and notices are blocks with a `notice.kind`.
`sessions/history` and the direct `session/open.fork` parameter remain later
work. Native forks are available through `session_start context=fork`.
Configuration, children, editor calls and usage requests are implemented.
`usage/record {record}` and `usage/quota {agent, host?, windows?, balance?,
plan?, credits?}` are editor-only notifications for the remaining Lisp
backends; MCP peers and replaced editors cannot write usage.

### Attach and catching up

`session/attach` returns a snapshot (pending asks, queue, status, info,
settings, capabilities, `epoch`, `seq`, replay mode and whether earlier
turns remain). A fresh attach then streams history blocks in order, ending
with `history/done`. Passing `after: {epoch, seq}` instead replays only the
events after that sequence number in the same epoch from a per-session ring buffer, falling back to a snapshot when they
have been dropped. This is the keeper's byte-offset replay lifted to
events. Emacs keeps the last `seq` per buffer, so a reconnect (daemon or
Emacs side) redraws nothing it already shows.

### Daemon → Emacs requests (editor calls)

`editor/call {method, params, caller}` → result or error. The daemon sends
it to the attached Emacs for the editor tools agents call through MCP
(below). With no Emacs attached it fails at once with an error saying so;
calls that wait on the user (`session_ask` confirmations, canvas buttons)
keep using the existing defer-and-poll scheme between the daemon and Emacs.

## MCP: `emx mcp` becomes a daemon client

Phase 3 is opt-in through `EMX_DAEMON_SOCKET`. With it set, `emx mcp`
loads `emx/mcp.ts`, connects only to that socket and identifies itself
with `mcp/hello {session: EMX_SESSION}`. This connection cannot say
`hello`, take over the editor or control sessions. Without the variable,
the existing emacsclient temp-file path, stamp watcher and remote-only
`config_*` tools are unchanged. Bare CLI commands also keep that path.
Host daemon sessions also offer `config_read`, `config_edit` and
`config_write`, forwarded through Emacs to the local daemon.

An MCP connection binds once to an existing daemon session; a second
`mcp/hello` on that connection is an error, even for the same session.
The owner-only socket trusts every process running as the user, like the
rest of the design. There is no per-session authentication: agents can
already run emacsclient themselves. The session id routes calls; it is
not an authentication token.

| direction | method | payload / result |
|---|---|---|
| MCP → daemon | `mcp/hello` | `{session}` → `{}` |
| MCP → daemon | `mcp/tools` | `{}` → `{tools}` |
| MCP → daemon | `mcp/call` | `{name, arguments?}` → method result or JSON-RPC error |
| MCP → daemon | `notifications/cancelled` | `{requestId}` of the socket call |
| editor → daemon | `hello` | `{client, version, tools?: {tools, readOnly}}` |
| editor → daemon | `editor/tools` | notification `{tools, readOnly}` |
| daemon → MCP | `mcp/tools_changed` | notification `{}` |
| daemon → editor | `editor/call` | `{method, params, caller: {session, root, place: null}}` |

- Editor methods and canvas still come from Lisp. Phase 5 replaces the five
  collaboration definitions with daemon definitions and handles their calls
  directly, even without Emacs; other methods retain the editor transport.
  Emacs sends `agent-ui--describe nil` and the private audited read-only
  names on hello. The existing two-second signature timer also checks
  ready daemon connections and sends `editor/tools` when definitions or
  permission classifications change. Stamp files remain for Lisp-started
  Claude/Codex/dsh sessions until their cut-over.
- The daemon saves the last definitions and classification atomically in
  `<stateDir>/tools.json`. `mcp/tools` returns only the definitions, even
  without an editor or after daemon restart. Calls without an editor fail
  immediately with `Emacs is not attached`. Neither readOnly nor
  `readOnlyHint` is exposed in MCP tool definitions. Dsh uses the private
  names in its existing bridge approval gate when mounting the server.
- `mcp/tools_changed` becomes MCP `notifications/tools/list_changed` on
  stdio. The fork-cache rule stays: definitions and classifications depend
  on configuration and place, never on the calling session.
- Emacs maps the daemon session id to its attached session buffer, derives
  root/place locally, and calls `agent-ui-call` with `agent-ui-caller`
  bound just as for `agent-ui-rpc`. Unknown/unattached callers fail; caller
  root text is not trusted. The reply is `{ok, result}` or `{ok, pending}`
  or `{ok: false, error}`, matching the legacy transport.
- The daemon polls deferred results with `editor/call` of `_poll` every
  second. Cancellation stops waiting and cancels the pending result; late
  deferred ids are released too. Editor disconnection or replacement
  fails outstanding calls rather than replaying their side effects on
  another editor. Stdio tool failures are MCP `isError` results.

## Backends

Each backend is a daemon module with the interface of today's generics:
`start`, `send`, `steer`, `interrupt`, `configure`, `stop`, `history`,
`fork`, `models`, `modes`, `commands`, `reattached`. It turns its CLI's
stream into the session events above.

- **dsh** first: the bridge plugin (`emacs-bridge.mjs`) already speaks a
  backend-neutral JSON-RPC vocabulary (`text`, `tool`, `tool/done`,
  `turn/end`, `usage`, `approval`, `question`), so the adapter is thin. The
  plugin keeps running inside dsh; its peer becomes the daemon. Phase 2
  implements this in `emx/backends/dsh.ts`: local stdio transport, presets
  and plan mode, configuration, slash commands, steering/cancel, tool views,
  asks, discard, usage/balance, version warnings and resume transcripts.
  Phase 7 maps remote project roots to host paths before opening sessions
  on a host daemon. Native subagents are always disabled on this path. `EMX_DSH_EXECUTABLE` overrides `dsh` for installations and fake
  protocol peers in tests; no API credentials pass through this option.
  External session discovery stays on the old Lisp path; phase 5 adds
  native conversation forks through the daemon collaboration tools.
- **Claude** is the hardest and shaped the event set: restart with
  `--resume` before the next send (effort change, messages from other
  clients, tools changed); `control_request` permissions and model / mode
  switches; history loaded in pages and inserted before the first block
  (`block/add` with `after`); following the transcript file for messages
  written by Claude Desktop or a terminal; `modelUsage` running totals
  turned into deltas. Reading `~/.claude/projects/...jsonl` moves from the
  python3 scripts to streaming Node code for local projects.
- **Codex**: `codex app-server` JSON-RPC; resume a thread in a new process
  when its tools changed.

### Phase 4a: local Claude sessions

Implemented in `emx/backends/claude.ts` behind `agent-emx-agents` containing
`claude`; the Lisp backend remains the default. The daemon runs the same
stream-json command and permission modes, injecting its own MCP socket and
session id. `session/open.claude` supplies `skillsDir` and
`supersededSkills`, retained for restarts. Permissions preserve the original
input and suggestions, including JSON false/null, arrays and empty objects;
AskUserQuestion adds answers to a copy of that original input. Tool views,
thinking, text, results, errors and rate-limit windows use existing events.
Denied tool results retain the `declined` status.

Model and permission mode change through control requests. Effort changes
restart with `--resume`, immediately when idle or after the active turn;
non-persistent children report a notice instead. Running `modelUsage`
totals become deltas using the Lisp baseline-proof rules, so a resumed
process cannot charge historical totals as the current turn.

History uses two streaming JSONL passes, retaining only the last page's
turn offsets and display blocks. `session/earlier` calls an optional backend
history hook beyond the daemon's loaded transcript. The saved byte boundary
survives daemon persistence. A directory watch coalesces writes for 500 ms,
shows messages from entrypoints other than `sdk-cli`, and restarts with
`--resume` before the next send; that restart forgets the usage baseline.
The watcher also handles transcripts created during the first turn.

`EMX_CLAUDE_CONFIG` is transitional daemon configuration: a JSON object
with `executable`, `extraArgs`, `disallowedTools` (default `Agent`,
`Workflow`, `SendMessage`, `ListAgents`) and `historyTurns` (default 20).
`EMX_CLAUDE_EXECUTABLE` overrides the executable for installations/tests;
`EMX_CLAUDE_PROJECTS_DIR` isolates transcript fixtures. Fake CLI tests do
not contact the API. Phase 5 replaces those defaults with the shared
config-file/watcher while retaining environment overrides for fixtures.

Remote projects use a host daemon in phase 7. Phase 5 supports native forks
through `session_start context=fork`. Historical
session discovery stays on the Lisp side, which already scans Claude's
project directory; the daemon handles live sessions and transcript paging.
Claude receives MCP tool-list notifications directly, so it does not need
Codex's tool-change process restart.

Phase 4a verification (2026-10-20): `tsc -p emx` passes; the combined
daemon/MCP/usage Node suite passes 104 tests, including 18 fake-Claude
cases. The AGENTS ERT suite plus daemon UI tests passes 251 tests with one
environment-dependent scroll test skipped. Evil-on/off byte compilation
has only the two existing lang-agda slot warnings; the language ERT suite
passes 23 tests with evil enabled. A single real Haiku turn through an
isolated daemon and temp project sent `say hi in one word` and streamed
`Hi` (one delta), then `usage/end` and idle. The usage delta for
`claude-haiku-5-5` was input 2, cacheRead 0, cacheWrite 19157, output 5.
No default Emacs server or daemon was used and no config was reloaded.

### Phase 4b: local Codex sessions

Implemented behind `agent-emx-agents` containing `codex`; nil remains the
Lisp default. `emx/backends/codex.ts` maps app-server items, reasoning,
commands and streamed output, file diffs, MCP calls, plans, web searches,
approvals and user questions into the existing blocks and asks. Every
turn carries model, effort, approval policy, sandbox and reviewer, using
the Lisp mode mapping. Configuration reads preserve the user's developer
instructions before appending the Emacs context; failures omit the override
and show a notice. `session/open.codex` carries `skillsRoot` and
`supersededSkills`, retained with the session for process restarts.

The MCP subprocess runs this checkout's `node bin/emx mcp` with the daemon
socket and session id, and a 1,800-second timeout. A changed editor tool
catalog or permission classification triggers a fresh process and
`thread/resume` before the next message. Children use ephemeral threads
and retain their initial tools. `EMX_CODEX_CONFIG` is transitional daemon
configuration, a JSON object with `executable`, `extraArgs` and
`nativeSubagents` (default false). `EMX_CODEX_EXECUTABLE` overrides the
program for installations and fake app-server tests; no credentials are
passed in either option.

Live token notifications become `usage/call` only inside a turn and when
the thread total changes; `usage/end` flushes them. History and duplicate
notifications never count. `quota/rate-limits` carries sparse `plan`,
`windows` (id, minutes, used fraction, resets) and numeric or `unlimited`
credits. A fresh attach republishes the cached account reading after
`history/done`, without replaying token usage. Resume fetches all pages of
`thread/turns/list`; the common session layer serves the requested last
turns and `session/earlier`. A crashed app-server resumes its saved id on
the next send.

Remote roots use a host daemon in phase 7. Phase 5 implements ephemeral `thread/fork`
through `session_start context=fork`. Discovering
past sessions stays in Lisp's `thread/list` implementation; use the Lisp
registration to browse sessions outside the daemon's own session table.
Shared historical discovery remains later work.

## Localization

Conventions stay: agent-facing text in English, UI text in Chinese. The
daemon never writes UI prose. Notices and labels are structured
(`{kind: "effort-after-turn"}`, `{kind: "restart-for-external"}`, tool view
`kind: "plan"`); Lisp maps kinds to Chinese strings. Errors the daemon
returns to agents stay English.

## Configuration

During migration, `agent-emx-agents` is a Lisp defcustom (default nil).
Set it before loading dsh, or use `(customize-set-variable
'agent-emx-agents '(dsh))`, to register new dsh sessions with `:backend emx
:emx-agent "dsh"`. Removing dsh restores its Lisp registration; existing
sessions retain their backend. The asynchronously received effective
configuration supplies launch policy and collaboration policy on both
paths; the old Lisp options remain offline defaults.

Phase 5a implements `emx/config.json` and the optional, git-ignored
`<var>/emx/config.json` override. Objects merge deeply; arrays, scalars and
null replace. Unknown fields, malformed JSON and invalid types report field
paths and keep the last good effective config. Both files are polled every
250 ms (including atomic replacement); reload is debounced 75 ms.
`config/get` and `config/reload` return `{config, errors}`. Hello includes
`config`; changes push a global `config {config, errors}` notification and
`mcp/tools_changed`.

Schema:

- `agents`: executable, title, extraArgs, Claude disallowedTools/historyTurns,
  Codex/dsh nativeSubagents. Enabled agents remain `my/agents` during migration.
- `profiles`: named objects with agent, model, effort, mode, cost, description,
  confirm. All current profile keys are preserved.
- `collab`: startGuidance, maxActive, handoffLimit, closeFinished, confirm,
  textLimit, replyLimit, confirmTimeout, handleTimeout, handleCommand,
  agentHandleCommands, tools (verbatim descriptions and input schemas),
  prompts (verbatim task, fork, handoff, mailbox and naming text).
- `usage.pollInterval`, `daemon.idleExit`, `sessions.hibernateAfter`: seconds.

Lisp collaboration reads the asynchronously pushed config from
`agent-emx-config.el`; accessors never make blocking requests. Its defcustoms
remain **offline fallbacks**, used before a config arrives. A disconnected
editor retains its last effective snapshot until reconnection. Display
preferences remain in Lisp. The transitional backend environment overrides
remain for protocol fixtures and installations; file values otherwise apply
on the next spawn. Existing processes retain their launch flags. Legacy
`usage/configure` still accepts Lisp quota-poller registration, but its
legacy pollInterval field cannot override the file's polling interval. Tests
that disable polling set it to zero in their temporary override file.

### Phase 5b: daemon collaboration

`emx/daemon/collab.ts` serves `sessions`, `session_read`, `session_ask`,
`session_start` and `session_stop` directly. Definitions come from the
configuration, filtered by installed executables and the enabled agents
Emacs sends on hello. Enabled agents are persisted with collaboration
state. Definitions never depend on caller identity, status, model or child
status; a Node test compares them byte for byte with Lisp's definitions.
Refusals happen at call time.

The daemon names first submissions with the configured cheap commands (own
agent first, global fallback), limits concurrent starts including pending
confirmations, caps modes, and implements fresh/handoff/fork. Handoff text
is fixed per parent turn and puts the task last. Claude forks use resume
plus fork-session and no persistence; Codex forks are ephemeral and omit
new developer instructions; dsh flushes the parent before forkFrom and uses
the native parentSession. Children do not hibernate or survive a daemon
crash as resumable sessions.

Pending replies and batched mailboxes live in `<var>/emx/collab.json`.
Long replies are saved under `<var>/replies/`. The original agent-facing
wording, hidden sender notes, tool summary and one-message idle delivery
are preserved. Visible user text and origins are retained separately from
hidden notes in the transcript and persisted queue. A child closes after
its result reaches the mailbox, unless failed or visible in Emacs. Closing
a parent stops its children; session_stop cancels its expected reply.

Emacs receives private `editor/call` methods `_session_open` and
`_session_visible` (never MCP definitions), plus `collab/closed` and the
session summaries. It creates and attaches a child view without a second
CLI, links the parent's oldest unlinked session_start block, and reuses
native parent/footer approval mirroring. Reconnect reattaches existing
child views. With no editor, collaboration continues; user confirmations
remain pending until answered or timed out. An unresponsive visibility
query conservatively keeps the child open.

**Cross-path choice:** the migration does not bridge daemon tools to Lisp
sessions. Daemon sessions list/read/ask daemon sessions only. Lisp tools
retain their current buffer-based behavior and can inspect attached daemon
views, but this is not a symmetric cross-path collaboration API. Use the
same execution path for sessions that need to collaborate. A complete
bridge must route asynchronous confirmations and reply tracking across both
owners; it is deferred rather than duplicating mailbox ownership.

## Approvals

The daemon decides; Emacs shows and answers. How the three CLIs treat
their own subagents (checked 2026-10-20 against Claude Code's docs, the
openai/codex sources and the deepseek-harness sources):

| | Claude Code | Codex | dsh |
|---|---|---|---|
| child's permissions | parent's mode and rules | parent's approval policy, sandbox and reviewer, copied at spawn | fixed at spawn |
| a call that needs approval | prompts the user in the main session | commands prompt the user; MCP calls are refused with "ask the parent agent" | refused; the child reports it to the parent |
| automatic reviewer | auto mode's classifier | Guardian (`auto_review`) | auto-review plugin |
| parent agent approves | no, by design | no interface | no; Auto weighs a parent's explicit instruction |

We follow them:

- **Read-only tools run without asking**: the audited read-only emx
  methods, and each CLI's own read-only actions as it judges them. For
  Claude this means `--allowedTools mcp__emacs__<method>`, for Codex
  per-tool approval on those methods, for dsh the bridge's gate.
- **`auto` hands approvals to each backend's own reviewer** (Claude's
  classifier, Codex's Guardian, dsh's auto-review). What the reviewer
  refuses, or can't decide, reaches the user.
- **No delegation to the parent agent.** A child's request is shown in the
  parent's footer too, as today; the user answers it in either place.
- **A child that hits a limit hands it back**: it reports what it needs
  (for a reviewer, a verification request) and the parent, which has the
  wider permissions, does it or starts a session that can.
- First answer wins; a late answer gets `stale`.

## Remote projects

Agents selected by `agent-emx-agents` run under the host daemon. Agents
still on their Lisp backend retain `agent-keeper.py`, the local emx and
`agent-remote-relay.py` over the `-R` bridge until phase 8. Existing
sessions keep their original backend.

```
 this machine                         │ host
                                      │
 Emacs ── unix socket ── ssh -O forward -L ── unix socket ── emx daemon ── agent CLIs
  │      (private dir)     over the tramp-rpc               (~/.cache/      │
  │                        ControlMaster                    emacs-agent/)   └ emx mcp
  └── local emx daemon (local sessions, config_* file tools, usage ledger)
```

### Install

The daemon's code is copied to the host content-addressed:
`~/.cache/emacs-agent/emx/<hash>/`, the hash being the one `hello`
reports, so a copy is made once per version and several versions can
coexist (as the dsh plugin is copied today). `daemon --manifest` returns
this version, runtime paths, byte sizes and SHA-256 hashes: TypeScript/JSON under `emx/`, `bin/emx`,
and the dsh `.mjs`/`.yml` files. `node_modules` and tests are excluded.
On user action, Emacs copies through the file handler into a unique private
staging directory beside the target, verifies every size and hash, and writes
`.complete` containing the version. An atomic rename publishes the directory;
a concurrent completed publication wins and the staging copy is removed.
Ensure checks the marker's contents. A failed ensure repairs the installation
and retries once, on the user-triggered path only. The host needs Node 22.18 or
later, checked in the same single round trip that looks up the agent
programs when a remote session opens (`agent-session-check-programs`);
python3 is no longer needed. The agents' credentials stay the host's own,
as today.

### One daemon per host and client checkout

The host runs one daemon per user and per client checkout:
`~/.cache/emacs-agent/emx/run/<client id>.sock`, in a directory of mode
0700. If the socket path exceeds 100 bytes (below both macOS and Linux
limits), it uses a stable hash of the client id in `$XDG_RUNTIME_DIR`, or
`/tmp/emx-<uid>/` if unset or too long. The fallback directory must be owned
by the user, mode 0700 and not a symlink. The client id is a hash of the checkout's path and the machine's
name. So this branch's worktree and the user's main checkout get separate
daemons on the same host, and two machines never share one. Its state
(session table, usage outbox) lives next to it in
`~/.cache/emacs-agent/emx/state/<client id>/`. The id is the first 16 hex
digits of SHA-1(checkout real path, NUL, machine name). Session state,
logs and the outbox use the existing `emx/` subdirectory there; the host's
usage files are only a cache for local quota freshness/reporting. The
local daemon remains the authoritative combined ledger. `--client` and
`--var` are mutually exclusive; `--stop --client <id>` stops only that
host/client daemon.

### Connecting

1. Emacs runs one command on the host through tramp-rpc:
   `node <dir>/bin/emx daemon --client <id> --ensure`. It copies nothing;
   it starts the daemon detached (`setsid`) unless one answers on the
   socket, and prints the socket path and the running daemon's code hash.
   Emacs wraps this in a shell check for the version's `.complete` marker.
   A missing or mismatched marker returns status 44; an explicit connection
   repairs a failed install and retries once. Ensure and copies run before
   asynchronous local callbacks, never in timers or sentinels. Ensure
   retains a stale daemon with live agents; once none are live, it replaces
   it using the same atomic stop-if-idle guard as local ensure.
2. Emacs forwards a private local socket to the remote one over the
   ControlMaster: `ssh -S <control> -O forward -L <local>:<remote> host`,
   as `agent-remote-bridge` does today with `-R`. The local end lives in a
   temporary directory of mode 0700.
3. Emacs connects to the local end and speaks exactly the local protocol:
   `hello`, `session/attach`, events, editor calls. Nothing in the
   protocol knows it crosses a host. Emacs shares one connection per host
   prefix and local var directory, with sessions still keyed by their
   project places: separate projects must not take over the same daemon's
   exclusive editor role. Tool descriptions use the connection's project
   place. Local sessions and the usage-only connection remain independent.

The forward belongs to the ControlMaster, so a new master (after a
reconnect) gets a new forward, as the bridge does today. A host where
stream-local forwarding is disabled (`AllowStreamLocalForwarding no`) can
fall back to piping the connection through a tramp-rpc process running
`emx connect`, at the cost of a slower path; we build that only if a host
needs it.

### Losing the connection

When SSH drops, the forwarded socket closes: Emacs marks that host's
sessions `disconnected` and the agents keep running under the daemon,
which is what the keeper does today. Editor calls fail at once with
"Emacs is not attached" (what the relay does today), and approvals and
questions wait in the daemon. Once tramp-rpc is connected again (Emacs
notices on its existing hooks and timer, never opening a connection
itself), Emacs makes a new forward and reattaches each session with
`after: seq`, so it receives exactly the events it missed, pending asks
included. Sending to a disconnected session reconnects first, as today.
Automatic reconnect reuses the socket path remembered from the last successful
ensure; it never runs a host process, including through `make-process` with
a file handler. If the daemon no longer answers, the session stays disconnected
until a send or `M-x agent-emx-reconnect` runs ensure again. A silent automatic
hello times out locally after two seconds. Only existing session ids are
reattached automatically; opening sessions and copying skills require user
action. Forward setup uses
`agent-remote--master` in connected-only mode, which checks the existing
master without `file-directory-p` on the project. The 10-second reconnect
timer never opens a host, starts a remote process or copies files. A changed master replaces
and cancels the old forward and its private local directory.
`agent-emx-restart-daemon` targets the current daemon view's host (or the
local daemon outside a host view), so a stale host daemon can be restarted
after resumable sessions become idle.

### Editor calls and paths

A remote agent's MCP client runs `node <dir>/bin/emx mcp` on the host,
which talks to the host's daemon. Editor tools are forwarded over the
client connection to Emacs: no relay, no per-session local emx. Paths stay
in the host's terms on the wire; Emacs maps them to `/rpc:host:` names
(`agent-session-expand-file-name`, as today). Before asynchronous opening,
Emacs expands remote roots (including `~`) once on the host and retains the
`/rpc:` prefix for editor mapping. Pasted image attachments are uploaded with
`agent-remote-upload` before send or steer; the wire contains host paths.

The `config_*` tools read and write this machine's Emacs configuration,
which the host can't reach. The host daemon forwards them to Emacs like an
editor call, and Emacs passes them to the local daemon, which does the
file I/O (it never blocks Emacs, which is why they live in emx today).
`config/call {method, arguments}` is local-editor-only. The port retains
checkout/symlink/`.git` guards, numbered reads, exact replacement checks,
unsaved-buffer refusal and visiting-buffer refresh. Only the private
`_config_modified`/`_config_written` editor requests touch buffers. Tools
and their private read-only classification are cached on the host, so
`config_read` is available to each backend without a permission prompt.

### Project environments

Bootstrap runs in the host home directory, outside the first project's direnv.
The daemon keeps that base environment and computes each session's overlay by
running `direnv export json` in its root. Direnv enforces `.envrc` authorization;
an unavailable or blocked direnv leaves the base environment unchanged. The
overlay uses the same essential variables as tramp-rpc (including PATH, compiler,
Rust, Python and Node paths), so its program lookup and daemon spawn agree.
Each CLI and the `emx mcp` it launches inherit this project environment. Results
are cached per root for up to five minutes and invalidated by parent `.envrc`
and `.direnv` changes; filesystem inspection and direnv run asynchronously in
Node, never on an Emacs timer.

### Configuration, usage and collaboration across hosts

- **Configuration:** the local config file is the source. Emacs sends the
  effective config in `hello.config` and again with `config/push` on change
  or local reconnection. It preserves JSON empty objects, false and null.
  The host persists the pushed base in `emx/client-config.json`, so it
  survives editor/daemon restarts. `~/.config/emx/config.json` may override
  only `agents.<name>.executable`; all other overrides are rejected with
  last-good config retained. Host config notifications never overwrite
  Emacs's local policy cache. Host quota commands use those executables
  and the installed dsh plugin, rather than local-machine command paths.
- **Usage:** the ledger stays local. Each host outbox and Emacs editor outbox
  persists a stable producer `source`, a monotonically increasing `sequence`,
  and pending entries before delivery. Entries retain their old UUID `id` for
  migration, plus `method` and `params`. Hello and a 5-second attached retry
  replay pending host entries in sequence order. Emacs adds host/root context
  and relays the same source and sequence to `usage/record` or `usage/quota`.
  The ledger owner returns its applied sequence watermark; only then does
  Emacs send `usage/ack {source, sequence}`. Anything at or below that source's
  watermark is a duplicate, independent of backlog size or receipt-cache age.
  Records persist delivery identity with the counters in the same append;
  quota snapshots retain each producer's watermark atomically. Startup rebuilds
  watermarks from those operations if a crash preceded the separate watermark
  index or acknowledgment. Producer state retains its sequence even when its
  outbox becomes empty. Editor outboxes use `emx/editor-usage-<server hash>.el`;
  host outboxes use `emx/usage-outbox.json`. Existing host array outboxes receive
  source/sequences once before replay. Migration scans all legacy ledger ids,
  including receipts older than the former 10,000-entry cache, without charging
  them again. Legacy id-only peers remain supported during upgrade.
  Remote quotas preserve their sampling times and never replace the combined
  local snapshot; a stale producer sequence cannot overwrite a newer reading.
- **Collaboration limitation:** children, `session_start`, `session_stop`
  and mailbox delivery remain in the parent's daemon. `sessions` lists
  only that daemon; `session_read` and `session_ask` resolve only its
  handles. Cross-daemon list/read/ask is deferred, like the phase-5 mixed
  Lisp/daemon bridge: asynchronous confirmations and reply ownership need
  a shared routing contract. An unknown target explicitly reports that
  cross-daemon collaboration is unsupported. Use sessions in the same
  daemon for collaborating tasks; no cross-host calls are silently routed.

### Security

Same model as today: owner-only sockets and directories on both ends, no
other authentication; anyone who can act as the user on the host can drive
its agents, as they can drive the agents themselves today.

### What goes away

Removal moves to phase 8: `agent-keeper.py`, `agent-remote-relay.py` and
their tests, the `-R` bridge and per-session local emx, and keeper byte-offset
reattach still serve non-opted-in Lisp backends. `agent-emx-remote.el`
installs/starts the host daemon, owns the `-L` transport, maps paths and
relays config/usage for opted-in sessions. Both paths coexist deliberately.

## Code layout

```
bin/emx                  entry: CLI, `emx mcp`, `emx daemon`, `emx connect`
emx/config.json          tracked configuration
emx/daemon/              socket server, sessions, events, editor calls
emx/backends/            claude.ts, codex.ts, dsh.ts
emx/collab/              children, mailbox, session_* tools
emx/usage/               ledger, quota polls, forecasts and turn accounting
emx/remote/              durable host usage outbox
lisp/agent/backend/dsh/  the dsh plugin, unchanged in place
test/emx/                node --test suites, with fake CLIs
emx/package.json         @types/node for tsc -p emx
```

## Migration

Each phase keeps every existing session type working and ends with green
ERT, `node --test` and a clean compile. Lisp backends are removed only at
the end.

1. **Skeleton.** `emx daemon` with socket, `hello`, sessions table, event
   log, attach and replay; a fake backend that echoes. In Lisp a generic
   `emx` backend renders the events into today's session buffer. ERT runs
   against a daemon started on a temp socket, node tests against fake
   clients.
2. **dsh** through the daemon, behind `agent-emx-agents` (default nil),
   old path still available. Implemented for local roots; real-daemon tests
   use a fake dsh peer without contacting the API.
3. **Editor calls and `emx mcp` over the daemon** (implemented); stamp
   files remain for the legacy path until its cut-over.
4. **Claude**, then **Codex**.
5. **Collab**: profiles from config, `session_*` tools, mailbox,
   children's lifecycle and limits, the approval policy above.
6. **Usage** (implemented): the daemon owns the ledger, quota polls and
   accounting; Lisp backends send records to the same writer.
7. **Remote**: install and `--ensure`, the `-L` forward, disconnect and
   reattach by `seq`, `config_*` through the local daemon, usage outbox,
   same-daemon collaboration (cross-daemon list/read/ask deferred as above).
   Keep the keeper and relay for non-opted-in agents until phase 8.
8. **Cut over**: remove the Lisp backends and what only they used; shrink
   `agent-session` (a `restart_required` struct change, done once).

## Phase 6: daemon-owned usage

`emx/usage/service.ts` ports the former `bin/emx-usage.js` algorithms;
`types.ts` describes its files and `accounting.ts` consumes original
backend events. The daemon initializes it only after acquiring its var-dir
lock. Ledger and quota paths are always `<var>/agent-usage.jsonl` and
`<var>/agent-quota.json`; socket clients cannot redirect them. The JSONL
records, quota histories, calendar bucketing, forecasts, stale-source
skipping, failure backoff and CLI commands are unchanged. `emx serve` and
its JavaScript module are removed because no callers remain.

Each daemon session sends its live accounting events to Accounting before
any editor event is logged. Calls sum by model until usage/end; the first
nonempty model counts the turn. Exit flushes a partial turn exactly once.
ClaudeTotals keeps its existing proof of the first resumed baseline,
falls back to the turn's own counters when ambiguous, and forgets the
baseline after external-client writes. Adapter history filtering stays in
place. Attach, catch-up, earlier history and reconnect cannot charge usage.
Accounting continues while Emacs is disconnected. Handles are supplied on
open and before sends so ledger session names retain the editor's handle;
root abbreviation and child markers match the Lisp records.

`agent-usage.el` retains accounting for Lisp backends, but sends their
records and quota readings over agent-emx's shared local connection. It
uses the same asynchronous ensure/hello path even when no daemon backend
is selected. On hello Emacs supplies agent display order, the polling
interval and the existing registered poller commands. The daemon stores
those in `<var>/emx/usage.json`, retaining polls after editor disconnect or
daemon restart. `agent-emx-var-directory` selects this single writer;
legacy usage file variables describe its standard paths. The old `.eld`
migration remains a one-time pre-start conversion. Batch Emacs only uses
an explicitly started isolated daemon.

Global `usage/quotas` snapshots decode to the same Lisp lists the echo
line and page already draw. `usage/changed` schedules the page's existing
idle refetch. Report filters, cache toggle, refresh behavior, clear's
confirmation, and visible wording are unchanged. The old
`agent-usage-restart-service` command now reconnects and reapplies poll
settings, without stopping live sessions; code updates use the daemon's
lifecycle rather than a separate usage subprocess.

Verification uses the unchanged `test/fixtures/usage/` data in
`test/emx/usage.test.ts`, plus socket/accounting/restart tests in
`usage-daemon.test.ts`. Fake quota peers cover all three CLI poll protocols
without credentials or model calls. ERT still renders the same page and
echo line from those fixtures over an isolated daemon socket.

Phase 6 verification (2026-10-20): `tsc -p emx` passes; `node --test
test/emx/ test/emx-mcp-test.js` passes all 118 tests. The full AGENTS ERT
suite passes 254 tests with one environment-dependent scroll test skipped
(255 total, no unexpected results), using the live checkout's package
directory but only worktree source and temporary daemon state. Evil-on and
evil-off byte compilation each report only the two existing `lang-agda.el`
slot warnings. Bridge and dsh plugin syntax checks pass. No real model or
quota calls, live Emacs server, default daemon or reload was used.

## Open questions

1. Config format: JSON as proposed, or something with comments?
2. Default durations: `daemon.idleExit` 15 minutes, `sessions.hibernateAfter`
   2 hours.

### Usage delivery recovery (phase 6 review)

`usage/hello` and editor `hello` advertise `capabilities.usage = 1` for the
acknowledged protocol. Lisp usage uses a dedicated connection and never sends
records to a daemon without that capability. Each record stays in an Emacs
in-memory outbox under a stable id until `usage/record` replies with that id.
Quota readings use `usage/quota` with an id and retain the latest per agent/host.
Failed ensure, socket loss and uncertain replies retain entries for retry.
Phase 7 review replaces the original bounded receipt caches with durable
producer sequence watermarks (see Remote projects above). Legacy receipt ids
remain in ledger appends for migration, and legacy notifications remain
supported for attached older editors.

While usage monitoring is active, failures schedule asynchronous ensure/connect
with 2–60 second exponential backoff. A successful usage handshake resets the
backoff, reapplies poll settings and flushes retained entries. Disabling the echo
monitor cancels its pending reconnect timer. The outbox survives daemon restarts
and producing Emacs restarts through the persisted editor outbox.

## Phase 7 verification

`test/emx/remote.test.ts` installs only the runtime into a temporary HOME,
checks the hash, plugin inclusion and stale/live versus idle replacement,
starts a second daemon through `--ensure --client`, holds a fake Codex
turn through editor disconnect, and replays only events after its cursor.
It exercises editor calls, remote -> editor -> local-daemon config tools,
config push/host overrides, durable usage and duplicate receipts. No SSH,
real account or model is used.

`test/agent-emx-remote-test.el` uses a local file handler and remote-process
stub to execute the actual ensure shell command in that temporary HOME;
the forwarding stub returns the host socket directly. Other tests stub
ControlMaster/ssh and verify private directories, forward reuse/replacement,
Node in the single program lookup, timer guards, path mapping, JSON types,
missing-install retry and local-before-remote acknowledgement order.
The legacy keeper and relay tests continue to cover the unswitched path.

### Proposed real-host check (requires separate approval)

Use a disposable host account/project and a dedicated Emacs server/config
var directory; do not attach the user's usual Emacs or its daemon, or
change executable overrides for an account running production daemons.
For example, after writing a fake-only config to `/tmp/emx-phase7-var/emx/config.json`:

```sh
emacs -Q --daemon=emx-phase7-check \
  --eval '(setq user-emacs-directory "/ABS/WORKTREE/" package-user-dir "/ABS/ELPA/" agent-emx-var-directory "/tmp/emx-phase7-var/" my/use-evil nil)' \
  -l /ABS/WORKTREE/init.el
emacsclient -s emx-phase7-check -c
```

First choose the disposable host,
project, installed Node path and a test client id with the user. Install
only this runtime through `agent-emx-remote--install` in that isolated
Emacs. Copy a fake CLI separately to the disposable host test directory
(the production runtime installer intentionally excludes fixtures). Push
a test config with all executables pointing to fake CLIs, polling disabled,
`collab.handleCommand: []`, and `collab.agentHandleCommands: {}`. This
checks actual tramp-rpc/sshd without model calls.

1. In isolated Emacs open `/rpc:HOST:/TEST/PROJECT/`, call
   `agent-session-check-programs`, and inspect the cached `:node` value.
   It must be >= 22.18 and lookup must issue only one `process-file`.
2. Through that file handler install the runtime, then run on the host:
   `node ~/.cache/emacs-agent/emx/VERSION/bin/emx daemon --client ID --ensure`.
   Check the JSON version/socket, a second ensure's identical pid, and
   `stat` of `~/.cache/emacs-agent/emx/run` and `state/ID` (0700).
3. From the local machine, using the test tramp-rpc ControlMaster:
   `mkdir -m 700 /tmp/emx-realhost-ID` and
   `ssh -S CONTROL -O forward -L /tmp/emx-realhost-ID/emx.sock:REMOTE_SOCKET HOST`.
   Connect the isolated client to that socket. A fake echo/Codex session
   should attach, render, answer an approval and map `/TEST/PROJECT/a.el`
   to `/rpc:HOST:/TEST/PROJECT/a.el` for an editor `open` call.
4. Hold a fake turn, record its epoch/seq, then close only this test master
   (`ssh -S CONTROL -O exit HOST`). The view must become disconnected;
   the host daemon/fake CLI must remain alive. Wait past the reconnect
   timer: it must not establish SSH. Reopen the test tramp-rpc connection;
   a new master/forward must reattach with the cursor and no duplicate
   blocks or pending approvals. With the host connection still open, stop only
   the test daemon: another timer tick must use only local SSH forwarding and
   leave sessions disconnected, with no host ensure or file copy. A manual
   reconnect should then ensure and reattach again.
5. Write/read/edit a disposable `var/phase7-realhost.el` using remote
   `config_*`, confirm that only the isolated local checkout changes,
   and test refusal while its visiting buffer is modified. Change the
   isolated local config, confirm the host receives it, and confirm an
   executable-only host override survives the push.
6. Finish a fake turn while detached and inspect the host outbox. Reattach,
   verify one combined local ledger record and a cleared remote outbox;
   interrupt again between local receipt and remote ack and verify retry
   still leaves one record. Check host-labelled quota readings too.
7. Open two allowed direnv projects with different fake CLI PATHs, including
   `/rpc:HOST:~/PROJECT/` for one. Check both lookup and actual CLI/MCP
   environments, then edit `.envrc`/`.direnv` and launch again. Paste an image
   and check send/steer receives a readable host path. Race two installers and
   interrupt one copy; only a fully verified version may appear at the target.
   Repeat a backlog over 10,000 records across an apply-before-ack restart,
   checking source watermarks and unchanged combined counts. Try a long HOME
   and verify the shortened socket directory's ownership and mode.
8. Stop only the test daemon with
   `node ~/.cache/emacs-agent/emx/VERSION/bin/emx daemon --client ID --stop`,
   cancel the test forward using `ssh -S CONTROL -O cancel -L LOCAL:REMOTE HOST`,
   and remove the disposable directories/config-file fixture.

The open real-host risks are tramp-rpc's process environment/detachment,
sshd stream-local forwarding policy, socket-path limits on that host,
and ControlMaster close/reopen behavior. The `emx connect` pipe fallback
remains deferred until a host actually requires it.

### Verification output (2026-10-20)

All commands ran from this worktree. Socket/process tests used only temp
var/HOME directories, fake CLIs and local host simulation. No live reload,
default Emacs server/daemon, real SSH host or real model was used.

```text
tsc -p emx                                      exit 0
node --test test/emx/ test/emx-mcp-test.js        155 passed, 0 failed
full ERT (AGENTS.md, shared package-user-dir)    277 tests; 276 passed, 0 unexpected, 1 skipped
  skipped: init-base-scroll-with-point
byte compile, my/use-evil=nil and t              exit 0 in each mode
  only known lang-agda.el:114 adjust-face / :116 protect-font-lock warnings
python3 test/agent-keeper-test.py                all passed
python3 test/agent-remote-relay-test.py           all passed
node --check bin/emx                            exit 0
git diff --check                                clean
```

### Phase 7 review fixes verification (2026-10-20)

Final verification used this worktree, fake CLIs and temporary daemon state;
no remote host, default Emacs server, reload or model call was used for these
fixes. A preliminary keeper test used its default cache and reported complete
cleanup; the final keeper/relay runs both used a temporary HOME.

- `tsc -p emx`, `node --check bin/emx`, and the dsh bridge syntax check passed.
- `node --test test/emx/ test/emx-mcp-test.js`: 159 passed, 0 failed.
- Full AGENTS ERT with the shared package directory and remote tests:
  290 total, 289 passed, 0 unexpected, 1 skipped (`init-base-scroll-with-point`).
- Byte compilation with evil on and off: only the two known `lang-agda.el`
  unknown-slot warnings (`adjust-face`, `protect-font-lock`) in each run.
- Keeper and relay Python suites: all passed with a temporary HOME.

Regression runs against the preceding implementations reproduced the timer,
copy verification/publication, image/root, per-project PATH and large-outbox
failures. In particular, the old usage cache replay wrote 20,002 records from
10,001 deliveries; sequence watermarks preserve 10,001 across both restarts.
The existing Node-warning ensure parser fix remains intact. The proposed
real-host check above is still needed for actual tramp direnv behavior, atomic
file-handler renames, stream-local forwarding and ControlMaster replacement.
