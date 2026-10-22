// protocol.ts --- the wire contract between Emacs and the emx daemon.
//
// JSON-RPC 2.0, one JSON object per line, both directions over the
// daemon's Unix socket (see doc/emx-daemon.md).  Emacs is the only client
// that opens sessions; agents' `emx mcp` processes connect only to run
// tools.
//
// Everything here is data: the daemon never sends UI prose.  Notices and
// labels carry a kind that Emacs maps to its own (Chinese) text; agent
// text (replies, tool output, questions an agent asks) is passed through.

import type { ReportParams, UsageRecord, QuotaReading } from '../usage/types.ts'
import type { UsageConfig, UsageService } from '../usage/service.ts'

/** A session's id, assigned by the daemon. */
export type SessionId = string

/** Durable idempotency key; terminal records are retained for 30 days. */
export interface CreationRecord {
  id: SessionId
  state: 'opening' | 'open' | 'failed' | 'closed'
  updated: number
  error?: string
}

export type Status = 'starting' | 'idle' | 'running' | 'disconnected' | 'exited'

/** The user's choices for a session; null means the agent's default. */
export interface Settings {
  model?: string | null
  effort?: string | null
  mode?: string | null
  /** Permission mode retained while plan mode is active, including on resume. */
  beforePlan?: string | null
}

/**
 * What the header line shows and what other code reads about a session:
 * model, tokens, title, handle, parent, profile...  Open-ended; `info`
 * events carry only the keys that changed.
 */
export type Info = Record<string, unknown>

// ---------------------------------------------------------------- Blocks

export type ToolKind =
  | 'command' | 'read' | 'edit' | 'search' | 'web' | 'task'
  | 'question' | 'plan' | 'mcp' | 'other'

export type ToolStatus = 'running' | 'done' | 'error' | 'declined'

/** How a tool call is shown, normalized by the backend adapter. */
export interface ToolView {
  kind: ToolKind
  /** The tool's own name, as the agent called it. */
  name: string
  /** A short description: a command line, a path, a query. */
  title: string
  command?: string
  path?: string
  /** Unified diff text of an edit. */
  diff?: string
  /** Plan entries (kind plan). */
  items?: { text: string, status: 'pending' | 'active' | 'done' }[]
}

/** A notice the daemon wants shown; Emacs words it from kind and args. */
export interface Notice {
  kind: string
  level?: 'info' | 'warning' | 'error'
  args?: Record<string, string | number | boolean>
}

export type Block =
  | { id: string, type: 'user', text: string, images?: string[],
      /** Number of historical images when the original paths are unavailable. */
      imageCount?: number, origin?: string }
  | { id: string, type: 'text', kind: 'assistant' | 'thinking', text: string, done: boolean }
  | { id: string, type: 'tool', view: ToolView, status: ToolStatus, output?: string }
  | { id: string, type: 'notice', notice: Notice }

// ---------------------------------------------------------------- Asks

/** One answer the user can pick for an approval; Emacs labels it by id. */
export type ChoiceId = 'allow' | 'always' | 'deny'

export interface Question {
  question: string
  header?: string
  detail?: string
  options?: { label: string, description?: string }[]
  multi?: boolean
  other?: boolean
  secret?: boolean
  range?: [number, number, string]
  /** Backend question semantics, e.g. {kind: "plan-review", approve: label}. */
  intent?: Record<string, unknown>
}

export type Ask =
  | {
      id: string, type: 'approval',
      /** The tool block it is about, if any. */
      tool?: string,
      view?: ToolView,
      /** The agent's own description of the request, passed through. */
      description?: string,
      choices: ChoiceId[],
    }
  | { id: string, type: 'question', tool?: string, questions: Question[] }

export interface Answer {
  /** For an approval. */
  choice?: ChoiceId
  /** For questions: one entry per question, in order. */
  answers?: { selected: string[], custom?: string }[]
}

// ---------------------------------------------------------------- Requests (Emacs -> daemon)

