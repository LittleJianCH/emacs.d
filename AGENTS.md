# AGENTS.md

Guide for coding agents working on this Emacs configuration. This checkout is the
configuration the user's Emacs loads, so the files you edit are the ones it runs.

## What this is

A modular Emacs config built for developing *with* agents:

- Agent CLIs (Claude Code, Codex, DeepSeek Harness) run headless behind structured protocols; Emacs renders
  the whole conversation UI itself (T3 Code / telega style). We never embed an agent's
  own TUI.
- Agents can drive Emacs back through `bin/emx` (CLI + stdio MCP server): open files,
  read buffers, run Elisp, and render native pages (`agent-canvas`). Everything is shown
  inside Emacs — no external browser.
- Day-to-day languages are Rust and Emacs Lisp.

Requires Emacs 30.1+ (the user runs Emacs 31, emacs-plus on macOS).

## Layout

```
early-init.el            GC / frame settings before the first frame
init.el                  package setup, then loads modules in order
lisp/core/               base layer
  init-base.el           defaults, var/ paths, `my/use-evil' + `my/toggle-evil'
  init-reload.el         `my/reload-config': apply edited files to the running Emacs
  init-ui.el             fonts, layout (nano margins), status line, side panels
  init-theme.el          nano-style light / dark themes following the macOS appearance
  init-evil.el           Vim bindings (on by default, `my/use-evil')
  init-completion.el     vertico / orderless / consult / corfu / cape
  init-dev.el            project, magit, eglot, tree-sitter
  init-remote.el         remote editing (tramp-rpc)
  init-term.el           terminals (ghostel, native module downloaded prebuilt)
lisp/lang/lang-NAME.el   one file per language; enabled via `my/languages' in init.el
lisp/agent/              shared agent support (see below)
  agent-emx.el          daemon client and editor tools; agent-emx-agents opts agents in
  agent-emx-remote.el   host runtime install, -L transport, config and usage relay
  backend/              individual backends, enabled via `my/agents' in init.el
    agent-NAME.el       backend implementation and registration
    dsh/                DeepSeek Harness bridge plugin and profile patches
lisp/app/                standalone applications
  init-telega.el         Telegram client (telega; needs a source-built TDLib)
bin/emx                  Node bridge: CLI, MCP server and daemon entry
emx/                     the emx daemon (TypeScript compiled on demand to generated dist/): protocol, sessions, backends
  backends/dsh.ts         local dsh bridge peer, enabled by agent-emx-agents
  usage/                 ledger, quotas, forecasts, polls and live turn accounting
  mcp.ts                 daemon-only stdio MCP client (EMX_DAEMON_SOCKET opt-in)
