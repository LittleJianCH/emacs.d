# Subagents and agent collaboration

Emacs runs subagents for every backend itself. A parent session's agent calls
`session_start` to hand a task to a child session on any harness and model; the
child does that one task and its final reply comes back through a mailbox. The
CLIs' own subagent mechanisms are turned off. The motivating case: Claude Opus
directs while DeepSeek flash, through dsh, writes the code.

Code: `lisp/agent/agent-collab.el` (tools, profiles, mailbox),
`lisp/agent/agent-session.el` (parent/child links, closing), the backends under
`lisp/agent/backend/`.

## How other harnesses do it

None lets a child run in another harness; at most they switch the model. Only a
host above several harnesses, such as T3 Code or this Emacs, can.

| Project | Parent calls | Child context | Choice | Results | Child approvals | Persistence |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code | `Agent{description, prompt, subagent_type, model, run_in_background, isolation}`, definitions in `.claude/agents/*.md` | fresh; fork mode inherits the parent's messages (off in `-p`) | model only | background by default; a `<task-notification>` user message starts a parent turn | surface in the parent, labelled; `can_use_tool` carries `agent_id` | `<session>/subagents/agent-<id>.jsonl` |
| Codex | V2 `spawn_agent`, `followup_task`, `wait_agent`, `interrupt_agent`; roles in `[agents.<role>]` | `fork_turns` (default all), but tool calls, reasoning and interim replies are dropped | model within the parent's provider; roles can't change the provider | always background; results queue for the parent, `wait_agent` waits | same connection, child `threadId`; clients can't send input to V2 children | own rollout, shares the root's `session_id` |
| dsh | `subagent` (continuable, background), `subagent_fork` (one-shot), plus `send_message`, `interrupt_agent`, `list_agents` | spawn fresh; fork copies completed turns byte for byte | provider and model per call (opt-in) | settlement notice when a child ends | the child's own | own log with lineage |
| opencode | `task{description, prompt, subagent_type, task_id?, background?}` | fresh; `task_id` continues a child | `provider/model` per agent | blocking, or background with a synthetic message | shown in the parent view; the parent can't type until answered | full child session, `parentID` |
| pi (extension example) | `subagent`: single, parallel, chain | a fresh `pi --mode json` process | `provider/model` per agent file | blocking | none | not saved |
| pi-subagent-manager | `agent_spawn{path, type, task, wait, timeoutMs}`, `agent_wait`, `agent_steer`, `agent_stop`, `agent_output`; child-only `agent_update`, `agent_pause` | by path: `/root/x` inherits, `/x` is fresh | ordered `models` list, exact match | blocking by default; detached results are saved, then delivered when the parent is idle; progress never wakes it; optional batched wake | no confirmation channel (inferred) | in-process sessions, own jsonl |
| Amp | built-in Search, Oracle, Librarian, Task; the oracle is another model used as a tool | only the instructions given | modes bind models; the oracle may be another vendor's | final summary only | none by default | custom ones are threads with `parentThreadID` |
| T3 Code | MCP `delegate_task{task, target{provider, model}, role, mode, isolation}`, `task_status`, `task_cancel` | the task only; separate fork and budgeted text handoff | any provider and model | pointer wake ("task X ended, read it with task_status"), batched per turn, acknowledged on read | questions go to the parent agent; approvals only to the user | threads; children read-only to the user |

## What we took

| Practice | From | Here |
| --- | --- | --- |
| A child is a full session, linked to and shown under its parent | opencode, Codex, T3, Amp; pi's "black box" critique | an ordinary agent-session with `:parent` |
| Only the final text comes back, clipped | all | `collab.textLimit` |
| Background results wake the parent; it never polls | Claude Code, opencode, pi-subagent-manager, T3 | the mailbox |
| Several results wake it once | pi-subagent-manager, T3 | one message per idle transition |
| Approvals go to the user, never to an agent; a parent is never held up while a child waits for the user | T3, Claude Code, opencode | yes |
| A child's permissions only narrow | T3 | mode capped by the parent's |
| Depth 1, a concurrency cap | Codex V1, dsh, opencode | yes |
| Forks keep the tool list, put the task after the history, refuse at call time | Claude Code fork, dsh `subagent_fork` | the rules below |