export interface HelloParams {
  client: string
  /** Hash of the client's copy of the emx sources. */
  version: string
  agents?: string[]
  config?: import('../config.ts').Config
  tools?: EditorTools
}
export interface HelloResult {
  sessions?: SessionSummary[]
  config?: import('../config.ts').Config
  capabilities?: { usage: number, stopIfIdle?: number, restart?: number }
  liveAgents?: number
  daemon: number
  /** Hash of the emx sources the daemon runs. */
  version: string
}

export interface SessionSummary {
  creationId?: string
  id: SessionId
  agent: string
  root: string
  status: Status
  info: Info
}

/** MCP definitions and an internal permission classification, never model hints. */
export interface EditorTools {
  tools: { name: string, description: string, inputSchema: Record<string, unknown> }[]
  readOnly: string[]
}

/** Daemon requests sent to the attached editor. Results use agent-ui's envelope. */
export interface EditorCall {
  method: string
  params: Record<string, unknown>
  caller: { session: SessionId, root: string, place: null }
}

/** Choices advertised by the backend, in its native ordering. */
export interface Capabilities {
  models: { id: string, name: string, description?: string,
    efforts?: string[], defaultEffort?: string }[]
  modes: string[]
  commands: { name: string, description?: string, hint?: string }[]
}

/** One model call's counters; input excludes cached tokens. */
export interface Usage {
  input: number
  cacheRead: number
  cacheWrite: number
  output: number
}

export interface SkillsContext { skillsDir?: string, supersededSkills?: string[] }

export interface OpenParams {
  /** Client identity reused when an open reply is lost. */
  creationId?: string
  /** Backend-neutral editor context, inherited by every child. */
  skills?: SkillsContext
  handle?: string
  agent: string
  root: string
  settings?: Settings
  /** A session to resume, in the agent's own terms. */
  resume?: string
  /** A session to fork. */
  fork?: SessionId
  /** The session whose agent starts this one. */
  parent?: SessionId
}

/**
 * A client's place in a session: the epoch of the daemon's event log it
 * read and the last seq it applied.  A log starts a new epoch when the
 * session is created or restored by another daemon process, and seqs
 * restart then: a seq means nothing without its epoch.
 */
export interface Cursor {
  epoch: string
  seq: number
}

export interface AttachParams {
  id: SessionId
  /** Where the client is; omitted for a fresh view. */
  after?: Cursor
  /** Turns to send for a fresh view (default 20); the rest come with session/earlier. */
  turns?: number
}

/**
 * The state of a session, without its transcript.  `replay` says what
 * follows: `events` when every event after the client's cursor is still
 * in the log (same epoch), which are then replayed in order; `fresh`
 * otherwise, when the client must clear its view and take the history
 * blocks that follow, closed by `history/done`.
 *
 * A fresh transfer is complete only at its `history/done`.  A client
 * whose connection drops before then has a partial view: it must not
 * keep the new cursor, and attaches fresh again.
 */
export interface AttachResult {
  epoch: string
  seq: number
  replay: 'events' | 'fresh'
  status: Status
  info: Info
  settings: Settings
  queue: string[]
  asks: Ask[]
  /** The backend choices in effect at this snapshot. */
  capabilities: Capabilities
  /**
   * Whether turns before the ones sent remain (session/earlier).  Only
   * meaningful for a fresh view: after a replay of events the client's
   * view starts where it did, and it keeps what it knew.
   */
  earlier: boolean
}

/**
 * Earlier turns: the `turns` turns (default 20) before block `before`,
 * the first block the client shows.  They arrive as history blocks with
 * `before` set, closed by `history/done`.  The daemon keeps no paging
 * state: a request lost with the connection is simply made again.
 */
export interface EarlierParams {
  id: SessionId
  before: string
  turns?: number
}

/**
 * A user message.  `block` is the id of the block Emacs already shows for
 * it: the daemon's user block takes that id, so Emacs recognizes it.
 */
export interface SendParams {
  /** Editor handle retained for ledger records, updated before a live turn. */
  handle?: string
  id: SessionId
  text: string
  images?: string[]
  block?: string
}