skills/NAME/SKILL.md     skills given to the agents Emacs starts (`agent-session-add-skill')
doc/subagents.md         design of subagents and agent collaboration, with measurements
doc/emx-daemon.md        design of moving agents into an emx daemon (in progress)
test/agent-backend-test.el  ERT suite for backend module startup and selection
test/agent-session-test.el  ERT suite for the agent UI (uses a fake echo backend)
test/agent-session-table-test.el  ERT suite for Markdown tables in transcripts
test/agent-session-link-test.el   ERT suite for clickable links in transcripts
test/init-reload-test.el    ERT suite for reloading
test/init-base-test.el      ERT suite for base defaults
test/init-remote-test.el    ERT suite for remote editing
test/init-ui-test.el        ERT suite for the themes, status line and side panels
test/init-term-test.el      ERT suite for the terminal module
test/agent-review-test.el   ERT suite for atomic reviews (builds throwaway Git repos)
test/agent-canvas-test.el   ERT suite for agent pages (elisp blocks, state, timers)
test/agent-usage-test.el    ERT suite for usage events, the echo line and the usage page
test/agent-emx-test.el      ERT suite for the emx backend (starts a daemon on a temp var dir)
test/agent-emx-remote-test.el ERT host simulation with stubbed tramp/SSH
test/emx/usage*.test.ts     usage arithmetic, daemon accounting and fake quota polls
                           (unchanged fixtures in test/fixtures/usage/)
test/emx/                   node --test suites for the emx daemon
var/                     runtime state (history, backups, pasted images...); git-ignored
```

### Agent layer (`lisp/agent/`)

- `agent-session.el` — the core. A `cl-defstruct agent-session` plus backend generics
  (`agent-session-backend-start/send/steer/interrupt/handle/stop/models/modes/commands/
  apply-settings/history`). Owns the session buffer: transcript | footer (separator,
  approval and queued-message lines, prompt) | input area, all in one buffer. Blocks
  (user / text / tool / notice) are stored in a hash table and re-rendered in place.
  Also: turn folding, steering, queueing, completion, image attachments, mode-line,
  transient menu `agent-session-menu`, global prefix map on `C-c a`.
- `agent-session-table.el` — renders complete Markdown tables in replies after
  fontification, keeping cell faces and lining up CJK text.
- `backend/agent-claude.el` — Claude Code backend: `claude -p --input-format stream-json
  --output-format stream-json --permission-prompt-tool stdio ...`. Permissions arrive
  as `control_request`/`can_use_tool`; model and permission mode switch live via control
  requests; effort needs a restart with `--resume`. History reads
  `~/.claude/projects/<encoded-root>/<session-id>.jsonl`. Replay never reads that file
  in Emacs (it reaches tens of MB): a python3 script (`agent-claude--history-script`)
  runs in the background where the file lives, on the host for a remote project, and
  prints only the last `agent-claude-history-turns` turns with the fields shown; a
  line above them loads earlier turns, inserted with `agent-session-call-before-block`.
  The same file is watched to show messages written by other clients (Claude Desktop,
  terminal); for a remote project a python3 script on the host follows it instead
  (`agent-claude--follow-script`) and passes on only those messages, so neither the
  watch nor the CLI's own writes cost round trips. The CLI is restarted with
  `--resume` before the next send so its context catches up.
  Sessions opt into `emx/backends/claude.ts` when `agent-emx-agents`
  contains `claude`; Lisp stays the default. The daemon's transitional
  `EMX_CLAUDE_CONFIG` JSON sets executable, extraArgs, disallowedTools
  (same defaults as Lisp) and historyTurns (20). Tests override the executable
  and project transcript directory with fake stream-json fixtures. Node streams
  history pages and follows external clients with a 500 ms directory-watch
  debounce; a resume after external writes forgets usage totals. Remote roots
  use a host daemon; native forks use collaboration, and historical discovery
  stays in Lisp.
- `backend/agent-codex.el` — Codex backend over `codex app-server` (JSON-RPC: `thread/start`,
  `turn/start`, `turn/steer`, approvals via `item/*/requestApproval`). The emx MCP server
  is injected per process with `-c mcp_servers.emacs.*`.
  Sessions opt into `emx/backends/codex.ts` when `agent-emx-agents`
  contains `codex`; Lisp stays the default. The daemon's transitional
  `EMX_CODEX_CONFIG` JSON sets executable, extraArgs and nativeSubagents
  (default false). Tests use `EMX_CODEX_EXECUTABLE` and a fake app-server.
  Changed editor tools restart saved threads before their next send;
  ephemeral children retain their process. Usage excludes replayed history.
  Remote roots use a host daemon; native forks use collaboration, and external
  discovery stays in Lisp.
- `backend/agent-dsh.el` — DeepSeek Harness (`dsh`) backend. The default remains
  Lisp; `agent-emx-agents` containing `dsh` registers new sessions with `:backend emx
  :emx-agent "dsh"` (set before startup or via `customize-set-variable`). Removing
  it restores Lisp; existing sessions keep their backend. The daemon path is local
  or /rpc:, and always disables native subagents. Remote sessions use a host
  daemon through agent-emx-remote.el. It uses
  `emx/backends/dsh.ts` with the same plugin; Lisp renders notices and the daemon
  records usage directly. dsh's own SDK/ACP protocols are too
  thin (SDK cannot cancel or approve), so we ship a dsh plugin, `backend/dsh/emacs-bridge.mjs`,
  mounted into the stock `sdk` profile by `backend/dsh/emacs.yml` (`dsh --profile sdk --patch
  ...`). It drives one dsh agent through dsh's internal API (`ctx.agents`,
  `agent/assistant-stream`, `session/event`, `approval/request`) and speaks our own
  line-delimited JSON-RPC, documented at the top of the plugin. Modes map to dsh
  permission presets (`auto` is dsh's experimental auto-review plugin, also mounted by
  `emacs.yml`); plan mode is dsh's own, and its `exit_plan_mode` review arrives as a
  `question`. History and replay go through the bridge too (`sessions/list`, resume
  returns the transcript); dsh's session logs are zstd-compressed, don't parse them in
  Elisp. emx is mounted per agent with dsh's MCP client. dsh asks about an MCP
  call only when a hook does, so the bridge asks about every emx call except the
  read-only methods (`:read-only` in `agent-ui-defmethod`), unless the preset is
  Full access, or Auto, whose reviewer judges each call first. For a remote
  project dsh runs on the host like the other backends: the plugin files are copied to
  `~/.cache/emacs-agent/dsh/<content hash>/` there, emx goes through the relay of
  `agent-remote.el`, and the host needs dsh, python3 and its own dsh credentials. The
  bridge reports dsh's version and the session notes one other than
  `agent-dsh-tested-version`. It depends on dsh internals,
  so expect to adjust it when dsh is upgraded. The API key lives in dsh's
  `~/.dsh/.credentials.yaml`; never pass it through the environment.
