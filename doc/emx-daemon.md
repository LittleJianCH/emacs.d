# emx daemon: agents outside Emacs

Status: design, not implemented. Branch `claude/emx-daemon`.

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
  (`package.json` at the root, `node_modules/` ignored). `bin/emx`,
  `bin/emx-usage.js` and the dsh plugin stay JavaScript until they move;
  the plugin runs inside dsh and stays JavaScript.
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
  agent is idle, hibernating them first.
- **One Emacs.** A daemon serves a single Emacs, as one Emacs server
  serves all its frames and emacsclients. A second Emacs saying `hello`
  takes over and the first is told it was replaced. Agents' `emx mcp`
  processes also connect to the socket, any number of them, but only to
  run tools.
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
| `config/reload` | `{}` | `{config, errors}` |
| `usage/report`, `usage/refresh`, `usage/clear` | as `emx serve` today | |

### Daemon → client (notifications, per attached session)

Every event carries `{session, seq}`; `seq` increases by one per session.

- `status {status}`, `info {info}` (changed keys), `settings {settings}`
- `block/add {block, after?}` (`after` places it, e.g. earlier history)
- `block/append {id, text}` (streamed text), `block/done {id}`
- `block/update {id, ...fields}` (tool result, output, error)
- `block/remove {ids}` (an abandoned attempt)
- `ask/add {ask}`, `ask/remove {id, resolution}` (see Approvals)
- `notice {kind, ...fields}`
- `queue {items}`, `children {ids}`
- `usage/quotas {quotas}` (not per session)

### Attach and catching up

`session/attach` returns a snapshot (blocks in order, pending asks,
queue, status, info, settings, `seq`), then streams events after it.
Passing `after: seq` instead replays only the events after that sequence
number from a per-session ring buffer, falling back to a snapshot when they
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

Today `emx mcp` turns each tool call into an `emacsclient` request through
temp files, and `EMX_TOOLS_STAMP` files tell it when tools change. In the
new design `emx mcp` connects to the daemon and forwards `tools/list` and
`tools/call`:

- **Daemon tools** run in the daemon: `sessions`, `session_read`,
  `session_ask`, `session_start`, `session_stop`, the remote `config_*`
  tools, and later usage and review data.
- **Editor tools** stay defined in Lisp with `agent-ui-defmethod`. On
  `hello` the editor sends their schemas (`tools`); the daemon keeps the
  last list on disk, so `tools/list` is stable while no Emacs is attached
  (calls fail cleanly instead). A changed list is pushed as
  `notifications/tools/list_changed` by the daemon itself: the stamp files
  and the file watch go away.
- The **fork-cache rule** stays: tools, their descriptions and any
  allowlist depend on configuration and place only, never on the calling
  session.
- The `emacsclient` path remains for bare command-line use (`emx open
  file 42` from a terminal).

## Backends

Each backend is a daemon module with the interface of today's generics:
`start`, `send`, `steer`, `interrupt`, `configure`, `stop`, `history`,
`fork`, `models`, `modes`, `commands`, `reattached`. It turns its CLI's
stream into the session events above.

- **dsh** first: the bridge plugin (`emacs-bridge.mjs`) already speaks a
  backend-neutral JSON-RPC vocabulary (`text`, `tool`, `tool/done`,
  `turn/end`, `usage`, `approval`, `question`), so the adapter is thin. The
  plugin keeps running inside dsh; its peer becomes the daemon.
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

## Localization

Conventions stay: agent-facing text in English, UI text in Chinese. The
daemon never writes UI prose. Notices and labels are structured
(`{kind: "effort-after-turn"}`, `{kind: "restart-for-external"}`, tool view
`kind: "plan"`); Lisp maps kinds to Chinese strings. Errors the daemon
returns to agents stay English.

## Configuration

One tracked file, `emx/config.json`, with a git-ignored override at
`var/emx/config.json` merged over it (user changes stay out of tracked
paths). Contents:

- `agents`: per agent, `enabled`, `executable`, extra arguments, disallowed
  tools, history turns.
- `profiles`: today's `agent-collab-profiles` (agent, model, effort, mode,
  cost, description, confirm).
- `collab`: start guidance, `maxActive`, handoff limit, close finished
  children, confirm `session_ask`.
- `usage`: poll interval.
- `approvals`: the policy below.

The daemon watches the file and applies changes like a reload does today
(a changed profile or guidance changes the tools' descriptions, which pushes
`list_changed`); `config/reload` does it on demand and reports errors.
Display preferences (keys, faces, evil, layout) stay in Lisp.

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

Today a remote agent runs on the host under `agent-keeper.py`, emx stays
local, and the agent's MCP client reaches it through
`agent-remote-relay.py`, a socket on the host and an `ssh -R` forward over
the tramp-rpc ControlMaster to a per-session local emx. With a daemon on
the host all three go.

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
coexist (as the dsh plugin is copied today). The host needs Node 22.18 or
later, checked in the same single round trip that looks up the agent
programs when a remote session opens (`agent-session-check-programs`);
python3 is no longer needed. The agents' credentials stay the host's own,
as today.