Not taken: back-and-forth between parent and child (Codex `followup_task`, dsh
`send_message`, `agent_steer`) — a child does one task, and conversations belong
between sessions the user opened; child-only tools (`agent_update`,
`agent_pause`), which would make a fork's tools differ from its parent's;
letting the model pick any model per call — it picks a profile; T3's pointer
wake — the clipped reply itself saves a round trip, and a child replies once.

## Measurements: can a fork reuse the parent's prompt cache?

Pass means the child's first request reads, from cache, the prefix of the
parent's last request. Numbers are cached tokens / parent's last prompt.

| Backend (model) | Fork | Cache | Parent mid-turn | Child saved |
| --- | --- | --- | --- | --- |
| Claude (haiku) | `claude -p --resume <parent> --fork-session`, all other flags as the parent's | fresh parent 40371/40373; restarted parent 43642/43644; with `--no-session-persistence` 37749/37751 | 43702/43704; the pending tool call reads "interrupted, outcome unknown" in the child | not with `--no-session-persistence` |
| Codex (gpt-6-luna) | in the child's own app-server, `thread/fork {ephemeral: true, excludeTurns: true}` | ephemeral 6/6 at 96–99%; non-ephemeral 0 in 5/5 | works; the child sees an interrupted turn; `lastTurnId` gives a clean cut | ephemeral threads aren't saved and can't be converted later |
| dsh (deepseek-flash) | the child's bridge opens the parent's log read-only (after the parent flushes), `buildForkSeed`, `agents.create` | same as the parent's own next turn | works; a synthetic tool result closes the open call | yes; hidden with `parentSession` |

- Codex gives a fork the parent's cache routing only when it is ephemeral; this
  is fixed in its source (0.158 through main).
- These runs disabled Codex's MCP servers and plugins; the later runs through
  Emacs, with them on, hit the cache as well (see Fork below).
- With stream-json input, restarting Claude with `--resume` keeps the cache.

## Daemon migration

All enabled sessions use the daemon. `emx/daemon/collab.ts` owns tools,
children, naming, policy and the persisted mailbox; `emx/config.json` plus
its runtime override is the sole policy source. Lisp only renders views,
links child progress and mirrors asks. Children outlive editor disconnects
but not daemon crashes. Children start in their parent's daemon; `sessions`,
`session_read` and `session_ask` reach sessions of other daemons (other
hosts, or this machine from a host) through the attached Emacs, and work
only while it is attached (see doc/emx-daemon.md, Collaboration).

The design below describes that daemon contract. Historical measurements
were made through the earlier Lisp execution path; the protocols remain.

## Design

### Two kinds of sessions, three kinds of context

- Sessions the user opened are saved and resumable. They read each other with
  `session_read` and ask each other with `session_ask`; conversations happen
  here.
- Child sessions are started by an agent with `session_start`. A child does
  one task and reports its final reply. It takes no messages from agents and
  asks no other sessions. A profile may delegate bounded parts to explicitly
  allowed helpers; leaf profiles cannot start sessions. It lives with its
  buffer and parent. The user can still type in it.

| Context | The child gets | Harness and model | Cache | Use it when |
| --- | --- | --- | --- | --- |
| fresh | the task only | the profile's | builds its own | the task stands alone |
| handoff | Emacs's text of the parent's conversation, then the task | the profile's | none from the parent; siblings started in one turn share a prefix | the task needs context but a cheaper model can do it |
| fork | the parent's own messages, then the task | the parent's; no profile | reuses the parent's cache; output at the parent's price | the task needs the parent's own level of reasoning |

A handoff keeps, within `collab.handoffLimit` characters, the latest
turn (cut from the front if need be), the first user message, then the turns
between, newest first, noting what was left out.

### Tools