- `agent-emx-remote.el` — opted-in remote agents run under a content-addressed
  host daemon, connected over a private `ssh -L` ControlMaster forward. Node
  18.17+ (or 20.3+) is checked with the existing program lookup. Timers only recreate
  local forwards to remembered sockets on connected hosts; ensure, staged
  runtime verification, root expansion, skills and image uploads need user action.
  Each host session gets its root's direnv environment, matching tramp-rpc; editor calls map host paths, config tools use the
  local daemon, and durable usage entries use persisted producer sequence
  watermarks acknowledged after local storage.
  Host config can override executables only. Cross-daemon collaboration remains
  unsupported; children stay in their parent's daemon. See phase 7 in
  `doc/emx-daemon.md`. The following legacy path stays for other backends.
- `agent-remote.el` — remote projects (`/rpc:` roots). The agent CLI runs on the
  project's host through tramp-rpc, so it uses the host's toolchain and history, like
  Claude Desktop's SSH mode. emx stays local: a per-host bridge forwards a Unix socket
  over the tramp-rpc ControlMaster (`ssh -O forward -R`, owner-only on the host), the
  agent's MCP command there is a python3 relay into it, and Emacs runs a local `emx mcp`
  per connection. Paths an agent reports are on the host
  (`agent-session-expand-file-name`). That emx runs with `EMX_REMOTE_AGENT=1`, which
  adds its own `config_read` / `config_edit` / `config_write` tools: the agent's file
  tools can't reach this machine. They are implemented in emx, not Emacs, so file I/O
  never blocks the editor, and are confined to this checkout outside `.git` (a guardrail
  against editing the wrong host, not a sandbox: `eval` is unrestricted). Writing a
  `.el` file tells the agent to call `reload` once its edits are done.
  A remote agent outlives the connection (`agent-session-keep-remote`): it runs under
  `agent-keeper.py`, a daemon on the host, behind a client that tramp-rpc starts.
  tramp-rpc's server SIGTERMs the processes it started when the connection closes,
  which only detaches the client; `delete-process` sends SIGKILL, which stops the
  agent. The client's output is framed with byte offsets, so a session that lost its
  client shows as `disconnected` and `agent-session-reattach` replays exactly what it
  missed (on a timer once the host is connected again, never opening a connection;
  or on the next send). The MCP relay (`agent-remote-relay.py`) stays up as well,
  failing requests while there is no bridge, and replays the MCP handshake to the new
  emx that a reattach brings back. Host-side tests: `python3 test/agent-keeper-test.py`
  and `python3 test/agent-remote-relay-test.py`.
- `agent-session-list.el` — the session sidebar (live sessions + history per project),
  keyboard and mouse.