### One daemon per host and client checkout

The host runs one daemon per user and per client checkout:
`~/.cache/emacs-agent/emx/run/<client id>.sock`, in a directory of mode
0700, the client id being a hash of the checkout's path and the machine's
name. So this branch's worktree and the user's main checkout get separate
daemons on the same host, and two machines never share one. Its state
(session table, usage outbox) lives next to it in
`~/.cache/emacs-agent/emx/state/<client id>/`.

### Connecting

1. Emacs runs one command on the host through tramp-rpc:
   `node <dir>/bin/emx daemon --client <id> --ensure`. It copies nothing;
   it starts the daemon detached (`setsid`) unless one answers on the
   socket, and prints the socket path and the running daemon's code hash.
   If the code dir is missing it says so, Emacs copies it and runs the
   command again.
2. Emacs forwards a private local socket to the remote one over the
   ControlMaster: `ssh -S <control> -O forward -L <local>:<remote> host`,
   as `agent-remote-bridge` does today with `-R`. The local end lives in a
   temporary directory of mode 0700.
3. Emacs connects to the local end and speaks exactly the local protocol:
   `hello`, `session/attach`, events, editor calls. Nothing in the
   protocol knows it crosses a host.

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

### Editor calls and paths

A remote agent's MCP client runs `node <dir>/bin/emx mcp` on the host,
which talks to the host's daemon. Editor tools are forwarded over the
client connection to Emacs: no relay, no per-session local emx. Paths stay
in the host's terms on the wire; Emacs maps them to `/rpc:host:` names
(`agent-session-expand-file-name`, as today).

The `config_*` tools read and write this machine's Emacs configuration,
which the host can't reach. The host daemon forwards them to Emacs like an
editor call, and Emacs passes them to the local daemon, which does the
file I/O (it never blocks Emacs, which is why they live in emx today).

### Configuration, usage and collaboration across hosts

- **Configuration:** the local config file is the source. Emacs sends the
  effective config in `hello` to each remote daemon and again when it
  changes. The host may override its agents' executables in
  `~/.config/emx/config.json`, since programs differ per host.
- **Usage:** the ledger stays local. A remote daemon emits its records as
  events and keeps them in an outbox on disk until a client acknowledges
  them (`usage/ack {seq}`); Emacs hands them to the local daemon. A host's
  quota polls run on the host, for the accounts logged in there, and arrive
  the same way.
- **Collaboration:** children start in their parent's daemon, so
  `session_start`, `session_stop` and a child's reply never leave the host.
  `sessions`, `session_read` and `session_ask` naming a session on another
  daemon go through Emacs, which knows them all: they work while Emacs is
  attached and fail clearly otherwise.

### Security

Same model as today: owner-only sockets and directories on both ends, no
other authentication; anyone who can act as the user on the host can drive
its agents, as they can drive the agents themselves today.

### What goes away

`agent-keeper.py`, `agent-remote-relay.py` and their tests, the `-R`
bridge and per-session local emx in `agent-remote.el`, and the reattach
logic built on byte offsets in `agent-session.el`. `agent-remote.el`
keeps installing and starting the host daemon, the forward, and path
mapping.

## Code layout

```
bin/emx                  entry: CLI, `emx mcp`, `emx daemon`, `emx connect`
emx/config.json          tracked configuration
emx/daemon/              socket server, sessions, events, editor calls
emx/backends/            claude.ts, codex.ts, dsh.ts
emx/collab/              children, mailbox, session_* tools
emx/usage/               today's bin/emx-usage.js
emx/remote/              --ensure, usage outbox
lisp/agent/backend/dsh/  the dsh plugin, unchanged in place
test/emx/                node --test suites, with fake CLIs
package.json             @types/node for tsc --noEmit
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
2. **dsh** through the daemon, behind a switch (`my/agents` entry or a
   per-agent option), old path still available.
3. **Editor calls and `emx mcp` over the daemon**; stamp files removed.
4. **Claude**, then **Codex**.
5. **Collab**: profiles from config, `session_*` tools, mailbox,
   children's lifecycle and limits, the approval policy above.
6. **Usage**: `emx serve` becomes a daemon module.
7. **Remote**: install and `--ensure`, the `-L` forward, disconnect and
   reattach by `seq`, `config_*` through the local daemon, usage outbox,
   cross-daemon `session_*` through Emacs. Then remove the keeper and the
   relay.
8. **Cut over**: remove the Lisp backends and what only they used; shrink
   `agent-session` (a `restart_required` struct change, done once).

## Open questions

1. Config format: JSON as proposed, or something with comments?
2. Default durations: `daemon.idleExit` 15 minutes, `sessions.hibernateAfter`
   2 hours.
