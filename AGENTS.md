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
  init-lazy.el           on-demand modules: `my/lazy-modules' triggers (files, modes, keys, commands)
lisp/lang/lang-NAME.el   one file per language; enabled via `my/languages' in init.el
lisp/agent/              shared agent support (see below)
  agent-emx.el          required daemon client, session views and editor tools
  agent-emx-remote.el   host runtime install, -L transport, config and usage relay
  agent-profiles.el     standalone subagent profile and quota threshold controls
  backend/              individual backends, enabled via `my/agents' in init.el
    agent-NAME.el       enabled-agent registration (all use :backend emx)
    pi/                 thin Pi RPC approval and direct MCP extension
    dsh/                DeepSeek Harness bridge plugin and profile patches
lisp/app/                standalone applications; enabled via `my/apps' in init.el
  init-telega.el         Telegram client (telega; needs a source-built TDLib)
bin/emx                  minimal launcher: locate/build dist, import compiled CLI
emx/                     the emx daemon (TypeScript compiled on demand to generated dist/): protocol, sessions, backends
  cli/                   argument parsing, help, emacsclient transport, daemon/MCP dispatch
  backends/               Claude, Codex, dsh, Pi protocol adapters and native history
  usage/                 ledger, quotas (including Pi OpenCode Go), forecasts and live accounting
  mcp.ts                 stdio MCP client (requires daemon socket/session binding)