| Method | Does | Who |
| --- | --- | --- |
| `sessions` | lists open sessions with parent and children | anyone |
| `session_read` | latest turns of a session, paged | anyone |
| `session_ask` | asks an idle session; the reply goes to the mailbox | between sessions the user opened |
| `session_start` | starts a child: `profile`, `context`, `prompt`, `handle`, `title` | profiles with delegation capability |
| `session_stop` | stops and closes a child | its parent |

### Profiles

Users and agents select a role rather than a free harness and model pair.
New user conversations default to `orchestrator`. Profile identity is saved
with the session and restored on reconnect. Roles define ordered model
`candidates`, a `cost`, `description`, optional `confirm` and
`preferOtherAgent`, and a profile-specific MCP tool policy:

```json
"reviewer": {
  "cost": "high",
  "description": "Reviews substantive changes before delivery; reproduces what it finds and reports findings without editing files.",
  "preferOtherAgent": true,
  "candidates": [
    { "agent": "codex", "model": "gpt-6-astra", "mode": "plan" },
    { "agent": "claude", "model": "opus", "mode": "plan" },
    { "agent": "pi", "model": "opencode-go/qwen3.8-max", "mode": "plan" }
  ]
}
```

Candidates carry `agent`, optional `model`, `mode` and `effort`, and no cost.
Legacy profiles with top-level `agent`, `model`, `mode` and `effort` still mean
one candidate. A legacy override's top-level agent takes precedence over an
inherited candidates array, so old local overrides keep working.
The user-facing `orchestrator` role owns dialogue, task clarification,
decisions, delegation, integration and final acceptance. Its candidates are
Claude `opus` with `high` effort and Codex `gpt-6.1-sol` with `xhigh`
effort. `opus` is the supported CLI alias; no versioned ID is invented.

Task roles are `coder-flash` and `explorer-flash` (minimal), `explorer`
(low), `coder` (medium), `researcher` (high; reports, design notes or pages),
`reviewer` (high, prefers another agent), and `expert` (premium, confirmed).
Each has fallbacks across subscriptions and an explicit reasoning effort per
candidate, chosen from published effort/benchmark data (2026-10); the exact
order lives in `emx/config.json`. Quota windows whose reading predates their
reset, overage windows, and windows named after another model (Claude's
`seven_day_fable`) do not mark a candidate strained. The role's description stays stable across candidate changes.

The tool lists a role when at least one candidate is not disabled, its agent is
enabled and its executable is installed in the caller root's environment. Lines contain only
`- role: tier cost.  description`, without the selected agent or model.
Children start where their parent runs: this machine or a remote project such
as `/rpc:dev:`. The host daemon resolves the project's environment before
startup, then uses its cached PATH for MCP descriptions and candidate checks.
Opening another session refreshes that root and announces changed definitions
only to its MCP clients; no editor stamp or host lookup timer remains.
Definitions follow the caller's profile and project environment, rather
than its selected model or transient quotas. Sessions with the same role
receive stable capability definitions; different roles may receive
different tools even when they use the same model.

### User conversations and model selection

New-conversation commands select a profile, defaulting to `orchestrator`.
The normal `/model` picker lists that profile's candidates, including their
provider and reasoning effort. A candidate carries its own mode/effort;
switching within a provider uses its normal configuration path. Switching
providers keeps the daemon session ID and visible transcript, starts a
fresh native conversation and hands off bounded recent text. Native resume
IDs never cross providers. Switching is rejected while work, approvals,
queued messages or collaboration results remain pending.

`M-x agent-session-select-any-model` (also `a` in the session menu) selects
from all enabled providers' model catalogs.
It permits a model outside the profile candidates and uses orchestrator's
MCP policy. Legacy sessions retain their provider and model; absent profile
identity defaults to orchestrator capability policy rather than forcing a
model change. Profile identity travels in session info, including reconnect
snapshots and persisted records.

### MCP capabilities

`profiles.NAME.tools` is independent of the role's model candidates:

```json
"tools": {
  "allow": ["context", "buffers", "read_buffer", "diagnostics", "sessions", "session_read"],
  "delegate": []
}
```

