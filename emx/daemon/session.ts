// session.ts --- session state, event replay, history and turn scheduling.

import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { backends } from '../backends/backend.ts'
import type { Backend, NewAsk, SessionHost } from '../backends/backend.ts'
import { ErrorCode } from './protocol.ts'
import { RpcError } from './rpc.ts'
import type { Answer, Ask, AttachResult, Block, Cursor, EventParams, Info,
  Capabilities, SessionEvent, SessionSummary, Settings, Status } from './protocol.ts'

export interface SessionOptions {
  creationId?: string
  id: string
  agent: string
  root: string
  info?: Info
  settings?: Settings
  resume?: string
  daemonSocket?: string
  environment?: () => Promise<NodeJS.ProcessEnv>
  agentConfig?: () => import('../config.ts').AgentConfig | undefined
  hibernateAfter?: () => number
  editorTools?: () => import('./protocol.ts').EditorTools
  restored?: boolean
  transcript?: Transcript
  onEvent?: (session: Session, event: SessionEvent) => void
  onUsage?: (session: Session, event: SessionEvent) => void
  onChange?: (summaryChanged: boolean) => void
}

export interface Transcript {
  blocks: Block[]
  queue: Message[]
  capabilities?: Capabilities
  /** Ids of user blocks showing their meta text instead of what was sent. */
  shown?: string[]
  /** Bounded provider-neutral context consumed by the next submitted message. */
  handoff?: string
}

interface Message {
  text: string
  images?: string[]
  block?: string
  /** What the transcript shows when text carries a hidden note. */
  meta?: { text: string, origin?: string }
}

export class Session implements SessionHost {
  readonly creationId?: string
  readonly id: string
  agent: string
  readonly root: string
  backend: Backend
  status: Status
  info: Info
  settings: Settings
  readonly daemonSocket: string
  readonly environment: NonNullable<SessionOptions['environment']>
  readonly agentConfig: NonNullable<SessionOptions['agentConfig']>
  readonly editorTools: () => import('./protocol.ts').EditorTools
  capabilities: Capabilities = { models: [], modes: [], commands: [] }
  blocks: Block[] = []
  readonly index = new Map<string, Block>()
  readonly asks = new Map<string, { ask: Ask, resolve: (answer: Answer) => void }>()
  queue: string[] = []
  readonly epoch = randomUUID()
  seq = 0
  readonly log: EventParams[] = []
  notify: ((event: EventParams) => void) | undefined
  #onEvent?: SessionOptions['onEvent']
  #messageMeta = new Map<string, { text: string, origin?: string }>()
  /** User blocks showing their meta text, which backend echoes keep. */
  #shown = new Set<string>()
  #onUsage?: SessionOptions['onUsage']
  #onChange: (summaryChanged: boolean) => void
  #resume: string | undefined
  #handoff?: string
  #queued: Message[] = []
  #active = false
  #prepared?: Promise<void>
  #operations: Promise<void> = Promise.resolve()
  #operationCount = 0
  #stopped = false
  #closing = false
  #hibernateAfter: () => number
  #hibernateTimer?: NodeJS.Timeout
  #pendingWork = false
  #resolveEnvironment: () => Promise<NodeJS.ProcessEnv>
  #environment?: Promise<NodeJS.ProcessEnv>

  constructor(options: SessionOptions) {
    this.creationId = options.creationId
    this.id = options.id
    this.agent = options.agent
    this.root = options.root
    this.daemonSocket = options.daemonSocket ?? ''
    this.#resolveEnvironment = options.environment ?? (async () => ({ ...process.env }))
    this.environment = () => this.#environment ??= this.#resolveEnvironment()
    this.agentConfig = options.agentConfig ?? (() => undefined)
    this.editorTools = options.editorTools ?? (() => ({ tools: [], readOnly: [] }))
    this.info = structuredClone(options.info ?? {})
    this.settings = { ...options.settings }
    this.status = options.restored ? 'idle' : 'starting'
    this.#resume = options.resume
    this.#hibernateAfter = options.hibernateAfter ?? (() => 0)
    this.#onEvent = options.onEvent
    this.#onUsage = options.onUsage
    this.#onChange = options.onChange ?? (() => {})
    if (options.transcript) {
      this.#handoff = options.transcript.handoff
      this.capabilities = structuredClone(options.transcript.capabilities ?? this.capabilities)
      this.blocks = structuredClone(options.transcript.blocks)
      for (const block of this.blocks) this.index.set(block.id, block)
      this.#queued = structuredClone(options.transcript.queue)
      this.#shown = new Set(options.transcript.shown)
      this.queue = this.#queued.map((message) => message.text)
    }
    this.backend = backends[this.agent](this)
  }

