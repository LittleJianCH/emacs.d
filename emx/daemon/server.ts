// server.ts --- one socket, one editor client, and a persistent session table.

import { randomUUID } from 'node:crypto'
import { mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { chmod, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import type { Server } from 'node:net'
import { join, resolve } from 'node:path'
import { backends } from '../backends/backend.ts'
import { acquireLock } from './lock.ts'
import { codeVersion, socketPath, stateDir } from './paths.ts'
import { ErrorCode } from './protocol.ts'
import type { Answer, Cursor, Info, SessionSummary, Settings } from './protocol.ts'
import { Connection, Reply, RpcError } from './rpc.ts'
import { Editor } from './editor.ts'
import { UsageService } from '../usage/service.ts'
import type { UsageConfig } from '../usage/service.ts'
import { Accounting } from '../usage/accounting.ts'
import { Session } from './session.ts'
import type { Transcript } from './session.ts'

interface SavedSession {
  id: string
  agent: string
  root: string
  info: Info
  settings: Settings
  resume?: string
}

export interface ServerOptions {
  varDir: string
  idleExit?: number
  log?: (message: string) => void
}

function invalid(message: string): never {
  throw new RpcError(ErrorCode.InvalidParams, message)
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid('Expected an object')
  return value as Record<string, unknown>
}

function string(value: unknown, name: string): string {
  if (typeof value !== 'string') invalid(`Expected a string: ${name}`)
  return value
}

function optionalString(value: unknown, name: string): string | undefined {
  return value === undefined ? undefined : string(value, name)
}

function settings(value: unknown): Settings {
  const params = object(value)
  const result: Settings = {}
  for (const key of ['model', 'effort', 'mode', 'beforePlan'] as const) {
    if (params[key] === null || typeof params[key] === 'string') result[key] = params[key]
    else if (params[key] !== undefined) invalid(`Expected a string or null: ${key}`)
  }
  return result
}

function integer(value: unknown, name: string, minimum: number): number | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum) {
    invalid(`Expected an integer >= ${minimum}: ${name}`)
  }
  return value
}

export class DaemonServer {
  readonly varDir: string
  readonly socket: string
  readonly server: Server
  readonly sessions = new Map<string, Session>()
  readonly version = codeVersion()
  readonly finished: Promise<void>
  client: Connection | undefined
  readonly usage: UsageService
  readonly accounting: Accounting
  readonly editor: Editor
  #mcp = new Map<Connection, string>()
  #calls = new Map<Connection, Map<unknown, AbortController>>()
  #connections = new Set<Connection>()
  #idleExit: number
  #idleTimer: NodeJS.Timeout | undefined
  #saveTimer: NodeJS.Timeout | undefined
  #sessionsTimer: NodeJS.Timeout | undefined
  #saveChain: Promise<void> = Promise.resolve()
  #savePending: Promise<void> | undefined
  #shutdown: Promise<void> | undefined
  #stopping = false
  #releaseLock: (() => void) | undefined
  #log: (message: string) => void
  #finish!: () => void