/** Config-order catalog, including disabled profiles and candidates. */
export interface CollabProfiles {
  quotaSkip: number
  profiles: {
    name: string
    cost: string
    description: string
    disabled: boolean
    overridden: boolean
    candidates: {
      agent: string
      /** Null when the backend's default model is requested. */
      model: string | null
      effort?: string
      mode?: string
      disabled: boolean
      /** All matching policy entries, including the bare profile entry. */
      disabledBy: string[]
      /** Runtime availability, independent of the disabled flag. */
      available: boolean
      unavailable?: string
      strained?: string
      quotaSkip: number
    }[]
  }[]
}

export interface Requests {
  'config/push': [{ config: import('../config.ts').Config }, { config: import('../config.ts').Config, errors: string[] }]
  'config/call': [{ method: string, arguments: Record<string, unknown> }, string]
  'usage/ack': [{ source: string, sequence: number }, {}]
  /** Whether a daemon answers, and which: never takes over (see hello). */
  'ping': [{}, HelloResult]
  /** Makes this connection the daemon's Emacs; a previous one gets `replaced`. */
  'hello': [HelloParams, HelloResult]
  'mcp/hello': [{ session: SessionId }, { remote: boolean, instructions: string }]
  'mcp/tools': [{}, { tools: EditorTools['tools'] }]
  'mcp/call': [{ name: string, arguments?: Record<string, unknown> }, unknown]
  'config/get': [{}, { config: import('../config.ts').Config, errors: string[] }]
  'config/set': [{ path: string[], value: unknown }, { config: import('../config.ts').Config }]
  'config/reload': [{}, { config: import('../config.ts').Config, errors: string[] }]
  'sessions/history': [{ agent: string, root: string }, { items: import('../backends/history.ts').HistoryItem[] }]
  'agents/models': [{ agent: string }, { models: { id: string, label?: string }[] }]
  /** Private editor hub methods; MCP peers cannot call these directly. */
  'collab/list': [{}, { sessions: object[] }]
  'collab/profiles': [{ root?: string }, CollabProfiles]
  'collab/disable': [{ profile: string, candidate?: number, disabled: boolean }, { config: import('../config.ts').Config }]
  'collab/read': [{ id: string, last?: number, before?: number, tools?: string }, string]
  'collab/ask': [{ id: string, prompt: string, route: import('./collab.ts').RemoteRoute,
    origin: { handle: string, agent: string } }, string]
  'collab/deliver': [{ id: string, route: import('./collab.ts').RemoteRoute,
    mail: { handle: string, text: string } }, {}]
  'collab/retry': [{}, {}]
  'sessions/list': [{ root?: string }, { sessions: SessionSummary[] }]
  'session/open': [OpenParams, { id: SessionId }]
  /** Cancel an uncertain open, including one whose reply was lost. */
  'session/cancel': [{ creationId: string }, {}]
  'session/attach': [AttachParams, AttachResult]
  'session/detach': [{ id: SessionId }, {}]
  'session/send': [SendParams, { queued: boolean }]
  'session/steer': [SendParams, { accepted: boolean }]
  'session/interrupt': [{ id: SessionId }, {}]
  'session/context': [{ id: SessionId, skills: SkillsContext }, {}]
  'session/configure': [{ id: SessionId } & Settings, {}]
  'session/answer': [{ id: SessionId, ask: string } & Answer, { stale: boolean }]
  'session/earlier': [EarlierParams, { earlier: boolean }]
  'session/stop': [{ id: SessionId }, {}]
  'usage/hello': [{}, HelloResult]
  'usage/record': [{id: string, source: string, sequence: number, record: Partial<UsageRecord>}, {id: string, source: string, sequence: number}]
  'usage/quota': [{id: string, source: string, sequence: number, reading: QuotaReading}, {id: string, source: string, sequence: number}]
  'usage/configure': [Partial<Pick<UsageConfig, 'agents' | 'pollInterval' | 'pollers'>>, ReturnType<UsageService['configure']>]
  'usage/report': [ReportParams, ReturnType<UsageService['report']>]
  'usage/refresh': [{force?: boolean}, {}]
  'usage/clear': [{}, {}]
  'daemon/restart': [{ version: string, runtime: string },
    { status: 'up_to_date' | 'restarted' | 'restart_scheduled', version: string,
      waiting?: { session?: string, reason: string }[] }]
  'daemon/stop': [{ ifIdle?: boolean, idleOnly?: boolean }, { stopped?: boolean }]
}