  summary(): SessionSummary {
    return { id: this.id, creationId: this.creationId, agent: this.agent, root: this.root,
      status: this.status, info: { ...structuredClone(this.info), agent: this.agent, ...(this.resumeId() ? { sessionId: this.resumeId() } : {}) } }
  }

  /** Includes asynchronous send preparation before a backend publishes running. */
  busy(): boolean {
    return this.#active || ['starting', 'running', 'disconnected'].includes(this.status)
  }

  pendingWork(): boolean { return this.backend.pendingWork?.() ?? false }

  /** Lifecycle work can still own a process even when status is idle. */
  get operating(): boolean { return this.#operationCount > 0 }

  resumeId(): string | undefined {
    return this.backend.resumeId() ?? this.#resume
  }

  /** All process ownership changes run here, including adapter preparation. */
  #operate(action: () => Promise<void>): Promise<void> {
    this.#operationCount++
    const task = this.#operations.then(() => {
      this.#environment = undefined
      return action()
    }).finally(() => { this.#operationCount--; this.#onChange(false) })
    this.#operations = task.catch(() => {})
    return task
  }

  start(): Promise<void> {
    return this.#operate(() => this.#start())
  }

  async #start(): Promise<void> {
    if (this.#stopped || this.#closing || this.backend.alive()) return
    await this.environment()
    if (this.#closing) return
    await this.backend.start(this.resumeId())
    await this.backend.configure(this.settings)
    this.#onChange(false)
    this.#drain()
    this.refreshHibernate()
  }

  /** An adapter-requested restart cannot revive an explicitly stopped session. */
  restart(): Promise<void> {
    return this.#operate(async () => {
      if (this.#stopped || this.#closing) return
      this.#resume = this.resumeId()
      await this.backend.stop()
      await this.#start()
    })
  }

  newId(prefix: string): string {
    return `${prefix}-${randomUUID()}`
  }

  /** Apply exactly once; log immutable events, independently of block state. */
  emit(input: SessionEvent): void {
    this.#onUsage?.(this, input)
    // Accounting is applied at the producer boundary, never logged or replayed.
    if (this.#onUsage && ['usage/call', 'usage/end', 'quota', 'quota/rate-limits'].includes(input.type)) return
    let event = structuredClone(input)
    if (event.type === 'block/add' && event.block.type === 'user') {
      const previous = this.index.get(event.block.id)
      const meta = this.#messageMeta.get(event.block.id)
        ?? (previous?.type === 'user' && (previous.origin || this.#shown.has(previous.id))
          ? { text: previous.text, ...(previous.origin ? { origin: previous.origin } : {}) } : undefined)
      if (meta) {
        event.block = { ...event.block, ...meta }
        this.#messageMeta.delete(event.block.id)
        this.#shown.add(event.block.id)
      }
    }
    if (event.type === 'block/add') {
      const existing = this.index.get(event.block.id)
      if (existing) {
        const fields = Object.fromEntries(Object.entries(event.block)
          .filter(([key, value]) => key !== 'id' && key !== 'type'
            && !isDeepStrictEqual((existing as unknown as Record<string, unknown>)[key], value)))
        if (!Object.keys(fields).length) return
        event = { type: 'block/update', id: existing.id, fields }
      }
    }
    if (event.type === 'block/update' && typeof event.fields.text === 'string') {
      const previous = this.index.get(event.id)
      if (previous?.type === 'user' && (previous.origin || this.#shown.has(previous.id))) event.fields.text = previous.text
    }
    // Summary.info currently includes every info key; transcript events do not.
    const summaryChanged = event.type === 'status' ? this.status !== event.status
      : event.type === 'info' && Object.entries(event.info)
        .some(([key, value]) => !isDeepStrictEqual(this.info[key], value))
    switch (event.type) {
      case 'status': this.status = event.status; break
      case 'info': this.info = { ...this.info, ...event.info }; break
      case 'capabilities': this.capabilities = event.capabilities; break
      case 'settings': this.settings = { ...this.settings, ...event.settings }; break
      case 'block/add': {
        const before = this.blocks.findIndex((block) => block.id === event.before)
        const block = structuredClone(event.block)
        this.blocks.splice(before < 0 ? this.blocks.length : before, 0, block)
        this.index.set(block.id, block)
        break
      }
      case 'block/append': {
        const block = this.index.get(event.id)
        if (block?.type === 'text' || block?.type === 'user') {
          this.#replace({ ...block, text: block.text + event.text })
        } else if (block?.type === 'tool') {
          this.#replace({ ...block, output: (block.output ?? '') + event.text })
        }
        break
      }
      case 'block/update': {
        const block = this.index.get(event.id)
        if (block) this.#replace({ ...block, ...event.fields, id: block.id, type: block.type } as Block)
        break
      }
      case 'block/remove': {
        const removed = new Set(event.ids)
        this.blocks = this.blocks.filter((block) => !removed.has(block.id))
        for (const id of removed) this.index.delete(id)
        break
      }
      case 'ask/add': {
        const pending = this.asks.get(event.ask.id)
        this.asks.set(event.ask.id, { ask: event.ask, resolve: pending?.resolve ?? (() => {}) })
        break
      }
      case 'ask/remove': this.asks.delete(event.id); break
      case 'queue': this.queue = [...event.items]; break
    }
    const logged: EventParams = { ...event, session: this.id, seq: ++this.seq }
    this.log.push(logged)
    if (this.log.length > 2000) this.log.shift()
    this.notify?.(logged)
    this.#onChange(summaryChanged)
    this.#onEvent?.(this, event)
    if (event.type === 'status' && event.status === 'idle') this.#drain()
    const pendingWork = this.pendingWork()
    const pendingChanged = pendingWork !== this.#pendingWork
    this.#pendingWork = pendingWork
    if (pendingChanged || ['status', 'ask/add', 'ask/remove'].includes(event.type)) this.refreshHibernate()
  }

  #replace(block: Block): void {
    const index = this.blocks.findIndex((item) => item.id === block.id)
    if (index >= 0) this.blocks[index] = block
    this.index.set(block.id, block)
  }

  setStatus(status: Status): void {
    if (this.status === status) return
    if (status === 'exited') this.#cancelAsks()
    this.emit({ type: 'status', status })
  }
  setInfo(info: Info): void { this.emit({ type: 'info', info }) }
  addBlock(block: Block, before?: string): void { this.emit({ type: 'block/add', block, before }) }
  append(id: string, text: string): void { this.emit({ type: 'block/append', id, text }) }
  update(id: string, fields: Partial<Record<string, unknown>>): void {
    this.emit({ type: 'block/update', id, fields })
  }
  remove(ids: string[]): void { this.emit({ type: 'block/remove', ids }) }

  ask(input: NewAsk): Promise<Answer> {
    const ask = { ...input, id: this.newId('ask') } as Ask
    return new Promise((resolve) => {
      // Register before emitting: an answer can arrive as soon as it is visible.
      this.asks.set(ask.id, { ask, resolve })
      this.emit({ type: 'ask/add', ask })
    })
  }

  answer(id: string, answer: Answer): { stale: boolean } {
    const pending = this.asks.get(id)
    if (!pending) return { stale: true }
    this.emit({ type: 'ask/remove', id, resolution: 'answered' })
    pending.resolve(answer)
    return { stale: false }
  }

  #cancelAsks(): void {
    for (const [id, pending] of this.asks) {
      this.emit({ type: 'ask/remove', id, resolution: 'cancelled' })
      pending.resolve({})
    }
  }

  sendMessage(text: string, origin: string, hidden: string, block = this.newId('user')): void {
    this.send(text + (hidden ? '\n\n' + hidden : ''), undefined, block, { text, origin })
  }

  send(text: string, images?: string[], block?: string, meta?: Message['meta']): { queued: boolean } {
    if (this.#stopped || this.#closing) throw new RpcError(ErrorCode.NoSession, "Session is closed")
    const message = { text, images, block, meta }
    if (this.#active || this.status === 'running') {
      this.#queued.push(message)
      this.emit({ type: 'queue', items: this.#queued.map((item) => item.text) })
      return { queued: true }
    }
    void this.#run(message)
    return { queued: false }
  }

  async #run(message: Message): Promise<void> {
    clearTimeout(this.#hibernateTimer)
    this.#active = true
    if (message.block && message.meta) this.#messageMeta.set(message.block, message.meta)
    try {
      // Adapters return after submission, never after a complete model turn.
      const prepared = this.#operate(async () => {
        if (this.#stopped || this.#closing) return
        try {
          await this.#start()
          if (this.#closing) return
          await this.backend.prepare?.()
          if (this.#closing) return
          const handoff = this.#handoff
          const block = message.block ?? (handoff ? this.newId('user') : undefined)
          if (handoff && block) this.#messageMeta.set(block, message.meta ?? { text: message.text })
          await this.backend.send(handoff ? handoff + '\n\nCurrent request:\n' + message.text : message.text, message.images, block)
          this.#handoff = undefined
        } catch (error) {
          this.#cancelAsks()
          this.setStatus('exited')
          throw error
        }
      })
      this.#prepared = prepared
      await prepared
    } catch (error) {
      if (this.#stopped || this.#closing) return
      this.addBlock({ id: this.newId('notice'), type: 'notice', notice: {
        kind: 'backend-error', level: 'error', args: { message: String(error) } } })
    } finally {
      this.#prepared = undefined
      this.#active = false
      this.#drain()
      this.refreshHibernate()
    }
  }

  #drain(): void {
    if (this.#closing || this.#active || this.status !== 'idle' || !this.#queued.length) return
    const message = this.#queued.shift()!
    this.emit({ type: 'queue', items: this.#queued.map((item) => item.text) })
    void this.#run(message)
  }

  steer(text: string, images?: string[], block?: string): boolean {
    if (this.#closing) return false
    if (this.#prepared && this.backend.steerWhilePreparing) {
      void this.#prepared.then(() => {
        if (!this.#stopped && !this.#closing) this.backend.steer(text, images, block)
      }).catch(() => {})
      return true
    }
    return this.backend.steer(text, images, block)
  }

  interrupt(): void {
    this.#cancelAsks()
    if (this.#prepared) {
      void this.#prepared.then(() => {
        if (!this.#stopped && !this.#closing) { this.#cancelAsks(); this.backend.interrupt() }
      }).catch(() => {})
    } else this.backend.interrupt()
  }

  configure(settings: Settings): Promise<void> {
    return this.#operate(async () => {
      if (this.#stopped || this.#closing) return
      this.backend.validateSettings?.({ ...this.settings, ...settings })
      this.emit({ type: 'settings', settings })
      if (this.backend.alive()) await this.backend.configure(this.settings)
    })
  }

  /** Switch only between turns; retain the editor transcript and provider history. */
  select(agent: string, settings: Settings, profile: string, handoffLimit: number,
    ready: () => boolean): Promise<void> {
    if (this.busy() || this.operating || this.asks.size || this.queue.length || this.pendingWork() || !ready()) {
      return Promise.reject(new RpcError(ErrorCode.InvalidParams, 'Finish pending work before changing profile or provider'))
    }
    return this.#operate(async () => {
      if (this.#stopped || this.#closing) throw new RpcError(ErrorCode.NoSession, 'Session is closed')
      if (this.busy() || this.asks.size || this.queue.length || this.pendingWork() || !ready()) {
        throw new RpcError(ErrorCode.InvalidParams, 'Finish pending work before changing profile or provider')
      }
      const oldAgent = this.agent, resume = this.resumeId()
      const oldInfo = structuredClone(this.info), oldSettings = { ...this.settings }, oldBackend = this.backend
      const oldHandoff = this.#handoff, oldCapabilities = structuredClone(this.capabilities)
      const oldStatus = this.status, wasAlive = oldBackend.alive()
      const sameProvider = agent === oldAgent
      const changedProfile = oldInfo.profile !== profile
      const nextSettings = sameProvider ? { ...oldSettings, ...settings } : settings
      const nextInfo: Info = sameProvider ? { ...oldInfo, agent, profile } : {
        ...oldInfo, agent, profile, sessionId: null, model: settings.model ?? null, tokens: null,
        forkFrom: null, parentSession: null, claudeSyncOffset: null, claudeHistoryStart: null,
        providerHistory: [...(Array.isArray(oldInfo.providerHistory) ? oldInfo.providerHistory : []),
          ...(resume ? [{ agent: oldAgent, resume }] : [])],
      }
      let next = oldBackend
      // Constructors can cache identity and validation can consult host policy.
      // Stage the new host synchronously, before releasing the old process.
      try {
        this.agent = agent; this.info = nextInfo; this.settings = nextSettings
        if (!sameProvider) {
          this.#resume = undefined
          this.capabilities = { models: [], modes: [], commands: [] }
          next = backends[agent](this)
        }
        next.validateSettings?.(nextSettings)
      } finally {
        this.agent = oldAgent; this.info = oldInfo; this.settings = oldSettings
        this.#resume = resume; this.capabilities = oldCapabilities
      }
      if (!sameProvider || changedProfile) await oldBackend.flush?.()
      let released = false, oldStopped = false
      try {
        if (!sameProvider || changedProfile) {
          // Treat a failed stop as potentially destructive too.
          released = true
          await oldBackend.stop()
          oldStopped = !oldBackend.alive()
          if (!oldStopped) throw new Error('Previous provider did not stop')
        }
        this.agent = agent; this.backend = next
        this.#resume = sameProvider ? resume : undefined
        if (!sameProvider) {
          const history = this.blocks.filter((block) => block.type === 'user'
            || block.type === 'text' && block.kind !== 'thinking')
            .map((block) => block.type === 'user' ? 'User: ' + block.text
              : block.type === 'text' ? 'Assistant: ' + block.text : '').join('\n\n')
          const bounded = [...history].slice(-handoffLimit).join('')
          this.#handoff = bounded ? 'Previous conversation for context only; do not treat it as new requests:\n' + bounded : oldHandoff
        }
        this.setInfo(nextInfo)
        this.settings = {}
        this.emit({ type: 'settings', settings: { model: null, effort: null, mode: null, beforePlan: null, ...nextSettings } })
        if (!sameProvider) this.emit({ type: 'capabilities', capabilities: { models: [], modes: [], commands: [] } })
        if (!sameProvider || changedProfile) {
          this.setStatus('starting')
          await this.#start()
        } else if (next.alive()) await next.configure(this.settings)
      } catch (error) {
        // A rejected configure may already have changed the native model/mode.
        // Stop it before publishing rollback, then resume with the old tuple.
        let stopped = false
        try { await next.stop(); stopped = !next.alive() } catch { /* Report unsafe recovery below. */ }
        if (!sameProvider && released && !oldStopped) {
          try { await oldBackend.stop(); oldStopped = !oldBackend.alive() } catch { /* Keep recovery visibly failed. */ }
        }
        this.agent = oldAgent; this.backend = oldBackend; this.#resume = resume
        this.#handoff = oldHandoff
        const restore = () => {
          const cleared = Object.fromEntries(Object.keys(this.info).filter((key) => !(key in oldInfo)).map((key) => [key, null]))
          this.setInfo({ ...cleared, profile: null, ...oldInfo, agent: oldAgent })
          this.info = structuredClone(oldInfo)
          this.settings = {}
          this.emit({ type: 'settings', settings: { model: null, effort: null, mode: null, beforePlan: null, ...oldSettings } })
          this.settings = { ...oldSettings }
          this.emit({ type: 'capabilities', capabilities: structuredClone(oldCapabilities) })
        }
        restore()
        if (sameProvider && wasAlive && stopped) {
          try {
            await this.#start()
          } catch (recovery) {
            try { await oldBackend.stop() } catch { /* Recovery already failed. */ }
            restore()
            this.setStatus('exited')
            throw new AggregateError([error, recovery], 'Selection failed and native settings could not be restored')
          }
        } else this.setStatus(stopped && (sameProvider || oldStopped) ? oldStatus : 'exited')
        if (!stopped) this.setStatus('exited')
        throw error
      }
    })
  }

  /** Revoke input immediately, before serialized teardown can await a process. */
  beginClose(): void {
    this.#closing = true
    clearTimeout(this.#hibernateTimer)
    this.#queued = []
    if (this.queue.length) this.emit({ type: 'queue', items: [] })
    this.#cancelAsks()
  }

  stop(): Promise<void> {
    return this.#operate(async () => {
      if (this.#stopped) return
      // Tree closure revokes eagerly; ordinary stops retain operation order.
      this.beginClose()
      this.#stopped = true
      clearTimeout(this.#hibernateTimer)
      this.#resume = this.resumeId()
      this.#queued = []
      if (this.queue.length) this.emit({ type: 'queue', items: [] })
      this.#cancelAsks()
      try { await this.backend.stop() } finally { this.setStatus('exited') }
    })
  }

  /** Release only an idle process; keep the session resumable. */
  hibernate(): Promise<void> {
    return this.#operate(async () => {
      if (this.#stopped || this.#closing || this.info.parent || this.#active || this.asks.size
        || this.pendingWork() || this.status !== 'idle' || !this.backend.alive()) return
      clearTimeout(this.#hibernateTimer)
      this.#resume = this.resumeId()
      await this.backend.stop()
      this.#onChange(true)
    })
  }

  refreshHibernate(): void {
    clearTimeout(this.#hibernateTimer)
    const seconds = this.#hibernateAfter()
    if (!seconds || this.#stopped || this.#closing || this.info.parent || this.#active || this.asks.size
      || this.pendingWork() || this.status !== 'idle' || !this.backend.alive()) return
    this.#hibernateTimer = setTimeout(() => {
      void this.hibernate().catch((error) => this.addBlock({
        id: this.newId('notice'), type: 'notice', notice: {
          kind: 'backend-error', level: 'error', args: { message: String(error) } } }))
    }, seconds * 1000)
    this.#hibernateTimer.unref()
  }

  detach(): void { this.notify = undefined }

  transcript(): Transcript {
    return structuredClone({ blocks: this.blocks, queue: this.#queued, capabilities: this.capabilities,
      shown: [...this.#shown], handoff: this.#handoff })
  }

  attach(after?: Cursor, turns = 20): { result: AttachResult, afterWrite: () => void } {
    const replay = after !== undefined && after.epoch === this.epoch
      && after.seq >= 0 && after.seq <= this.seq
      && (after.seq === this.seq || (this.log[0]?.seq ?? Infinity) <= after.seq + 1)
    const events = replay ? this.log.filter((event) => event.seq > after!.seq) : []
    const blocks = replay ? [] : this.#lastTurns(this.blocks.length, turns)
    const earlier = !replay && (blocks.length < this.blocks.length || !!this.backend.hasEarlier?.())
    const result: AttachResult = { epoch: this.epoch, seq: this.seq, replay: replay ? 'events' : 'fresh',
      status: this.status, info: { ...structuredClone(this.info), agent: this.agent, ...(this.resumeId() ? { sessionId: this.resumeId() } : {}) }, settings: { ...this.settings },
      queue: [...this.queue], asks: [...this.asks.values()].map(({ ask }) => structuredClone(ask)),
      earlier, capabilities: structuredClone(this.capabilities) }
    return { result, afterWrite: () => {
      for (const event of events) this.notify?.(event)
      if (!replay) {
        for (const block of blocks) this.#history(block, result.seq)
        this.#historyDone(earlier, result.seq)
        this.backend.reattached?.()
      }
    } }
  }

  #lastTurns(end: number, turns: number): Block[] {
    if (turns <= 0) return []
    let remaining = turns
    let start = end
    while (start > 0) {
      start--
      if (this.blocks[start].type === 'user' && --remaining === 0) break
    }
    // Include any preamble when all turns have been selected.
    if (!this.blocks.slice(0, start).some((block) => block.type === 'user')) start = 0
    return structuredClone(this.blocks.slice(start, end))
  }

  #history(block: Block, seq: number, before?: string): void {
    this.notify?.({ type: 'block/add', block, before, history: true, session: this.id, seq })
  }

  #historyDone(earlier: boolean, seq: number): void {
    this.notify?.({ type: 'history/done', earlier, session: this.id, seq })
  }

  async earlier(before: string, turns = 20): Promise<{ earlier: boolean }> {
    let end = this.blocks.findIndex((block) => block.id === before)
    if (end < 0) throw new RpcError(ErrorCode.InvalidParams, `Unknown history block: ${before}`)
    const loaded = this.blocks.slice(0, end).filter((block) => block.type === 'user').length
    if (loaded < turns && this.backend.hasEarlier?.()) {
      const beforeFirst = this.blocks[0]?.id
      for (const block of await this.backend.loadEarlier?.(turns - loaded) ?? []) {
        this.emit({ type: 'block/add', block, before: beforeFirst, history: true })
      }
      end = this.blocks.findIndex((block) => block.id === before)
    }
    const blocks = this.#lastTurns(end, turns)
    const earlier = blocks.length < end || !!this.backend.hasEarlier?.()
    for (const block of blocks) this.#history(block, this.seq, before)
    this.#historyDone(earlier, this.seq)
    return { earlier }
  }
}
