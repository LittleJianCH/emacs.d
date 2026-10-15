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
  init-ui.el             theme, fonts, windows
  init-evil.el           optional Vim bindings (off by default)
  init-completion.el     vertico / orderless / consult / corfu / cape
  init-dev.el            project, magit, eglot, tree-sitter
  init-remote.el         remote editing (tramp-rpc)
lisp/lang/lang-NAME.el   one file per language; enabled via `my/languages' in init.el
lisp/agent/              agent support (see below)
bin/emx                  Node bridge: agent -> Emacs (CLI and MCP server)
test/agent-session-test.el  ERT suite for the agent UI (uses a fake echo backend)
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
- `agent-claude.el` — Claude Code backend: `claude -p --input-format stream-json
  --output-format stream-json --permission-prompt-tool stdio ...`. Permissions arrive
  as `control_request`/`can_use_tool`; model and permission mode switch live via control
  requests; effort needs a restart with `--resume`. History and replay read
  `~/.claude/projects/<encoded-root>/<session-id>.jsonl`; the same file is watched to
  show messages written by other clients (Claude Desktop, terminal), and the CLI is
  restarted with `--resume` before the next send so its context catches up.
- `agent-codex.el` — Codex backend over `codex app-server` (JSON-RPC: `thread/start`,
  `turn/start`, `turn/steer`, approvals via `item/*/requestApproval`). The emx MCP server
  is injected per process with `-c mcp_servers.emacs.*`.
- `agent-dsh.el` — DeepSeek Harness (`dsh`) backend. dsh's own SDK/ACP protocols are too
  thin (SDK cannot cancel or approve), so we ship a dsh plugin, `dsh/emacs-bridge.mjs`,
  mounted into the stock `sdk` profile by `dsh/emacs.yml` (`dsh --profile sdk --patch
  ...`). It drives one dsh agent through dsh's internal API (`ctx.agents`,
  `agent/assistant-stream`, `session/event`, `approval/request`) and speaks our own
  line-delimited JSON-RPC, documented at the top of the plugin. It depends on dsh
  internals, so expect to adjust it when dsh is upgraded. The API key lives in dsh's
  `~/.dsh/.credentials.yaml`; never pass it through the environment.
- `agent-session-list.el` — the session sidebar (live sessions + history per project),
  keyboard and mouse.
- `agent-ui.el` — methods agents can call, defined with `agent-ui-defmethod`; emx's
  `tools/list` is generated from these, so a new method is automatically an MCP tool.
- `agent-canvas.el` — `render` / `patch` methods: native pages built from JSON blocks
  (text, tables, SVG charts and diagrams, buttons that send prompts back to the session).
- `init-agent.el` — wires it all up; evil bindings live in `with-eval-after-load 'evil`.

The emx MCP server is only configured for agent processes started from Emacs (via
`--mcp-config` / `-c`), never globally. emx talks to Emacs through `emacsclient` using
temp request/response files (`agent-ui-rpc`).

## Verifying changes

Run from the repo root.

Tests (ERT, ~30 tests, a few seconds):

```sh
emacs --batch --init-directory=. -l init.el -l test/agent-session-test.el \
      -f ert-run-tests-batch-and-exit
```

Byte-compile check — compile into a temp dir so no stale `.elc` lands next to the
sources (Emacs would load it instead of the `.el`):

```sh
emacs --batch --init-directory=. -l init.el --eval '
(let ((out (make-temp-file "elc-" t)))
  (setq byte-compile-dest-file-function
        (lambda (f) (expand-file-name (concat (file-name-nondirectory f) "c") out)))
  (dolist (dir (list "lisp/core" "lisp/agent" "lisp/lang"))
    (dolist (f (directory-files dir t "\\.el$"))
      (byte-compile-file f))))' 2>&1 | grep -A3 -E '^[a-z-]+\.el:[0-9]+|Error'
```

No output means a clean compile. It must stay warning-free, including with evil disabled (declare evil functions
with `declare-function`; call `evil-define-key*`, not the `evil-define-key` macro).
`node --check bin/emx` for the bridge, `node --check lisp/agent/dsh/emacs-bridge.mjs`
for the dsh plugin.

Add or update a regression test for every bug fix and UI behavior change. Tests that
need the Claude/Codex backends should exercise their pure functions (as the sync and
image tests do) rather than spawning real CLIs.

## Live development in the user's Emacs

The user develops inside a running Emacs, often from an agent session hosted by it.
After changing code, hot-reload it instead of asking for a restart:

```sh
emacsclient -e '(load (locate-user-emacs-file "lisp/agent/agent-session.el") nil t)'
```

`locate-user-emacs-file` resolves against the running Emacs's config directory, so
the command names no machine-specific path.

Load in dependency order: agent-session -> agent-claude / agent-codex / agent-dsh ->
agent-session-list -> agent-ui -> agent-canvas -> init-agent. Caveats:

- `defvar`, `defvar-keymap`, `defcustom` and `defface` do not re-evaluate on reload.
  Apply new key bindings with `keymap-set` and changed defaults with `setq` afterwards,
  then verify (`keymap-lookup`).
- Changing the `agent-session` struct layout breaks live session objects — including the
  session you may be running in. Append new slots at the end, or keep per-backend state
  in the `state` plist; if a layout change is unavoidable, ask the user to restart.
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
- **Keys.** Emacs keybindings are the default. evil is optional (`my/use-evil`, toggled
  with `M-x my/toggle-evil`; `C-u` saves the choice) and every evil binding must stay
  inside `with-eval-after-load 'evil`.
- **Modularity.** New languages go in `lisp/lang/lang-NAME.el` and are enabled in
  `my/languages`. A new agent is a backend implementing the generics plus one
  `agent-session-define-agent` line in `init-agent.el`. New agent -> Emacs abilities are
  `agent-ui-defmethod`s.
- **Packages.** use-package with GNU ELPA first, then NonGNU, then MELPA; pin to MELPA
  only when needed (evil: NonGNU 1.15 breaks on Emacs 31).
- **State.** Runtime files go under `var/` (`my/var`), never into tracked paths.
- **Style.** Match the surrounding code: lexical-binding headers, `agent-session--`
  prefix for internals, comment density similar to nearby code.