export type Method = keyof Requests
export type Params<M extends Method> = Requests[M][0]
export type Result<M extends Method> = Requests[M][1]

// ---------------------------------------------------------------- Events (daemon -> Emacs)

/**
 * Events of one session, sent as notifications whose method is the
 * event's type and whose params carry `session` and `seq`.  seq grows by
 * one per event of a session; blocks sent for a fresh attach or for
 * session/earlier carry the seq they were sent at and `history: true`,
 * and don't advance it, nor does the `history/done` that closes them.
 */
export type SessionEvent =
  | { type: 'status', status: Status }
  | { type: 'info', info: Info }
  | { type: 'settings', settings: Settings }
  /** Full replacement of the backend's available choices. */
  | { type: 'capabilities', capabilities: Capabilities }
  /** Live model calls only; resumed transcript usage is excluded. */
  | { type: 'usage/call', model: string, usage: Usage }
  /** Internal backend event: flush the turn to the daemon's usage ledger. */
  | { type: 'usage/end' }
  /** Internal account balance reading, consumed by daemon accounting. */
  | { type: 'quota', balance: { amount: number, currency: string }[] }
  /** Sparse Codex account readings; missing credits retain the known value. */
  | { type: 'quota/rate-limits', rateLimits: { plan?: string,
      windows: { id: string, minutes: number | null, used: number, resets: number | null }[],
      credits?: number | 'unlimited' } }
  /** A new block, at the end, or before the block `before`. */
  | { type: 'block/add', block: Block, before?: string, history?: boolean }
  /** Streamed text of a text block, or output of a tool block. */
  | { type: 'block/append', id: string, text: string }
  /** Changed fields of a block (a text block's final text, a tool's result). */
  | { type: 'block/update', id: string, fields: Partial<Record<string, unknown>> }
  | { type: 'block/remove', ids: string[] }
  | { type: 'ask/add', ask: Ask }
  | { type: 'ask/remove', id: string, resolution: 'answered' | 'cancelled' }
  | { type: 'queue', items: string[] }
  /** The end of the history blocks of a fresh attach or of session/earlier. */
  | { type: 'history/done', earlier: boolean }

export type EventParams = SessionEvent & { session: SessionId, seq: number }

/** Notifications that are not about one session. */
export interface DaemonNotifications {
  /** Effective file policy, also delivered on usage-only connections. */
  'config': { config: import('../config.ts').Config, errors: string[] }
  /** The daemon stopped a child or an explicitly closed session. */
  'collab/closed': { id: SessionId }
  /** Another Emacs said hello; this connection no longer gets events. */
  'replaced': {}
  'daemon/restarting': { version: string }
  'daemon/restart-failed': { error: string }
  /** Sent only to MCP connections. */
  'mcp/tools_changed': {}
  /** A visible report should be refetched after ledger writes or clear. */
  'usage/changed': {}
  'usage/quotas': {quotas: ReturnType<UsageService['configure']>['quotas']}
  /** The session list changed (opened, stopped, status). */
  'sessions': { sessions: SessionSummary[] }
}

// ---------------------------------------------------------------- Errors

export const ErrorCode = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  Internal: -32603,
  /** No such session. */
  NoSession: 1,
  /** The connection was replaced by another Emacs. */
  NotClient: 2,
} as const

/** Editor notifications reuse hello's tools payload. */
export interface EditorNotifications {
  'editor/tools': EditorTools
  'usage/record': {record: UsageRecord}
  'usage/quota': QuotaReading
}
/** MCP cancellation references the socket request id, as in MCP stdio. */
export interface McpNotifications { 'notifications/cancelled': { requestId: number } }
export interface EditorRequests { 'editor/call': [EditorCall, {
  ok: boolean, result?: unknown, pending?: string, error?: string
}] }