  constructor(options: ServerOptions) {
    this.varDir = resolve(options.varDir)
    this.socket = socketPath(this.varDir)
    this.editor = new Editor(stateDir(this.varDir))
    this.#idleExit = options.idleExit ?? 900
    this.#log = options.log ?? (() => {})
    this.usage = new UsageService({ log: (message) => this.#log(message),
      send: (message) => this.client?.notify('usage/' + message.method, message.params) })
    this.accounting = new Accounting(this.usage)
    this.finished = new Promise((resolve) => { this.#finish = resolve })
    this.server = createServer((socket) => {
      const connection = new Connection(socket)
      this.#connections.add(connection)
      connection.onRequest = (method, params, id) => this.#request(connection, method, params, id)
      connection.onNotification = (method, params) => {
        if ((method === 'usage/record' || method === 'usage/quota') && connection === this.client) {
          try {
            if (method === 'usage/record') this.usage.record({ record: object(object(params).record) })
            else this.usage.quota({ ...object(params), agent: string(params.agent, 'agent') })
          } catch (error) { this.#log(`Usage notification failed: ${error}`) }
        }
        if (method === 'editor/tools' && connection === this.client) this.#tools(params)
        if (method === 'notifications/cancelled') this.#calls.get(connection)?.get(params.requestId)?.abort(new Error('Cancelled'))
      }
      connection.onClose = () => {
        this.#connections.delete(connection)
        this.#mcp.delete(connection)
        for (const call of this.#calls.get(connection)?.values() ?? []) call.abort(new Error('MCP connection closed'))
        this.#calls.delete(connection)
        if (this.client === connection) {
          this.editor.detach()
          this.client = undefined
          for (const session of this.sessions.values()) session.detach()
        }
        this.#checkIdle()
      }
    })
    this.server.on('error', (error) => this.#log(`Socket error: ${error.message}`))
  }

  async start(): Promise<void> {
    const dir = stateDir(this.varDir)
    await mkdir(dir, { recursive: true, mode: 0o700 })
    await chmod(dir, 0o700)
    this.#releaseLock = await acquireLock(dir)
    try {
      // Only the lock holder may remove an abandoned socket.
      await unlink(this.socket).catch((error: NodeJS.ErrnoException) => {
        if (error.code !== 'ENOENT') throw error
      })
      await this.editor.restore().catch((error) => this.#log(`Cannot load tools: ${error}`))
      let usageConfig = {}
      try { usageConfig = JSON.parse(await readFile(join(dir, 'usage.json'), 'utf8')) } catch { /* First start. */ }
      this.usage.initialize({ ...usageConfig, usageFile: join(this.varDir, 'agent-usage.jsonl'),
        quotaFile: join(this.varDir, 'agent-quota.json') })
      await this.#restore()
      await new Promise<void>((resolve, reject) => {
        this.server.once('error', reject)
        this.server.listen(this.socket, () => {
          this.server.off('error', reject)
          resolve()
        })
      })
      await chmod(this.socket, 0o600)
      this.#log(`Listening on ${this.socket}`)
      this.#checkIdle()
    } catch (error) {
      await this.stop()
      throw error
    }
  }

  #list(root?: string): SessionSummary[] {
    return [...this.sessions.values()].filter((session) => root === undefined || session.root === root)
      .map((session) => session.summary())
  }

  #changed(summaryChanged = true): void {
    if (summaryChanged && !this.#stopping && this.#sessionsTimer === undefined) {
      // Keep one deadline and publish the latest state, at most every 100 ms.
      this.#sessionsTimer = setTimeout(() => {
        this.#sessionsTimer = undefined
        this.client?.notify('sessions', { sessions: this.#list() })
      }, 100)
    }
    if (!this.#stopping && this.#saveTimer === undefined) {
      // Later events share this deadline instead of postponing it.
      this.#saveTimer = setTimeout(() => {
        this.#saveTimer = undefined
        void this.persist().catch((error) => this.#log(`Cannot save sessions: ${error}`))
      }, 200)
    }
    if (summaryChanged) this.#checkIdle()
  }

  #make(saved: SavedSession, restored = false, transcript?: Transcript): Session {
    return new Session({ ...saved, restored, transcript, daemonSocket: this.socket, editorTools: () => this.editor.tools, onUsage: (session, event) => this.accounting.accept(session, event), onChange: (summaryChanged) => this.#changed(summaryChanged) })
  }

  async #restore(): Promise<void> {
    let data: unknown
    try {
      data = JSON.parse(await readFile(join(stateDir(this.varDir), 'sessions.json'), 'utf8'))
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') this.#log(`Cannot load sessions: ${error}`)
      return
    }
    if (!Array.isArray(data)) {
      this.#log('Cannot load sessions: expected an array')
      return
    }
    for (const entry of data) {
      try {
        const record = object(entry)
        const agent = string(record.agent, 'agent')
        if (!Object.hasOwn(backends, agent)) throw new Error(`Unknown agent: ${agent}`)
        const saved: SavedSession = { id: string(record.id, 'id'), agent,
          root: string(record.root, 'root'), info: object(record.info ?? {}),
          settings: settings(record.settings ?? {}), resume: optionalString(record.resume, 'resume') }
        // Session ids are also file names; reject paths in a damaged state table.
        if (!/^session-[a-zA-Z0-9-]+$/.test(saved.id)) throw new Error('Invalid session id')
        let transcript: Transcript | undefined
        try {
          const data = JSON.parse(await readFile(this.#transcriptFile(saved.id), 'utf8'))
          if (!Array.isArray(data.blocks) || !Array.isArray(data.queue)) throw new Error('Invalid transcript')
          transcript = data
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') this.#log(`Cannot load transcript: ${error}`)
        }
        this.sessions.set(saved.id, this.#make(saved, true, transcript))
      } catch (error) {
        this.#log(`Ignoring invalid saved session: ${error}`)
      }
    }
  }

  #transcriptFile(id: string): string {
    return join(stateDir(this.varDir), 'sessions', `${id}.json`)
  }

  #snapshot(): Map<string, string> {
    const files = new Map<string, string>()
    const records: SavedSession[] = []
    for (const session of this.sessions.values()) {
      records.push({ id: session.id, agent: session.agent, root: session.root,
        info: session.info, settings: session.settings, resume: session.resumeId() })
      files.set(this.#transcriptFile(session.id), JSON.stringify(session.transcript()) + '\n')
    }
    // Publish the table after its transcripts.
    files.set(join(stateDir(this.varDir), 'sessions.json'), JSON.stringify(records) + '\n')
    return files
  }

  persist(): Promise<void> {
    clearTimeout(this.#saveTimer)
    this.#saveTimer = undefined
    if (this.#savePending) return this.#savePending
    const task = this.#saveChain.catch(() => {}).then(async () => {
      this.#savePending = undefined
      // Snapshot when the write starts, including changes while it was queued.
      const files = this.#snapshot()
      await mkdir(join(stateDir(this.varDir), 'sessions'), { recursive: true, mode: 0o700 })
      for (const [file, data] of files) {
        const temp = `${file}.${process.pid}.tmp`
        await writeFile(temp, data, { mode: 0o600 })
        await rename(temp, file)
      }
    })
    this.#savePending = task
    this.#saveChain = task
    return task
  }

  #persistSync(): void {
    mkdirSync(join(stateDir(this.varDir), 'sessions'), { recursive: true, mode: 0o700 })
    for (const [file, data] of this.#snapshot()) {
      const temp = `${file}.${process.pid}.tmp`
      writeFileSync(temp, data, { mode: 0o600 })
      renameSync(temp, file)
    }
  }

  #session(params: Record<string, unknown>): Session {
    const id = string(params.id, 'id')
    const session = this.sessions.get(id)
    if (!session) throw new RpcError(ErrorCode.NoSession, `No such session: ${id}`)
    return session
  }

  #message(params: Record<string, unknown>): { text: string, images?: string[], block?: string } {
    const text = string(params.text, 'text')
    const block = optionalString(params.block, 'block')
    if (params.images !== undefined && (!Array.isArray(params.images)
      || !params.images.every((image) => typeof image === 'string'))) invalid('Expected string[]: images')
    return { text, images: params.images as string[] | undefined, block }
  }

  #tools(value: unknown): void {
    if (this.editor.update(value)) {
      for (const connection of this.#mcp.keys()) connection.notify('mcp/tools_changed', {})
      void this.editor.flush().catch((error) => this.#log(`Cannot save tools: ${error}`))
    }
  }

  #request(connection: Connection, method: string, value: unknown, requestId?: unknown): unknown {
    if (method === 'mcp/hello') {
      if (this.#mcp.has(connection)) invalid('MCP connection is already bound to a session')
      const session = string(object(value).session, 'session')
      this.#session({ id: session })
      if (connection === this.client) invalid('An editor connection cannot become an MCP connection')
      this.#mcp.set(connection, session)
      return {}
    }
    const mcp = this.#mcp.get(connection)
    if (mcp !== undefined) {
      if (method === 'mcp/tools') return { tools: this.editor.tools.tools }
      if (method === 'mcp/call') {
        const session = this.#session({ id: mcp })
        const params = object(value)
        const controller = new AbortController()
        let calls = this.#calls.get(connection)
        if (!calls) this.#calls.set(connection, calls = new Map())
        calls.set(requestId, controller)
        return this.editor.call(string(params.name, 'name'), object(params.arguments ?? {}),
          { session: mcp, root: session.root, place: null }, controller.signal)
          .finally(() => calls!.delete(requestId))
      }
      throw new RpcError(ErrorCode.NotClient, 'MCP connections may only list and call tools')
    }
    if (method !== 'hello' && method !== 'ping' && method !== 'daemon/stop'
      && connection !== this.client) {
      throw new RpcError(ErrorCode.NotClient, 'Say hello to become the client')
    }
    const params = object(value)
    if (this.#stopping) throw new RpcError(ErrorCode.Internal, 'Daemon is stopping')
    switch (method) {
      case 'ping': return { daemon: process.pid, version: this.version }
      case 'hello': {
        if (params.tools !== undefined) this.#tools(params.tools)
        string(params.client, 'client')
        string(params.version, 'version')
        if (this.client !== connection) {
          this.editor.detach()
          this.client?.notify('replaced', {})
          for (const session of this.sessions.values()) session.detach()
        }
        this.client = connection
        this.editor.connection = connection
        this.#checkIdle()
        return new Reply({ daemon: process.pid, version: this.version }, () => connection.notify('usage/quotas', { quotas: this.usage.configure({}).quotas }))
      }
      case 'usage/configure': {
        const config: Partial<UsageConfig> = {}
        if (params.agents !== undefined) {
          if (!Array.isArray(params.agents) || !params.agents.every((a) => typeof a === 'string')) invalid('Expected string[]: agents')
          config.agents = params.agents
        }
        if (params.pollInterval !== undefined) config.pollInterval = integer(params.pollInterval, 'pollInterval', 0)
        if (params.pollers !== undefined) {
          config.pollers = {}
          for (const [source, value] of Object.entries(object(params.pollers))) {
            const command = object(value).command
            if (!Array.isArray(command) || !command.length || !command.every((a) => typeof a === 'string')) invalid('Expected nonempty string[]: command')
            config.pollers[source] = { command }
          }
        }
        const result = this.usage.configure(config)
        // Persist commands so quota polls continue without an attached editor.
        const file = join(stateDir(this.varDir), 'usage.json')
        writeFileSync(file + '.tmp', JSON.stringify({ agents: this.usage.agents,
          pollInterval: this.usage.pollInterval, pollers: this.usage.pollers }), { mode: 0o600 })
        renameSync(file + '.tmp', file)
        return result
      }
      case 'usage/report': return this.usage.report(params)
      case 'usage/refresh': return this.usage.refresh(params)
      case 'usage/clear': return this.usage.clear()
      case 'sessions/list': return { sessions: this.#list(optionalString(params.root, 'root')) }
      case 'session/open': {
        const agent = string(params.agent, 'agent')
        if (!Object.hasOwn(backends, agent)) invalid(`Unknown agent: ${agent}`)
        const root = string(params.root, 'root')
        const handle = optionalString(params.handle, 'handle')
        const resume = optionalString(params.resume, 'resume')
        const parent = optionalString(params.parent, 'parent')
        // Claude needs the editor's installed skill replacements on each spawn.
        let claude: import('./protocol.ts').OpenParams['claude']
        if (params.claude !== undefined) {
          const context = object(params.claude)
          const supersededSkills = context.supersededSkills
          if (supersededSkills !== undefined && (!Array.isArray(supersededSkills)
            || !supersededSkills.every((s) => typeof s === 'string'))) invalid('Expected string[]: supersededSkills')
          claude = { skillsDir: context.skillsDir == null ? undefined : optionalString(context.skillsDir, 'skillsDir'),
            supersededSkills: supersededSkills as string[] | undefined }
        }
        // Codex needs the editor's installed skill replacements on every spawn.
        let codex: import('./protocol.ts').OpenParams['codex']
        if (params.codex !== undefined) {
          const context = object(params.codex)
          const supersededSkills = context.supersededSkills
          if (supersededSkills !== undefined && (!Array.isArray(supersededSkills)
            || !supersededSkills.every((s) => typeof s === 'string'))) invalid('Expected string[]: supersededSkills')
          codex = { skillsRoot: optionalString(context.skillsRoot, 'skillsRoot'),
            supersededSkills: supersededSkills as string[] | undefined }
        }
        // Native conversation forks are a later migration phase.
        if (params.fork !== undefined) invalid('Session forks are not supported yet')
        const session = this.#make({ id: `session-${randomUUID()}`, agent, root, resume,
          settings: settings(params.settings ?? {}),
          info: { ...(handle ? { handle } : {}), ...(parent ? { parent: this.sessions.get(parent)?.resumeId() ?? parent } : {}),
            ...(codex ? { codex } : {}), ...(claude ? { claude } : {}) } })
        this.sessions.set(session.id, session)
        return (async () => {
          try {
            await session.start()
          } catch (error) {
            await session.stop()
            this.sessions.delete(session.id)
            this.#changed()
            throw error
          }
          this.#changed()
          await this.persist()
          return { id: session.id }
        })()
      }
      case 'session/attach': {
        const session = this.#session(params)
        let after: Cursor | undefined
        if (params.after !== undefined) {
          const cursor = object(params.after)
          const seq = integer(cursor.seq, 'after.seq', 0)
          if (seq === undefined) invalid('Expected after.seq')
          after = { epoch: string(cursor.epoch, 'after.epoch'), seq }
        }
        const turns = integer(params.turns, 'turns', 0)
        session.notify = (event) => {
          if (this.client === connection) connection.notify(event.type, event)
        }
        const attached = session.attach(after, turns)
        return new Reply(attached.result, attached.afterWrite)
      }
      case 'session/detach': this.#session(params).detach(); return {}
      case 'session/send': {
        const session = this.#session(params)
        const message = this.#message(params)
        if (params.handle !== undefined) session.setInfo({ handle: string(params.handle, 'handle') })
        return session.send(message.text, message.images, message.block)
      }
      case 'session/steer': {
        const session = this.#session(params)
        const message = this.#message(params)
        if (params.handle !== undefined) session.setInfo({ handle: string(params.handle, 'handle') })
        return { accepted: session.steer(message.text, message.images, message.block) }
      }
      case 'session/interrupt': this.#session(params).interrupt(); return {}
      case 'session/configure': return this.#session(params).configure(settings(params)).then(() => ({}))
      case 'session/answer': {
        const session = this.#session(params)
        const id = string(params.ask, 'ask')
        const answer: Answer = {}
        if (params.choice !== undefined) {
          if (params.choice !== 'allow' && params.choice !== 'always' && params.choice !== 'deny') {
            invalid('Invalid approval choice')
          }
          answer.choice = params.choice
        }
        if (params.answers !== undefined) {
          if (!Array.isArray(params.answers)) invalid('Expected an array: answers')
          answer.answers = params.answers.map((input) => {
            const item = object(input)
            if (!Array.isArray(item.selected) || !item.selected.every((s) => typeof s === 'string')) {
              invalid('Expected string[]: selected')
            }
            return { selected: item.selected as string[], custom: optionalString(item.custom, 'custom') }
          })
        }
        return session.answer(id, answer)
      }
      case 'session/earlier': {
        const session = this.#session(params)
        return session.earlier(string(params.before, 'before'), integer(params.turns, 'turns', 0))
      }
      case 'session/stop': {
        const session = this.#session(params)
        for (const [peer, owner] of this.#mcp) {
          if (owner !== session.id) continue
          for (const call of this.#calls.get(peer)?.values() ?? []) call.abort(new Error('Session stopped'))
          this.#calls.delete(peer)
        }
        return session.stop().then(async () => {
          this.sessions.delete(session.id)
          this.#changed()
          // Await older writes before deleting, so none can recreate this file.
          await this.persist()
          await unlink(this.#transcriptFile(session.id)).catch((error: NodeJS.ErrnoException) => {
            if (error.code !== 'ENOENT') throw error
          })
          return {}
        })
      }
      case 'daemon/stop': return new Reply({}, () => { void this.stop() })
      default: throw new RpcError(ErrorCode.MethodNotFound, `Method not found: ${method}`)
    }
  }

  #checkIdle(): void {
    const busy = this.client !== undefined || [...this.sessions.values()].some((session) => session.backend.alive())
    if (busy || this.#stopping) {
      clearTimeout(this.#idleTimer)
      this.#idleTimer = undefined
    } else if (this.#idleTimer === undefined) {
      this.#idleTimer = setTimeout(() => {
        this.#log('Idle timeout')
        void this.stop()
      }, this.#idleExit * 1000)
    }
  }

  stop(): Promise<void> {
    this.#shutdown ??= this.#close()
    return this.#shutdown
  }

  async #close(): Promise<void> {
    this.#stopping = true
    this.editor.detach()
    await this.editor.flush().catch((error) => this.#log(`Cannot save tools: ${error}`))
    this.#checkIdle()
    clearTimeout(this.#saveTimer)
    clearTimeout(this.#sessionsTimer)
    try {
      await this.#saveChain.catch(() => {})
      // Preserve the queue before stopping backends cancels their pending work.
      // A restored session has a new epoch, no asks, and starts idle.
      this.#persistSync()
    } catch (error) {
      this.#log(`Cannot save sessions on shutdown: ${error}`)
    }
    for (const session of this.sessions.values()) {
      try { await session.stop() } catch (error) {
        this.#log(`Cannot stop backend for ${session.id}: ${error}`)
      } finally { this.accounting.flush(session) }
    }
    this.usage.stop()
    // end() flushes the daemon/stop response before closing its socket.
    for (const connection of this.#connections) connection.close()
    const force = setTimeout(() => {
      for (const connection of this.#connections) connection.socket.destroy()
    }, 500)
    await new Promise<void>((resolve) => this.server.close(() => resolve()))
    clearTimeout(force)
    if (this.#releaseLock) {
      await unlink(this.socket).catch((error: NodeJS.ErrnoException) => {
        if (error.code !== 'ENOENT') this.#log(`Cannot remove socket: ${error.message}`)
      })
      try { this.#releaseLock() } catch (error) {
        this.#log(`Cannot remove lock: ${error}`)
      }
      this.#releaseLock = undefined
    }
    this.#log('Stopped')
    this.#finish()
  }
}