`allow: "*"` allows the current MCP tools; a list permits only named tools.
`delegate` restricts the profiles that `session_start` may create. A role
without delegation does not receive that tool. Missing policy on legacy or
custom profiles uses orchestrator's policy. MCP listing and direct calls
use the same policy; a hidden tool cannot be invoked by guessing its name.
Profiles define capability boundaries for the injected MCP server, not a
sandbox around the agent's native CLI or filesystem tools.

`collab.disabled` defaults to `[]` and accepts strings in four forms:
`"reviewer"` disables the whole profile, `"reviewer:claude"` disables all of
that profile's Claude candidates, and `"reviewer:claude/opus"` disables the
candidate with that exact model string. `"reviewer:claude/"` disables only
Claude candidates with an unspecified model (omitted, null or empty), leaving
named-model siblings enabled. Parsing splits at the first `:` and then the
first `/` after it; the rest is an opaque model string, including any `:` or
`/`. Comparisons use no aliases or case folding. Profile and agent names must
be nonempty; profile names cannot contain `:`, and agent names cannot contain
`/`. Empty profile or agent parts are invalid; an empty model suffix is valid.
Unknown names are ignored. Candidates with the same agent/model identity share
an exact entry, even when mode or effort differs. Legacy top-level agent/model
profiles count as one candidate.
Profiles disabled outright or with every candidate disabled disappear from
tool descriptions, profile guidance and MCP instructions. Starting one fails
with `Profile <name> is disabled`.

On each `session_start`, emx walks the role's candidates in order. It skips
disabled candidates, disabled agents, missing executables and Pi models rejected by
`agents.pi.models` (the same `allowedModel` filter as the backend, including
its default model when omitted). It then skips strained subscriptions using
this daemon's current UsageService quota snapshot: only the agent's `host: null`
entry counts, and duplicate entries are ignored. A subscription is strained
when any window is `limited` or its used fraction reaches
`agents.<name>.quotaSkip`, falling back to `collab.quotaSkip` when the agent has
no override (global default `0.9`; both accept numbers from `0` through `1`),
or a nonempty balance list has
all amounts at or below zero. Missing quota data does not exclude a candidate;
remote readings and forecast values do not affect selection.

`preferOtherAgent: true` puts available, non-strained candidates with a different
agent from the caller first, preserving their relative order. The shipped
review role uses this: a Codex caller normally gets Claude Opus, while a Claude
caller gets Codex. If every available candidate is strained, emx still uses
the first available, non-disabled candidate in configuration order. Disabled
candidates are never eligible for this fallback. If none is available,
the error lists every candidate and its reason. A backend startup failure closes
the child and returns its error; selection does not retry after startup.

The started receipt names the chosen agent's title and the context, not the
model: the caller chooses by profile, and the session list shows each child's
model to the user.  It appends reasons for candidates skipped before it, for example
`Skipped candidates: Claude sonnet: 5h quota 93% used; DeepSeek: balance exhausted.`
The wording, including unavailable/model-filter/quota/vendor-preference reasons
and the no-candidate error, comes from `collab.prompts`. Child info keeps
`profile` as the role name, with its actual agent and model in the existing
session fields. Permission mode is still capped by the parent's mode.

The editor requests `collab/profiles` with `{ root?: string }` to inspect policy
and current quota state. Availability uses the same cached environment for that
root as selection, guidance and tool descriptions; omitting root uses the
daemon's process environment. All share the enabled-agent, executable and Pi
model checks. It returns every profile in configuration order, including disabled
ones, as `{ profiles: [{ name, cost, description, disabled, overridden,
candidates: [{ agent, model, effort?, mode?, disabled, disabledBy, available, unavailable?,
strained?, quotaSkip }] }], quotaSkip }`. A missing candidate model is `null`;
absent effort, mode and reason
fields are omitted. Missing cost and description become `"unknown"` and `""`.
Profile `disabled` means all its candidates are disabled. Candidate `disabledBy`
is an array of every matching `collab.disabled` entry, including a bare profile
entry, or `[]` when enabled. Candidate `available`
reflects enabled agents, installed executables and the Pi model filter,
independently of `disabled`. The outer threshold is global; each candidate
carries its effective threshold. `strained` uses exactly the same English
reason computation as selection and its skipped-candidate receipt.
`overridden` is true when the last successfully loaded user overlay contains
an entry at `profiles.<name>`, even when it has the same values as the defaults.

