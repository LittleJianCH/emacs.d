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
  id: string
  agent: string
  root: string
  info?: Info
  settings?: Settings
  resume?: string
  daemonSocket?: string
  editorTools?: () => import('./protocol.ts').EditorTools
  restored?: boolean
  transcript?: Transcript
  onChange?: (summaryChanged: boolean) => void
}

export interface Transcript {
  blocks: Block[]
  queue: Message[]
  capabilities?: Capabilities
}

interface Message {
  text: string
  images?: string[]
  block?: string
}

export class Session implements SessionHost {
  readonly id: string
  readonly agent: string
  readonly root: string
  readonly backend: Backend
  status: Status
  info: Info
  settings: Settings
  readonly daemonSocket: string
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
  #onChange: (summaryChanged: boolean) => void
  #resume: string | undefined
  #queued: Message[] = []
  #active = false
  #generation = 0

  constructor(options: SessionOptions) {
    this.id = options.id
    this.agent = options.agent
    this.root = options.root
    this.daemonSocket = options.daemonSocket ?? ''
    this.editorTools = options.editorTools ?? (() => ({ tools: [], readOnly: [] }))
    this.info = structuredClone(options.info ?? {})
    this.settings = { ...options.settings }
    this.status = options.restored ? 'idle' : 'starting'
    this.#resume = options.resume
    this.#onChange = options.onChange ?? (() => {})
    if (options.transcript) {
      this.capabilities = structuredClone(options.transcript.capabilities ?? this.capabilities)
      this.blocks = structuredClone(options.transcript.blocks)
      for (const block of this.blocks) this.index.set(block.id, block)
      this.#queued = structuredClone(options.transcript.queue)
      this.queue = this.#queued.map((message) => message.text)
    }
    this.backend = backends[this.agent](this)
  }

  summary(): SessionSummary {
    return { id: this.id, agent: this.agent, root: this.root,
      status: this.status, info: structuredClone(this.info) }
  }

  resumeId(): string | undefined {
    return this.backend.resumeId() ?? this.#resume
  }

  async start(): Promise<void> {
    await this.backend.start(this.resumeId())
    await this.backend.configure(this.settings)
    this.#onChange(false)
  }

  newId(prefix: string): string {
    return `${prefix}-${randomUUID()}`
  }

  /** Apply exactly once; log immutable events, independently of block state. */
  emit(input: SessionEvent): void {
    const event = structuredClone(input)
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
        if (this.index.has(event.block.id)) break
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
    if (event.type === 'status' && event.status === 'idle') this.#drain()
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

  send(text: string, images?: string[], block?: string): { queued: boolean } {
    const message = { text, images, block }
    if (this.#active || this.status === 'running') {
      this.#queued.push(message)
      this.emit({ type: 'queue', items: this.#queued.map((item) => item.text) })
      return { queued: true }
    }
    void this.#run(message)
    return { queued: false }
  }

  async #run(message: Message): Promise<void> {
    this.#active = true
    const generation = this.#generation
    try {
      if (!this.backend.alive()) await this.start()
      if (generation !== this.#generation) return
      await this.backend.send(message.text, message.images, message.block)
    } catch (error) {
      if (generation !== this.#generation) return
      this.addBlock({ id: this.newId('notice'), type: 'notice', notice: {
        kind: 'backend-error', level: 'error', args: { message: String(error) } } })
      this.#cancelAsks()
      this.setStatus('exited')
    } finally {
      this.#active = false
      this.#drain()
    }
  }

  #drain(): void {
    if (this.#active || this.status !== 'idle' || !this.#queued.length) return
    const message = this.#queued.shift()!
    this.emit({ type: 'queue', items: this.#queued.map((item) => item.text) })
    void this.#run(message)
  }

  steer(text: string, images?: string[], block?: string): boolean {
    return this.backend.steer(text, images, block)
  }

  interrupt(): void {
    this.#cancelAsks()
    this.backend.interrupt()
  }

  async configure(settings: Settings): Promise<void> {
    this.emit({ type: 'settings', settings })
    if (this.backend.alive()) await this.backend.configure(this.settings)
  }

  async stop(): Promise<void> {
    this.#generation++
    this.#resume = this.resumeId()
    this.#queued = []
    if (this.queue.length) this.emit({ type: 'queue', items: [] })
    this.#cancelAsks()
    await this.backend.stop()
    this.setStatus('exited')
  }

  detach(): void { this.notify = undefined }

  transcript(): Transcript {
    return structuredClone({ blocks: this.blocks, queue: this.#queued, capabilities: this.capabilities })
  }

  attach(after?: Cursor, turns = 20): { result: AttachResult, afterWrite: () => void } {
    const replay = after !== undefined && after.epoch === this.epoch
      && after.seq >= 0 && after.seq <= this.seq
      && (after.seq === this.seq || (this.log[0]?.seq ?? Infinity) <= after.seq + 1)
    const events = replay ? this.log.filter((event) => event.seq > after!.seq) : []
    const blocks = replay ? [] : this.#lastTurns(this.blocks.length, turns)
    const earlier = !replay && blocks.length < this.blocks.length
    const result: AttachResult = { epoch: this.epoch, seq: this.seq, replay: replay ? 'events' : 'fresh',
      status: this.status, info: structuredClone(this.info), settings: { ...this.settings },
      queue: [...this.queue], asks: [...this.asks.values()].map(({ ask }) => structuredClone(ask)),
      earlier, capabilities: structuredClone(this.capabilities) }
    return { result, afterWrite: () => {
      for (const event of events) this.notify?.(event)
      if (!replay) {
        for (const block of blocks) this.#history(block, result.seq)
        this.#historyDone(earlier, result.seq)
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

  earlier(before: string, turns = 20): { earlier: boolean } {
    const end = this.blocks.findIndex((block) => block.id === before)
    if (end < 0) throw new RpcError(ErrorCode.InvalidParams, `Unknown history block: ${before}`)
    const blocks = this.#lastTurns(end, turns)
    const earlier = blocks.length < end
    for (const block of blocks) this.#history(block, this.seq, before)
    this.#historyDone(earlier, this.seq)
    return { earlier }
  }
}
