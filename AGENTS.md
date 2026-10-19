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
  backend/              individual backends, enabled via `my/agents' in init.el
    agent-NAME.el       backend implementation and registration
    dsh/                DeepSeek Harness bridge plugin and profile patch
lisp/app/                standalone applications
  init-telega.el         Telegram client (telega; needs a source-built TDLib)
bin/emx                  Node bridge: agent -> Emacs (CLI and MCP server)
skills/NAME/SKILL.md     skills given to the agents Emacs starts (`agent-session-add-skill')
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
- `backend/agent-codex.el` — Codex backend over `codex app-server` (JSON-RPC: `thread/start`,
  `turn/start`, `turn/steer`, approvals via `item/*/requestApproval`). The emx MCP server
  is injected per process with `-c mcp_servers.emacs.*`.
- `backend/agent-dsh.el` — DeepSeek Harness (`dsh`) backend. dsh's own SDK/ACP protocols are too
  thin (SDK cannot cancel or approve), so we ship a dsh plugin, `backend/dsh/emacs-bridge.mjs`,
  mounted into the stock `sdk` profile by `backend/dsh/emacs.yml` (`dsh --profile sdk --patch
  ...`). It drives one dsh agent through dsh's internal API (`ctx.agents`,
  `agent/assistant-stream`, `session/event`, `approval/request`) and speaks our own
  line-delimited JSON-RPC, documented at the top of the plugin. Modes map to dsh
  permission presets (`auto` is dsh's experimental auto-review plugin, also mounted by
  `emacs.yml`); plan mode is dsh's own, and its `exit_plan_mode` review arrives as a
  `question`. History and replay go through the bridge too (`sessions/list`, resume
  returns the transcript); dsh's session logs are zstd-compressed, don't parse them in
  Elisp. emx is mounted per agent with dsh's MCP client. For a remote project dsh runs
  on the host like the other backends: the plugin files are copied to
  `~/.cache/emacs-agent/dsh/<content hash>/` there, emx goes through the relay of
  `agent-remote.el`, and the host needs dsh, python3 and its own dsh credentials. The
  bridge reports dsh's version and the session notes one other than
  `agent-dsh-tested-version`. It depends on dsh internals,
  so expect to adjust it when dsh is upgraded. The API key lives in dsh's
  `~/.dsh/.credentials.yaml`; never pass it through the environment.
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
- `agent-session-list.el` — the session sidebar (live sessions + history per project),
  keyboard and mouse.
- `agent-ui.el` — methods agents can call, defined with `agent-ui-defmethod`; emx's
  `tools/list` is generated from these, so a new method is automatically an MCP tool.
  A method that waits for something slow returns `agent-ui-defer` at once and emx polls
  it (`_poll`), so Emacs never blocks while an agent waits.
- `agent-collab.el` — agents working with each other. Every session has a handle
  (`@cfi-meaning`) named from its topic by a cheap model of its agent
  (`agent-collab-agent-handle-commands`, else `agent-collab-handle-command`); users
  mention sessions with it. Methods `sessions`, `session_read` (latest turns, paged)
  and `session_ask` (sends a prompt to an idle open session, confirmed by the user when
  `agent-collab-confirm` is set, and waits for its reply). Agents never start sessions
  themselves.
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
temp request/response files (`agent-ui-rpc`).

## Verifying changes

Run from the repo root.

Tests (ERT, ~50 tests, a few seconds). They exercise the native Emacs keys, so turn
evil off first (it is on by default and its normal state would eat typed keys):

```sh
emacs --batch --init-directory=. --eval '(setq my/use-evil nil)' -l init.el \
      -l test/agent-session-test.el \
      -l test/init-reload-test.el -l test/init-base-test.el -l test/init-remote-test.el \
      -l test/init-ui-test.el -l test/init-term-test.el \
      -l test/agent-review-test.el \
      -l test/agent-canvas-test.el -l test/agent-session-table-test.el \
      -l test/agent-session-link-test.el -l test/agent-backend-test.el \
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
`node --check bin/emx` for the bridge, `node --check lisp/agent/backend/dsh/emacs-bridge.mjs`
for the dsh plugin.

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