The local editor toggles policy with `collab/disable`:
`{ profile: string, candidate?: number, disabled: boolean }`, returning
`{ config }`. `candidate` is a zero-based index into the profile's current
candidates (including a legacy single candidate). The daemon reads current
defaults and overlay, mutates the disabled list synchronously and uses the
same validated atomic write and notification path as `config/set`; a stale
page cannot overwrite another writer's entries. Disabling a candidate always
adds an exact `profile:agent/model` entry, including the trailing slash for an
unspecified model. Enabling it removes every covering non-profile entry; when
an agent-wide entry is removed, exact entries are added for the siblings it
covered so those siblings stay disabled. Enabling a profile removes only its
bare entry; candidate entries remain. Invalid profile names, indices or
non-boolean states fail without publication. Host daemons reject mutations.

The local editor can request `config/set` with `{ path: ["agents", "claude",
"quotaSkip"], value: 0.8 }`. It edits only `var/emx/config.json`, preserving
other keys and creating intermediate objects. `value: null` deletes the overlay
key, pruning empty parent objects and restoring defaults through the normal
merge. emx validates the would-be merged configuration before touching the file;
invalid edits fail without changing it. Successful edits publish a temporary
file by atomic rename, using two-space JSON with a trailing newline, immediately
reload policy and notify clients and MCP tools. The response is `{ config }`
with the full effective config. Host daemons reject this request with
`config/set is only available on local daemons`; their config files continue
to accept only executable overrides through the existing host mechanism.

The profile page (`C-c a p`) remembers the invoking buffer's project root,
falling back to its `default-directory`, passes it to `collab/profiles` on
every refresh (including `g`), and shows it in the header. Candidate status
shows matching entries, for example 已停用（coder:codex）. All profile/candidate
switches use `collab/disable`. The page offers 编辑 and, for overridden profiles,
恢复默认. Each candidate has 修改, 删除 and ordering buttons; 添加候选 appends
a candidate. Agent completion uses the effective config's agents. Models accept
free text, including model ids absent from the choices; empty model or effort
means unspecified. Edits preserve existing permission modes and other candidates'
fields. Every candidate edit writes the whole nonempty array to
`["profiles", name, "candidates"]`, since arrays replace rather than merge.
An explicit `candidates` array in an overlay takes precedence over top-level
`agent`, `model`, `effort` and `mode` inherited from single-candidate defaults.
Writing that array through `config/set` also removes those conflicting fields
from that profile's overlay. Legacy single-agent overlays without an explicit
array continue to override default arrays. 恢复默认 sends
`{ path: ["profiles", name], value: null }`, removing the whole profile override.

`agents/models` takes `{ agent: string }` and returns
`{ models: [{ id: string, label?: string }] }` without opening a daemon session
or submitting a model turn. Codex uses a short-lived app-server to initialize
and page through `model/list`, excluding hidden entries. Pi uses a short-lived
RPC process with `--no-session`, extensions and skills disabled, requests
`get_available_models`, and applies the backend's `agents.pi.models`
include/exclude filter. Both queries have a ten-second deadline and close their
process afterward. Claude offers the aliases `default`, `sonnet`, `opus`,
`haiku`; other configured agents currently return an empty array. Unknown agents
fail. Queries use the configured executable, extra arguments and normal
`EMX_<AGENT>_EXECUTABLE` override. The page supplements choices with models
already present in config profiles and falls back to those on query failure.