- `agent-ui.el` — methods agents can call, defined with `agent-ui-defmethod`; emx's
  `tools/list` is generated from these, so a new method is automatically an MCP tool.
  A method that waits for something slow returns `agent-ui-defer` at once and emx polls
  it (`_poll`), so Emacs never blocks while an agent waits. When the methods change (a
  reload, a changed profile), a timer writes their signature to
  `var/emx-tools-<server-name>[-<project hash>]`, one per place (`EMX_TOOLS_STAMP`); each
  emx watches its agent's and sends
  `notifications/tools/list_changed`, which Claude and dsh act on. Codex ignores it, so
  a saved Codex thread whose tools changed is resumed in a new process before the next
  send; a Codex child keeps the tools it started with. Daemon connections get
  the same local definitions plus a private read-only list on hello and through
  `editor/tools`, checked by that timer. `agent-ui-call` is the shared dispatcher
  for emacsclient and `editor/call`; agent-emx maps daemon callers to live buffers.
- `agent-collab.el` — agents working with each other. Every session has a handle
  (`@cfi-meaning`) named from its topic by a cheap model of its agent
  (`agent-collab-agent-handle-commands`, else `agent-collab-handle-command`); users
  mention sessions with it. Methods `sessions`, `session_read` (latest turns, paged)
  and `session_ask` (sends a prompt to an idle session the user opened, confirmed by
  the user when `agent-collab-confirm` is set; the reply comes by mailbox).
  `session_start` starts a subagent: a child session of a profile in
  `agent-collab-profiles` (agent, model, effort, mode, cost; profiles of agents whose
  program isn't installed here, per `agent-session-define-agent`'s `:executable`, are
  left out, judged where the caller runs: here, or its remote project), named by the
  caller after its task (`handle`, else the profile), linked to the caller
  (`:parent` in its info, listed under it), given the prompt alone (`fresh`), the
  caller's conversation as text too (`handoff`), or, for a session of the caller's
  own agent and settings, a copy of its conversation that shares its prompt cache
  (`fork`: `--fork-session`, ephemeral `thread/fork`, the dsh bridge's `forkFrom`).
  A child does one task and reports:
  it can't start sessions, takes no `session_ask` and sends none, its mode never
  exceeds the caller's, and `session_stop` closes it. Children live with their buffer
  and their parent (Claude `--no-session-persistence`, Codex ephemeral threads, dsh
  `parentSession`), and close once their reply is delivered
  (`agent-collab-close-finished`) unless on screen or failed. Neither call waits for the reply, which would hold up the asker's
  whole turn and the user's messages: it goes to the asker's mailbox, sent to its
  agent in one message once it is idle. A child's
confirmations and questions also wait in its parent's footer, and the parent's
`session_start` tool block shows the child's progress. The CLIs' own
  subagents are off (`agent-claude-disallowed-tools`, `agent-codex-native-subagents`,
  `agent-dsh-native-subagents` with `backend/dsh/no-subagents.yml`). An agent's tools
  and their descriptions may depend on the configuration and where the agent runs
  (`agent-session-place`: this machine, or a remote project, whose direnv may add
  agents), never otherwise on the calling session (see
  `agent-ui-description-functions`): a forked session runs where its parent does and
  has to see exactly its parent's tools to share its prompt cache. A remote project's
  programs are looked up in one round trip as a session opens there
  (`agent-session-check-programs`; a failed lookup isn't retried for 5 minutes),
  never on a timer. Design and measurements:
  `doc/subagents.md`.
  For local daemon sessions, `emx/daemon/collab.ts` owns those five tools,
  children, naming and the persisted mailbox. Emacs only adopts/attaches views,
  mirrors asks and links progress. `emx/config.json` plus the optional
  `var/emx/config.json` override owns agent launch policy, profiles and prompts;
  `agent-emx-config.el` receives the effective config asynchronously, with the
  defcustoms retained as offline defaults. The daemon watches both files and
  serves `config/get` / `config/reload`. Daemon tools currently target daemon
  sessions only; mixed Lisp/daemon collaboration is not symmetric. See phase 5
  of `doc/emx-daemon.md`. Tests: `test/emx/{config,collab,session}.test.ts`,
  `test/agent-emx-config-test.el`, `test/agent-emx-collab-test.el`.
- `agent-usage.el` — the tokens the agents started from this Emacs used, and what
  their accounts have left (no prices: the accounts are mostly coding-plan
  subscriptions). The emx daemon owns the bookkeeping, arithmetic and quota
  polls (`emx/usage/`), and is the only writer of `var/agent-usage.jsonl` and
  `var/agent-quota.json`. The file formats, sums, calendar buckets and forecasts
  are unchanged. `emx serve` and `bin/emx-usage.js` have been removed.
  `usage/report`, `usage/refresh`, `usage/clear` and `usage/configure` go over
  the daemon socket; `usage/quotas` pushes snapshots and `usage/changed` refreshes
  a visible page. `agent-emx--local-connection` shares ensure/connect with local
  sessions; startup is asynchronous interactively and batch calls never start a
  default daemon implicitly. The daemon owns paths under `agent-emx-var-directory`.
  Backends still register commands in `agent-usage-pollers` (Claude's `/usage`,
  Codex's `account/rateLimits/read`, dsh's `balance`); Emacs sends them and
  `agent-usage-poll-interval` on hello. The daemon saves this configuration under
  `var/emx/usage.json` and polls even without Emacs, skipping fresh sources and
  backing off failures. Opening the page forces every poll.
  Daemon backends account at the original event boundary: Claude's running
  `modelUsage` totals become deltas with the same baseline-proof rule (a resumed
  process may restore older totals); ambiguous totals use only the turn's own
  usage. Codex/dsh calls sum per model per turn, the first nonempty model counts
  the turn, and process exit flushes a partial turn. Accounting events never enter
  the editor event log or replay. Lisp backends keep `agent-usage-totals` and
  `agent-usage-add-call` / `agent-usage-end-turn`; `agent-usage-record` and
  `agent-usage-set-quota` send daemon notifications, sharing its single writer.
  Only sessions started from Emacs count, including children; other clients'
  history and resumed usage do not. The echo line (`agent-usage-echo-mode`, drawn
  into ` *Minibuf-0*`) and usage page (`C-c a u`, RET filters a row) are unchanged.
  Forecasts project from the last seventh of a window (a day for weekly windows),
  waiting until readings cover half of that span, so idle days do not exaggerate
  capacity. `M-x agent-usage-clear` still asks `yes-or-no-p` and stays unbound.
  `M-x agent-usage-restart-service` now reconnects and reapplies poll settings;
  it does not stop a daemon's live sessions.
- `agent-canvas.el` — `render` / `patch` methods: native pages built from JSON blocks
  (text, tables, SVG charts and diagrams, buttons that send prompts back to the session).
  An `elisp` block runs the agent's Lisp at point on every redraw (resize, theme change,
  `g`, state change); the public `agent-canvas-*` helpers give it page state kept across
  redraws, buttons, timers cancelled on redraw, and a way to message the session. `v`
  shows the source of the block at point. render / patch read and byte-compile elisp
  blocks before running them and return what they find as `warnings`. The `canvas_guide`
  method gives agents the how-to (kept in `agent-canvas--guide`) and the example pages in
  `lisp/agent/canvas-examples/` (snippets, not loaded or compiled; a test renders each one).
- `agent-review.el` — atomic reviews of a branch: `review_snapshot` pins base/head and
  lists hunks, the agent plans items, `review_build` checks every changed line is covered
  exactly once and shows a review buffer with a sidebar of items. The user selects lines
  and writes an annotation, which is sent straight to the originating session with the
  selected code; the agent answers with `review_reply`. Git runs in the
  caller's root through its file handler, so remote projects need nothing on the host.
  Data lives under `var/reviews/` as Lisp data.  The workflow for agents is the
  `emacs-atomic-review` skill (`skills/`), which replaces the CLIs' web page
  `atomic-review` skill in the sessions Emacs starts.
- `init-agent.el` — wires it all up; evil bindings live in `with-eval-after-load 'evil`.

The emx MCP server is only configured for agent processes started from Emacs (via
`--mcp-config` / `-c`), never globally. emx talks to Emacs through `emacsclient` using
temp request/response files (`agent-ui-rpc`) on the legacy path. With
`EMX_DAEMON_SOCKET` and `EMX_SESSION` set, `emx mcp` uses only the daemon:
`mcp/hello`, `mcp/tools`, `mcp/call`; editor calls and deferred polling go over
the attached agent-emx connection. The daemon caches definitions in tools.json
and dsh builds its MCP launch spec there, never in session/open. MCP clients
cannot take over the editor connection. See doc/emx-daemon.md for the contract.

## Verifying changes

Run from the repo root.

Tests (ERT, 290 tests, about half a minute). They exercise the native Emacs keys, so turn
evil off first (it is on by default and its normal state would eat typed keys):

```sh
emacs --batch --init-directory=. --eval '(setq my/use-evil nil)' -l init.el \
      -l test/agent-session-test.el \
      -l test/init-reload-test.el -l test/init-base-test.el -l test/init-remote-test.el \
      -l test/init-ui-test.el -l test/init-term-test.el \
      -l test/agent-review-test.el \
      -l test/agent-canvas-test.el -l test/agent-session-table-test.el \
      -l test/agent-session-link-test.el -l test/agent-backend-test.el \
      -l test/agent-usage-test.el \
      -l test/agent-emx-test.el -l test/agent-emx-config-test.el \
      -l test/agent-emx-collab-test.el -l test/agent-emx-remote-test.el \
      -f ert-run-tests-batch-and-exit
```

Byte-compile check — compile into a temp dir so no stale `.elc` lands next to the
sources (Emacs would load it instead of the `.el`):

```sh
emacs --batch --init-directory=. -l init.el --eval '
(let ((out (make-temp-file "elc-" t)))
  (setq byte-compile-dest-file-function
        (lambda (f) (expand-file-name (concat (file-name-nondirectory f) "c") out)))
  (dolist (dir (list "lisp/core" "lisp/agent" "lisp/agent/backend" "lisp/lang" "lisp/app"))
    (dolist (f (directory-files dir t "\\.el$"))
      (byte-compile-file f))))' 2>&1 | grep -A3 -E '^[a-z-]+\.el:[0-9]+|Error'
```

No output means a clean compile. It must stay warning-free, including with evil disabled (declare evil functions
with `declare-function`; call `evil-define-key*`, not the `evil-define-key` macro).
`node --check bin/emx` for the bridge and `node --check
lisp/agent/backend/dsh/emacs-bridge.mjs` for the dsh plugin. The usage tests moved
to `test/emx/usage*.test.ts`, retaining `test/fixtures/usage/`.

Install the pinned local build tools with `npm install --prefix emx`. Build and
check the daemon from the checkout (never use a global `tsc`):

```sh
npm install --prefix emx
node bin/emx daemon --manifest              # build on demand and print host manifest
emx/node_modules/.bin/tsc -p emx             # noEmit, includes test/emx
node --test test/emx/ test/emx-mcp-test.js
```

`emx/tsconfig.build.json` emits ESM ES2022 JavaScript with rewritten `.js`
imports. `bin/emx` invokes the local compiler into a temporary tree, copies
`config.json` and adds an ESM package marker, then atomically switches
`emx/dist` to a complete immutable generation (`emx/.dist-build-*`). A source
stamp skips unchanged builds; competing builders wait under a lock, and a
failed compile leaves dist intact. Dist and generations are generated and
git-ignored. Keep old generations while processes may still import them;
they can be removed once those processes have exited. Hosts receive only the
manifest's dist files, `bin/emx` and dsh plugins, and never need build tools.
Node 18.17+ (or 20.3+) is required by `AbortSignal.any`; tests themselves use
this machine's Node with type stripping. Set `EMX_NODE_MIN=/path/to/node`
to exercise the source-free runtime with the minimum Node binary. Tests run
daemons only on temp var dirs, never the default one. Quota poll tests use only
fake CLIs; batch Emacs integration tests bind `agent-usage-poll-interval` to 0.

Add or update a regression test for every bug fix and UI behavior change. Tests that
need the Claude/Codex backends should exercise their pure functions (as the sync and
image tests do) rather than spawning real CLIs.

## Live development in the user's Emacs

The user develops inside a running Emacs, often from an agent session hosted by it.
After changing code, hot-reload it instead of asking for a restart:

```sh
bin/emx reload
```

(the `reload` MCP tool, or `M-x my/reload-config`). It reloads every file under the
running Emacs's `lisp/` changed on disk since it was last loaded, in dependency order,
and reports each file as `reloaded`, `failed` or `restart_required`. Edits in another
checkout, such as a worktree, are not picked up: pass their absolute paths
(`bin/emx reload --files "$PWD/lisp/agent/agent-ui.el ..."`; relative paths resolve
against the running config) only when the user wants to try that code. Unlike a
plain `load`, it:

- byte-compiles each file first (a copy, in a temp dir; nothing lands next to the
  source) and evaluates the result as if it were the source, so reloaded functions
  run compiled instead of interpreted — interpreted code in a big module can freeze
  Emacs. A file that does not compile is reported `failed` and nothing of it is
  loaded; compiler warnings come back in the file's `warnings`;
- merges `defvar-keymap` (and keymap `defvar`) definitions into the live keymaps,
  keeping bindings other files added; bindings the source dropped are removed from
  the second reload on, once there is a previous version to compare with;
- moves `defcustom`s nobody customized or `setq`'d to their new default and applies
  changed `defface` specs; other `defvar`s are state and keep their values;
- refuses to load a file whose `cl-defstruct` layout changed (it would break live
  objects, including the `agent-session` you may be running in) and reports
  `restart_required`; slots appended at the end load with a warning, since objects
  made before lack them. Prefer keeping per-backend state in the `state` plist;
- never reloads `init.el` / `early-init.el` (`restart_required`), nor files that only
  depend on a changed file: reload those yourself when they expand a changed macro.

Other caveats:

- Re-running a major mode in a live buffer kills its buffer-local variables (e.g.
  `agent-session-list--root`); save and restore them.
- If `emacsclient` hangs or reports "Server not responding", Emacs is blocked; diagnose
  with `sample <pid>` instead of retrying.

## Gotchas

- Never start an Emacs server from batch/test runs (`server-start` is guarded by
  `noninteractive`). A batch Emacs that grabs the default socket deletes it on exit and
  leaves the user's Emacs unreachable.
- Emacs handles `SIGALRM` itself, so `perl -e 'alarm N; exec ...'` does not time out a
  batch Emacs; kill it from a parent process instead.
- `json-parse-string` returns arrays as vectors: iterate with `seq-doseq`, not `dolist`.
  `json-serialize` returns unibyte UTF-8; write it with `no-conversion`.
- file-notify (kqueue on macOS) only delivers events through the GUI event loop; test it
  in the running Emacs, not in batch.
- Mouse highlighting merges adjacent text whose `mouse-face` values are `eq`; give each
  item its own value.
- Docstring lines must fit in 80 columns (byte-compiler warning).
- Codex `-c` TOML for the MCP env must not repeat keys.
- Synchronous network round trips on timers (e.g. VC refresh of remote buffers) freeze
  Emacs; keep remote work on demand.

## Conventions

- **Language.** Code comments, docstrings, commit messages and everything agent-facing
  (MCP instructions, tool and parameter descriptions, errors returned to agents) are in
  English. Text shown to the user in the UI (messages, labels, prompts, notices, page
  content) is in Chinese.
- **Commits.** Commit in small, coherent steps with English messages: a short imperative
  summary line, then a body explaining why. Never add `Co-Authored-By` or other agent
  attribution trailers. Git identity for this repo is `简 <chenhowe0529@gmail.com>`.
  Only push when the user asks, and check the outgoing commits for sensitive data
  (local paths, credentials, internal hosts) first.
- **Keys.** evil is on by default but optional (`my/use-evil`, toggled with
  `M-x my/toggle-evil`; `C-u` saves the choice), so every feature must also work with
  the native Emacs keybindings, and every evil binding must stay inside
  `with-eval-after-load 'evil`.
- **Modularity.** New languages go in `lisp/lang/lang-NAME.el` and are enabled in
  `my/languages`. A new agent lives in `lisp/agent/backend/agent-NAME.el`,
  implements the generics, registers itself with `agent-session-define-agent`,
  and is enabled via `my/agents` in init.el. New agent -> Emacs abilities are
  `agent-ui-defmethod`s; only work that needs no Emacs state (like the `config_*` file
  tools) belongs in emx itself.
- **Packages.** use-package with GNU ELPA first, then NonGNU, then MELPA; pin to MELPA
  only when needed (evil: NonGNU 1.15 breaks on Emacs 31).
- **State.** Runtime files go under `var/` (`my/var`), never into tracked paths.
- **Style.** Match the surrounding code: lexical-binding headers, `agent-session--`
  prefix for internals, comment density similar to nearby code.