skills/NAME/SKILL.md     skills given to the agents Emacs starts (`agent-session-add-skill')
doc/subagents.md         design of subagents and agent collaboration, with measurements
doc/emx-daemon.md        design of the emx daemon, sessions and remote projects
test/agent-backend-test.el  ERT suite for enabled daemon registrations
test/agent-session-test.el  ERT suite for the agent UI (uses a fake echo backend)
test/agent-session-table-test.el  ERT suite for Markdown tables in transcripts
test/agent-session-link-test.el   ERT suite for clickable links in transcripts
test/init-reload-test.el    ERT suite for reloading
test/init-base-test.el      ERT suite for base defaults
test/init-remote-test.el    ERT suite for remote editing
test/init-ui-test.el        ERT suite for the themes, status line and side panels
test/init-term-test.el      ERT suite for the terminal module
test/init-lazy-test.el      ERT suite for on-demand module loading
test/lang-test.el           ERT suite for the language modules (toolchains mocked)
test/lang-c-test.el         C/C++ modes, clangd environments and keys (mocked)
test/agent-review-test.el   ERT suite for atomic reviews (builds throwaway Git repos)
test/agent-canvas-test.el   ERT suite for agent pages (elisp blocks, state, timers)
test/agent-usage-test.el    ERT suite for usage events, the echo line and the usage page
test/agent-profiles-test.el ERT suite for profile controls and quota thresholds
test/agent-emx-test.el      ERT suite for the emx backend (starts a daemon on a temp var dir)
test/agent-emx-remote-test.el ERT host simulation with stubbed tramp/SSH
test/agent-emx-smoke-test.el Batch end-to-end fake Claude/Codex/dsh cut-over smoke
test/emx/usage*.test.ts     usage arithmetic, daemon accounting and fake quota polls
                           (unchanged fixtures in test/fixtures/usage/)
test/emx/                   node --test suites for the emx daemon
var/                     runtime state (history, backups, pasted images...); git-ignored
```

### Agent layer (`lisp/agent/`)

- `agent-session.el` — the core. A `cl-defstruct agent-session` plus backend generics
  (`agent-session-backend-start/send/steer/interrupt/stop/models/modes/commands/
  apply-settings/reconnect`). Owns the session buffer: transcript | footer (separator,
  approval and queued-message lines, prompt) | input area, all in one buffer. Blocks
  (user / text / tool / notice) are stored in a hash table and re-rendered in place.
  Also: turn folding, steering, queueing, completion, image attachments, mode-line,
  transient menu `agent-session-menu`, global prefix map on `C-c a`.
- `agent-session-table.el` — renders complete Markdown tables in replies after
  fontification, keeping cell faces and lining up CJK text.
- `backend/agent-{claude,codex,dsh,pi}.el` — small registration modules, loaded
  only for `my/agents`. All register `:backend emx`; no Lisp protocol adapters
  or migration switch remain. Defaults and execution policy are daemon config.
- `emx/backends/claude.ts` — Claude stream-json, approvals, live model/mode
  changes and resume for effort changes. Streams native JSONL history in pages,
  follows external clients, and resumes to catch up before sending. Native
  discovery reads bounded title/head/tail data, including Desktop worktrees.
  Background tasks keep the process alive across idle periods and defer restarts;
  completion wakes an accounted autonomous turn, with a 15-second wake guard.
- `emx/backends/codex.ts` — Codex app-server JSON-RPC, approvals, models and
  settings. Injects daemon MCP and preserves developer instructions. A saved
  thread restarts on editor tool changes; ephemeral children keep their process.
- `emx/backends/dsh.ts` — peer of `backend/dsh/emacs-bridge.mjs`, mounted by
  `emacs.yml` into dsh's sdk profile. Owns replay, settings, approvals, plan
  review and live usage. The plugin uses dsh internals (tested 0.2.0-rc.2);
  it gates non-read-only MCP calls in restricted presets and delegates Auto to
  dsh's reviewer. Credentials stay in dsh's own credentials file.
- `emx/backends/pi.ts` — Pi 1.3.0 RPC, filtered OpenCode Go models, live
  thinking/mode settings, native resume/fork and `agent_settled` completion.
  `backend/pi/emacs-extension.js` forwards every tool for daemon arbitration
  and registers direct Emacs MCP. Tests use a fake Pi CLI only.
- `emx/backends/history.ts` — `sessions/history {agent, root}`: discover past
  Claude JSONL, Codex `thread/list`, and dsh `sessions/list` asynchronously on
  their owning host. Groups git worktrees and preserves each resume root.
- `agent-emx.el` — one client backend for every enabled agent. Connections own
  sockets; `agent-session` holds only view/client state. Events render into the
  existing UI API, with sequence cursors for disconnect/replay and earlier
  history. Hello restores live top-level views before children; native resume
  reuses live daemon sessions. Installed skills travel as backend-neutral
  session context and are inherited across backend boundaries. The struct removed its process slot and renamed state to client in
  phase 8: this is `restart_required`; never hot-reload that layout change.
- `agent-emx-remote.el` — content-addressed host runtime install and private
  `ssh -L` ControlMaster transport for all remote sessions. Node 18.17+ (or
  20.3+) is checked in the actual home-directory bootstrap. Repairs publish
  fresh generations behind a version pointer and retain existing installs.
  Timers only restore local
  forwards for connected hosts; install, ensure, root expansion, skills and
  uploads run on user action. Host config overrides executables only. Durable
  usage outboxes use sequence acknowledgments. Children remain in the parent's
  daemon; cross-daemon list/read/ask and replies use Emacs as the hub. Tests
  simulate a host locally.
- `agent-remote.el` — shared ControlMaster lookup and input upload helpers.
  No reverse bridge, keeper, relay, per-session emx or byte-offset reattach.
- `agent-session-list.el` — the session sidebar (live sessions + history per project),
  keyboard and mouse.
- `agent-ui.el` — editor methods defined by `agent-ui-defmethod`, exposed over
  the daemon's `editor/call`. Deferred results return immediately and are polled
  by the daemon. Definitions and private read-only classification go over
  `editor/tools`; method registration and module loads publish changes without
  filesystem stamps or a polling timer. The bare CLI retains `agent-ui-rpc`.
- `agent-collab.el` — editor-only collaboration: enrich user mentions from
  cached daemon wording and link child progress in the parent's tool block.
  `agent-emx` recovers daemon views, routes cross-daemon calls and answers; `agent-session` mirrors
  child asks in the parent's footer. `emx/daemon/collab.ts` owns all five
  `session_*` tools, handles, profiles, forks, children and persisted mailboxes.
  Policy is in `emx/config.json` plus `var/emx/config.json`, with no Lisp
  defcustom fallbacks. `agent-emx-config.el` caches display titles, executable
  names and input wording only. See `doc/subagents.md`.
- `agent-usage.el` — displays daemon quota snapshots and asynchronous reports.
  `emx/usage/` alone owns turn accounting, ledger writes, quota polls and
  forecasts, including while Emacs is disconnected. Commands come from effective
  agent config and the enabled agent list; `usage.pollInterval` owns cadence.
  Pi polls OpenCode Go's undocumented usage endpoint using a key obtained
  from Pi, never persisted: 5h / weekly forecasts, monthly allowance only.
  The editor retains durable pending upgrade entries and the transport used to
  forward acknowledged host usage, plus one-time old-ledger conversion.
  `C-c a u` opens the report; `agent-usage-clear` stays unbound and confirmed.
  `agent-usage-restart-service` reconnects without stopping agents.
- `agent-profiles.el` — `C-c a p` opens a standalone local daemon profile page.
  It reads `collab/profiles {root}` using the invoking buffer's project root
  (or default-directory), remembers it for refresh and shows it in the header.
  Whole-profile and candidate switches use `collab/disable`, which mutates
  current policy in the daemon; candidate `disabledBy` lists matching entries.
  Exact default-model entries end in `profile:agent/`; named models may contain
  colons and slashes. Global and per-agent quota thresholds and a shortcut
  allowing an agent to exhaust its quota use `config/set`. Candidate editing,
  insertion, deletion and reordering write the full candidates array, preserving
  mode and effort; restoring defaults deletes the profile overlay. Model completion
  uses `agents/models` with configured models as fallback and accepts free text.
  Successful writes
  refresh the page; `g` refreshes manually and `q` quits.
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
  The session command `/atomic-review [BRANCH|COMMIT|A..B]` resolves the refs and
  pins the snapshot in Emacs, then sends the agent its id (`review_snapshot {snapshot}`).
  Data lives under `var/reviews/` as Lisp data.  The workflow for agents is the
  `emacs-atomic-review` skill (`skills/`), which replaces the CLIs' web page
  `atomic-review` skill in the sessions Emacs starts.
- `init-agent.el` — wires it all up; evil bindings live in `with-eval-after-load 'evil`.

The daemon injects MCP only into its own agent processes, never globally.
Its audited read-only set combines editor `:read-only` methods with
`sessions`, `session_read`, and host `config_read`. These need no approval:
Claude gets exact `--allowedTools` entries, Codex per-tool
`mcp_servers.emacs.tools.<name>.approval_mode="approve"`, and dsh its bridge
gate. Never publish `readOnlyHint` in MCP definitions. Persistent Claude and
Codex sessions resume in a new process before sending after a set change;
children retain their original set. Keep flags caller-independent so forks
share their parent's prompt cache under the same configuration and place.
`emx mcp` requires `EMX_DAEMON_SOCKET` and `EMX_SESSION`, and uses
`mcp/hello`, `mcp/tools`, `mcp/call`. The legacy emacsclient MCP transport
is removed. Bare CLI commands use `emx/cli/emacsclient.ts` and temporary request/response
files through `agent-ui-rpc`; `emx/cli/main.ts` dispatches daemon and MCP commands.
Host `config_*` tools live only in `emx/daemon/config-files.ts`.
Editor calls and deferred polling use the attached daemon connection; MCP
clients cannot take over the editor role.

## Verifying changes

Run from the repo root. For an isolated worktree, set `package-user-dir`
to the existing checkout's elpa directory before loading init.el. Run with the
caller's real HOME: every ERT file loads test/test-helper.el, which isolates
daemon/usage state and native history, supplies fake CLIs, disables background
auto-revert polling, and checks that var/emx stays empty. Integration tests that
rebind HOME must capture expanded local paths before doing so.

Tests (ERT, about half a minute). They exercise the native Emacs keys, so turn
evil off first (it is on by default and its normal state would eat typed keys):

```sh
emacs --batch --init-directory=. --eval '(setq my/use-evil nil)' -l init.el \
      -l test/agent-session-test.el \
      -l test/init-reload-test.el -l test/init-base-test.el -l test/init-remote-test.el \
      -l test/init-ui-test.el -l test/init-term-test.el \
      -l test/init-lazy-test.el -l test/lang-test.el -l test/lang-c-test.el \
      -l test/agent-review-test.el \
      -l test/agent-canvas-test.el -l test/agent-session-table-test.el \
      -l test/agent-session-link-test.el -l test/agent-backend-test.el \
      -l test/agent-usage-test.el -l test/agent-profiles-test.el \
      -l test/agent-emx-test.el -l test/agent-emx-config-test.el \
      -l test/agent-emx-collab-test.el -l test/agent-emx-remote-test.el \
      -l test/agent-emx-smoke-test.el \
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
git-ignored. Importers pin their resolved generation with a PID lease under
the publication lock. Publishing also handles real dist directories; cleanup
keeps the current, previous and live generations. Hosts receive only the
manifest's dist files, `bin/emx` and dsh plugins, and never need build tools.
Node 18.17+ (or 20.3+) is required by `AbortSignal.any`; tests themselves use
this machine's Node with type stripping. Set `EMX_NODE_MIN=/path/to/node`
to exercise the source-free runtime with the minimum Node binary. Tests run
daemons only on temp var dirs, never the default one. Quota poll tests use only
fake CLIs; batch Emacs integration tests set `usage.pollInterval` to 0 in temp config.

Add or update a regression test for every bug fix and UI behavior change. Backend protocol tests live under `test/emx/` and use fake CLIs only.
Use temporary var/history directories and fake CLIs. Keep the caller's HOME
except in tests specifically simulating a host or CLI home. Disable naming with
`collab.handleCommand: []` and `collab.agentHandleCommands: {}`, and set
`usage.pollInterval: 0` unless testing fake quota peers.

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
  made before lack them. Backend state lives in the daemon; the `client` plist
  holds only the editor's view/connection state;
- never reloads `init.el` / `early-init.el` (`restart_required`), nor files that only
  depend on a changed file: reload those yourself when they expand a changed macro.

After editing `emx/`, call the same `reload`. It builds changed sources, compares
runtime versions, and updates this Emacs's connected local and host daemons.
The report adds an `emx` array alongside `files`: each daemon reports `restarted`,
`restart_scheduled` (English reasons and session ids), `up_to_date`, or `failed`
(including compiler/install errors). `my/reload-config` keeps its Lisp entry list
and appends `(:emx VECTOR)` for the same reports.

`restart_scheduled` needs no second reload: the old daemon continues serving
requests and restarts itself once turns, asks, children and collaboration
deliveries finish. A live child must close because it cannot be resumed. The
calling agent's own running turn normally schedules the restart. Idle sessions
hibernate with their transcripts and resume ids; Emacs reconnects and restores
their views, and the next send resumes them with new code. Host runtime install
happens during reload, never from a reconnect timer. The manual fallback remains
`M-x agent-emx-restart-daemon`.

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
  `my/languages`; apps go in `lisp/app/init-NAME.el` and `my/apps`. Give each
  optional one an entry in `my/lazy-modules` (the files, global keys and
  commands that first use it), so it loads and installs its packages only then;
  a test checks the file triggers match the module's own `auto-mode-alist` rules.
  Reloading never installs new triggers or loads a module nobody used yet: a
  table edit takes effect after a restart, or `my/lazy-require` on the feature.
  A new agent lives in `lisp/agent/backend/agent-NAME.el`, registers itself
  with `agent-session-define-agent` using `:backend emx`, with its protocol
  adapter in `emx/backends/`, and is enabled via `my/agents` in init.el. New agent -> Emacs abilities are
  `agent-ui-defmethod`s; only work that needs no Emacs state (like the `config_*` file
  tools) belongs in emx itself.
- **Packages.** use-package with GNU ELPA first, then NonGNU, then MELPA; pin to MELPA
  only when needed (evil: NonGNU 1.15 breaks on Emacs 31).
- **State.** Runtime files go under `var/` (`my/var`), never into tracked paths.
- **Style.** Match the surrounding code: lexical-binding headers, `agent-session--`
  prefix for internals, comment density similar to nearby code.