The caller names a child after its task (`handle`, such as `cgu-measure`); it
knows the task best and needs no model call to do it. Without one the child is
named after its role. Use a fork when the task needs the caller's conversation
and prompt cache; emx chooses a candidate when a role is requested.
When to delegate lives in one place: `collab.prompts.delegation`, which
`mcp/hello` puts in front of the generated profile list, one line per available
role with its `use`. Both are always visible, so an agent can decide there;
neither appears when no profile is available. Claude Code defers MCP tool
schemas behind ToolSearch, so the `session_start` description and
`collab.startGuidance` stay unseen until an agent loads the tool; they only say
how to call it and how to brief, and never restate when. Codex repeats the
instructions before every tool, so the rule stays short.

The rule is shaped by the question, not by a count or by parallelism. Where
something is used, how a path works across files and what another codebase
does there are delegated before the second lookup, even as the user's whole question or a
follow-up with nothing else to do: at most one grep pins the symbol and
revision, the brief gives symbol, revision, repo and asks for file:line and what
the code does, and related questions of the turn share one brief. The parent
tells the user the profile and why in one sentence, ends its turn when it needs
the answer, and writes the user's answer from the report. Its exceptions sit in
the same item: a definition in a file already open, a fact outside those
questions that one grep settles, explaining code the user already pointed at
(lines just marked in a review, a diff already in the conversation),
edit-compile-fix interleaved with the agent's own edits, reading a diff to plan
an atomic review, and dialogue with the user. Children start nothing. Project
rules naming Claude's Agent or Explore, which emx disables, or "after N reads"
mean `session_start` here. Builds, benchmarks and test series that won't
interleave with the agent's edits are their own item, and independent parts of
nontrivial work a third, without keeping the reading half. Every shape the rule
names matches some profile's `use`; the rule names no profile.

Earlier versions failed in ways that motivated this. With only "nontrivial work
with independent parts" and "keep the immediate blocker local", a session asked
where a field is used grepped, read the call sites and compared Go's sources
itself: the lookup was the next step and had no other half. That held after
the profile list was made visible and with its project's own rule to hand over
archaeology past 3 reads. A trigger of "more than 3 reads" did not help either:
the count is unknown before reading, underestimated, easy to game with `git
grep` / `git show`, and blurred into the "few reads" exemption; 3 was one
project's threshold besides. Separately, once background runs could wake the
session, an agent implemented a change and ran a series of benchmarks itself in
hundreds of Bash calls; a note inside the `run_in_background` bullet is skipped
by an agent not thinking of background runs, hence the runs item, which says
"delegate" like the reading item. A grep listing the hits only pins the symbol:
the session that missed delegation began with one and would have counted it as
settling where-used, so "one grep" covers only facts outside the three shapes,
and reading a hit is the second lookup.

`collab.startGuidance` names no profiles; per-profile use belongs in each
profile's `use` and description. Split by outcome and file ownership,
not automatically into code, tests and docs; the parent must not edit files
assigned to a child either.

Give a concise brief with the goal, context, scope, constraints, verification
and expected report. Do not complete the work merely to specify it. Choose a
profile by its description; reasoning that depends heavily on the conversation
goes to a fork, never reading. Long runs with known commands
and inputs do not need a fork just to preserve context. Choose the
least costly profile likely to finish reliably, avoid
duplicating the child's task, and verify the important claims in its report.

Substantive changes get a separate review before final delivery, even when no
commit was requested; the reviewer's `use` says so. emx prefers another
vendor for it. Explicitly ask for findings, not edits.

Earlier observations motivated these boundaries: "fork when it needs your
context" led to an hour of builds and measurements on a fork despite known
commands being enough for a cheaper profile. Agents also decided several tasks
at once, or did every piece themselves when writing a spec seemed expensive.

These instructions aim to make delegation timely, not maximize child counts.
Protocol tests check that the rule, its exceptions and the child exception are
exposed; they do
not establish how often models follow them. Compare new sessions on a trivial
edit, independent investigations and a substantive change, checking delegation
timing, duplicate work, result quality, usage and elapsed time. Shared MCP
instructions and the generated summary are fixed for the MCP process lifetime;
MCP has no instructions-changed notification. Tool descriptions use the refresh
mechanism below. Profiles are filtered by enabled agents and executable
availability in the session root's environment, then sorted by cost: minimal,
low, medium, high, premium and unknown, with configuration order within a tier.
Both the tool description and the summary use `profileCost` for the static
role display tier; profiles themselves remain in `emx/config.json`.

