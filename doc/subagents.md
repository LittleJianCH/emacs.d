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
| Only the final text comes back, clipped | all | `agent-collab-text-limit` |
| Background results wake the parent; it never polls | Claude Code, opencode, pi-subagent-manager, T3 | the mailbox |
| Several results wake it once | pi-subagent-manager, T3 | one message per idle transition |
| Approvals go to the user, never to an agent; a waiting parent returns when a child waits for the user | T3, Claude Code, opencode | yes |
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

## Design

### Two kinds of sessions, three kinds of context

- Sessions the user opened are saved and resumable. They read each other with
  `session_read` and ask each other with `session_ask`; conversations happen
  here.
- Child sessions are started by an agent with `session_start`. A child does
  one task and reports its final reply. It takes no messages from agents, asks
  no one and starts no sessions. It lives with its buffer and its parent. The
  user can still type in it.

| Context | The child gets | Harness and model | Cache | Use it when |
| --- | --- | --- | --- | --- |
| fresh | the task only | the profile's | builds its own | the task stands alone |
| handoff | Emacs's text of the parent's conversation, then the task | the profile's | none from the parent; siblings started in one turn share a prefix | the task needs context but a cheaper model can do it |
| fork | the parent's own messages, then the task | the parent's; no profile | reuses the parent's cache; output at the parent's price | the task needs the parent's own level of reasoning |

A handoff keeps, within `agent-collab-handoff-limit` characters, the latest
turn (cut from the front if need be), the first user message, then the turns
between, newest first, noting what was left out.

### Tools

| Method | Does | Who |
| --- | --- | --- |
| `sessions` | lists open sessions with parent and children | anyone |
| `session_read` | latest turns of a session, paged | anyone |
| `session_ask` | asks an idle session; the reply goes to the mailbox | between sessions the user opened |
| `session_start` | starts a child: `profile`, `context`, `prompt`, `handle`, `title` | sessions the user opened |
| `session_stop` | stops and closes a child | its parent |

### Profiles

The model picks a profile, not a free harness and model pair: harness and model
don't combine freely, model lists come from running processes, and a profile
carries the permission mode, cost and confirmation the user set.
`agent-collab-profiles` defaults to `coder-flash` (dsh, DeepSeek flash, auto),
`explorer` (Claude haiku, plan), `coder` (Codex gpt-6.1-sol, auto), `reviewer`
(Codex gpt-6-astra, plan), `generalist` (Claude Opus, auto) and `expert`
(Claude Fable, plan, confirmed by the user each time: a fork only reaches the
parent's own model); the tool description lists those whose agent is enabled
and installed where the caller runs: children start where their parent runs, so
an agent on this machine sees the agents installed here and one in a `/rpc:dev:`
project those of that project on dev (per project, since tramp-rpc applies its
direnv). A remote project's programs are looked up in one round trip (`command
-v`) as a session opens there, so installing an agent shows once a session opens
there again; the timer never makes round trips, and an unreachable host isn't
asked again for 5 minutes. A child that fails to start anyway is closed (only
that one, found by a token in its info: others may open while it waits for the
host) and the error returned.

The caller names a child after its task (`handle`, such as `cgu-measure`); it
knows the task best and needs no model call to do it. Without one the child is
named after its profile. An agent
never picks a profile of its own agent and model: it forks instead, getting the
same model with its context and prompt cache.
The description also carries `agent-collab-start-guidance`, on when to start
a session at all: investigations to explorer, specified code and long runs to
the coders, reasoning on the caller's context to a fork, a review before
committing, independent pieces at once; doing it yourself when explaining
would take longer than the work; telling the user the profile and why.
Without it agents rarely delegated even when a profile fitted. With only "fork
when it needs your context", an agent forked an hour of builds and
measurements: needing context rarely means needing it unwritten, since the
caller can write the spec and the scripts, then hand the execution to a cheap
profile. It also decided several tasks at once instead of each on its own.
Costs come in five tiers, minimal, low, medium, high and premium, so the most
expensive models stand apart: DeepSeek flash is minimal, Haiku low, Codex's
gpt-6.1-sol medium, its frontier model and Opus high, and Fable premium.

### Rules

1. An agent's tools and their descriptions depend on the configuration and
   where the agent runs, never otherwise on the calling session
   (`agent-ui-description-functions`): a fork runs where its parent does. A
   test compares the parent's and the child's `describe` output. Each place has
   its own stamp file, so installing an agent in one doesn't refresh (and cost
   the prompt cache of) sessions elsewhere. Remote sessions whose emx started
   before per-place stamps watch this machine's stamp until they restart.
   When Emacs's tools change (a reload, a changed profile), live sessions are
   told: emx sends `tools/list_changed` (Claude and dsh list again; Codex
   ignores it, so a saved Codex thread resumes in a new process before its
   next send). Every session, a fork's parent included, then sees the new
   tools, so forks keep matching. A Codex child never refreshes: its thread
   isn't saved, and it closes after one task anyway.
2. What a child is told goes in its first user message, after any inherited
   history; never in system prompts or developer instructions.
3. Refusals (depth, concurrency, profile, children asking) happen at call time;
   the tools stay listed.
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

A child is named after its profile at once (`@coder-flash`, `@coder-flash-2`):
the parent refers to it by that name. Closing a parent closes its children,
asking first while one works. At most `agent-collab-max-active` children of a
session work at once.

A child closes once its final reply has reached its parent's mailbox
(`agent-collab-close-finished`), unless the user has it on screen or it failed.
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
user has to give is waited for (`agent-collab-confirm-timeout`).

The mailbox lives in Emacs memory: children don't outlive Emacs. Each asked-for
reply is tracked with its target, message and asker. When the target goes
idle, exits or is closed, the clipped reply goes to
the asker's mailbox; when the asker is idle, everything in it is sent as one
message, with a hidden note that Emacs delivered it and the user didn't write
it.

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
caller's own agent and settings (`agent-session-backend-fork-p` says which
backends can), named `@<parent>-fork`. Each backend forks in Emacs, the child
in its own process like any other child:

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