### Rules

1. Tool definitions depend on the profile, configuration and project
   environment. Editor registration/module loads publish `editor/tools`;
   the daemon sends `tools/list_changed`. Role capability boundaries take
   precedence over sharing prompt caches across different roles.
2. What a child is told goes in its first user message, after any inherited
   history; never in system prompts or developer instructions.
3. MCP lists only the profile's allowed tools and helper profiles. The
   daemon independently validates every call, including hidden tool names.
   Depth, concurrency, candidate and collaboration checks remain enforced.
4. A handoff is fixed per turn: children started in the same turn get the same
   text, the task last.
5. A child's mode never exceeds its parent's: plan < ask < edits < auto < full.
6. Messages from other sessions carry an `:origin`: shown as `@sender` in the
   agent's color, never as the user, and they neither title nor name the
   session. Notes meant for the receiving agent (who sent it, that Emacs
   delivered it) are sent after the text but not shown (`:hidden`).
7. Only the user answers approvals.

### Lifecycle

| Backend | Not saved | Cost |
| --- | --- | --- |
| Claude | `--no-session-persistence` | no effort change while it lives (that needs `--resume`) |
| Codex | `ephemeral: true` | none |
| dsh | `parentSession` hides it from `sessions/list` | the log stays on disk |

A child without a `handle` is named after its profile at once (`@coder-flash`,
`@coder-flash-2`): the parent refers to it by that name. Closing a parent closes
its subtree, asking first while one works. The root task shares
`collab.maxActive` across active descendants and pending starts.

A delegating child remains unfinished while helper work or results remain.
After integrating them and completing, its reply reaches its direct
parent's mailbox. It closes with `collab.closeFinished`, unless the user
has it on screen or it failed.
Its reply lists what its tools did, since it can't be read afterwards. A closed
child can't be resumed: Claude and Codex children aren't saved, so "waking it
up again" would only be a new session with a summary, which is what starting
another child already is.

### Results

`session_start` returns once the child is started, and its final reply reaches
the parent through the mailbox; `session_ask` does the same between the user's
sessions. Neither waits for the reply. Both once took a `wait`, from before
there was a mailbox, but a call that waits holds up the caller's whole turn:
the user's messages queue behind it, and an agent that waited twenty minutes
for a review left the user unanswered. An agent that needs the reply before
going on ends its turn; the reply starts the next one. Only a confirmation the
user has to give is waited for (`collab.confirmTimeout`).

The mailbox and pending deliveries persist in the daemon. When a target
finishes, its clipped reply goes to the asker's mailbox. When the asker is
idle, entries arrive as one message, with a hidden origin note. A child
can finish while Emacs is disconnected and its result still reaches its
parent; the editor reattaches views by event sequence.

### Approvals and progress

A child's confirmations and questions show in its footer and, labelled
`@child`, in its parent's: answering either answers both, and closing the
child closes what it left. Only the user answers them. The parent's
`session_start` tool block carries a line on its child (status, latest tool,
tokens; `@child 已关闭` once it is gone) that opens it on click. A call doesn't say
which tool block it is, so a child takes the oldest running `session_start`
block not linked yet.

Messages from other sessions' agents, mailbox deliveries included, fold to
their first lines (`agent-session-message-head-lines`) with a button to
expand them; the user's own messages stay whole.

### Fork

`session_start` with `context: "fork"` and no profile starts a child of the
caller's own agent and settings (the daemon checks backend support), named `@<parent>-fork` when the caller gives no `handle`. Each
daemon adapter forks the child in its own process:

- Claude: `--resume <parent> --fork-session --no-session-persistence` and the
  parent's other flags.
- Codex: `thread/fork {ephemeral: true, excludeTurns: true}` in the child's
  app-server, without cwd or developer instructions, which the copied history
  carries.
- dsh: the parent's bridge flushes its log, then the child's bridge runs
  `initialize {forkFrom}`: it reads the log read-only, seeds the child from it
  and takes the route the parent last used.

The fork point is the parent's current position, including the turn in
progress; the task message explains the interrupted `session_start` call the
child sees. The child's buffer shows only its own turns.

Measured through Emacs with real configurations (MCP servers and plugins
on), a fork's first request read from cache 99% (Claude), all (dsh) and 98%
(Codex) of the parent's last prompt, and each fork answered from the
inherited conversation.

## Status

| Step | Content | State |
| --- | --- | --- |
| 0 | fork cache measurements | done |
| 1 | CLIs' own subagents off; Codex ignores other threads' notifications | done |
| 2 | parent/child links, nested session list, message origins | done |
| 3 | `session_start` fresh and handoff, profiles, caps | done |
| 4 | children not saved, closed with the parent, mailbox, `session_stop` | done |
| 5 | approvals and questions mirrored to the parent; child status in the parent's tool block; folded agent messages | done |
| 6 | fork on all three backends | done |
| 7 | children close once their reply is delivered; agent notes hidden from the transcript | done |

## Open questions

- A session-level "direct only" mode, in which the parent's agent only splits
  work, starts children and summarizes.
- A git worktree per child, for children editing the same files at once.

## References

- Claude Code: [subagents](https://code.claude.com/docs/en/sub-agents),
  [headless](https://code.claude.com/docs/en/headless),
  [hooks](https://code.claude.com/docs/en/hooks)
- Codex: [openai/codex](https://github.com/openai/codex) —
  `codex-rs/core/src/tools/handlers/multi_agents_spec.rs`,
  `codex-rs/core/src/session/session.rs`,
  `codex-rs/core/src/agent/control/spawn.rs`,
  `codex-rs/app-server/src/request_processors/thread_input.rs`
- dsh: [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) —
  READMEs of dsh-subagent, dsh-tool-subagent, dsh-subagent-fork-in-process,
  dsh-session
- opencode: [anomalyco/opencode](https://github.com/anomalyco/opencode) —
  `packages/opencode/src/tool/task.ts`
- pi: [subagent extension](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/examples/extensions/subagent),
  [pi-subagent-manager](https://pi.dev/packages/pi-subagent-manager)
- Amp: [models and subagents](https://ampcode.com/docs/models-and-subagents)
- T3 Code: [pingdotgg/t3code](https://github.com/pingdotgg/t3code) —
  `docs/orchestration-v2/`, `packages/provider-core/src/server/handoffBudget.ts`

### Internal read-only classification

`agent-ui-defmethod` accepts `:read-only t` for audited read operations.
The classification is internal policy input, not an approval or an MCP
annotation. `agent-ui-read-only-methods` returns the audited method names
for a place, including remote emx's `config_read`. `eval`, reload, writes
and executable canvas operations are not classified as read-only.
Diagnostics only reads an already open buffer (including symlink aliases);
it does not visit a file and run its hooks.

We deliberately do not emit `readOnlyHint`: Codex uses it to skip approval
in its default MCP auto mode, and Claude maps it to the tool's read-only
and concurrency properties. Audited read-only tools that remain in the
profile's tool set receive exact Claude `--allowedTools` entries and Codex
per-tool `approval_mode="approve"` overrides. The installed dsh
0.2.0-rc.2 client discards the annotation, but emitting it only for one
backend would make the policy misleading.

dsh itself asks about a tool call only when a hook or a sandbox escalation
does, so its MCP calls, `eval` included, ran unchecked in every preset. The
bridge now asks about every MCP call except the read-only methods, which
Emacs passes it (`readOnly` per server), unless the preset is Full access
or Auto: Auto's reviewer judges each call first, and in the installed
version asks the user when it denies one.

The private read-only approval set is intersected with the profile's
allowed MCP tools. Hidden tools receive no backend approval override.
Internal classification does not change a tool's published signature.
Parent-side approval delegation requires a separate, explicit decision for
each pending request; being classified as read-only is not sufficient to
approve one.
