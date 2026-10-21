import { ProjectEnvironments } from '../remote/environment.ts'
// server.ts --- one socket, one editor client, and a persistent session table.

import { ConfigFiles, configNames, configTools } from './config-files.ts'
import { Outbox } from '../remote/outbox.ts'
import { homedir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { Configuration } from '../config.ts'
import { Collaboration, toolNames } from './collab.ts'
import { mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { chmod, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import type { Server } from 'node:net'
import { join, resolve } from 'node:path'
import { backends } from '../backends/backend.ts'
import { acquireLock } from './lock.ts'
import { checkoutRoot, codeVersion, socketPath, stateDir } from './paths.ts'
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
  socket?: string
  remote?: boolean
  idleExit?: number
  configFile?: string
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
  readonly configuration: Configuration
  readonly collab: Collaboration
  readonly environments?: ProjectEnvironments
  readonly outbox?: Outbox
  readonly configFiles: ConfigFiles
  #outboxTimer?: NodeJS.Timeout
  #usageClients = new Set<Connection>()
  #mcp = new Map<Connection, string>()
  #calls = new Map<Connection, Map<unknown, AbortController>>()
  #closing = new WeakMap<Session, Promise<void>>()
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
    this.socket = options.socket ?? socketPath(this.varDir)
    this.editor = new Editor(stateDir(this.varDir))
    this.configuration = new Configuration(this.varDir, options.configFile, options.remote ? join(homedir(), '.config/emx/config.json') : undefined)
    if (options.remote) this.environments = new ProjectEnvironments()
    if (options.remote) this.outbox = new Outbox(join(stateDir(this.varDir), 'usage-outbox.json'))
    this.configFiles = new ConfigFiles(async (method, file) => {
      if (!this.client) throw new Error('Emacs is not attached')
      const out = await this.client.request('editor/call', { method, params: { path: file } }, AbortSignal.timeout(5000)) as any
      if (!out.ok) throw new Error(out.error ?? 'Editor call failed')
      return out.result
    })
    this.#idleExit = options.idleExit ?? this.configuration.value.daemon.idleExit
    this.#log = options.log ?? (() => {})
    this.usage = new UsageService({ capture: this.outbox ? (method, params) => this.outbox!.add(method, params) : undefined, log: (message) => this.#log(message),
      send: (message) => {
        for (const peer of new Set([...this.#usageClients, ...(this.client ? [this.client] : [])])) {
          peer.notify('usage/' + message.method, message.params)
        }
      } })
    this.accounting = new Accounting(this.usage)
    this.collab = new Collaboration({ sessions: this.sessions, varDir: this.varDir,
      config: () => this.configuration.value, changed: () => this.#changed(false),
      create: (agent, root, settings, info) => {
        const s = this.#make({ id: `session-${randomUUID()}`, agent, root, settings, info })
        this.sessions.set(s.id, s); this.#changed(); return s
      }, close: (s) => this.#closeSession(s),
      view: async (s) => {
        if (this.client) await this.client.request('editor/call', { method: '_session_open',
          params: { session: s.summary() }, caller: { session: s.id, root: s.root, place: null } }, AbortSignal.timeout(5000))
      },
      visible: async (s) => {
        if (!this.client) return false
        try {
          const out = await this.client.request('editor/call', { method: '_session_visible',
            params: { id: s.id }, caller: { session: s.id, root: s.root, place: null } }, AbortSignal.timeout(1000)) as any
          return out?.result?.visible !== false
        } catch { return true }
      } })
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
        this.#usageClients.delete(connection)
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
      this.outbox?.restore()
      if (this.outbox) {
        const deliver = () => {
          if (this.outbox!.entries.length) this.client?.notify('usage/outbox', { entries: this.outbox!.entries })
        }
        this.outbox.changed = deliver
        this.#outboxTimer = setInterval(deliver, 5000)
        this.#outboxTimer.unref()
      }
      this.usage.initialize({ ...usageConfig, pollInterval: this.configuration.value.usage.pollInterval, usageFile: join(this.varDir, 'agent-usage.jsonl'),
        quotaFile: join(this.varDir, 'agent-quota.json') })
      if (this.outbox) this.usage.configure({ pollers: this.#hostPollers() })
      this.configuration.watch((result) => this.#configChanged(result))
      await this.#restore()
      this.collab.restore()
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
    return new Session({ ...saved, restored, transcript, daemonSocket: this.socket, environment: this.environments ? () => this.environments!.get(saved.root) : undefined, agentConfig: () => this.configuration.value.agents[saved.agent], hibernateAfter: () => this.configuration.value.sessions.hibernateAfter, editorTools: () => this.collab.tools(this.editor.tools), onEvent: (session, event) => this.collab.event(session, event), onUsage: (session, event) => this.accounting.accept(session, event), onChange: (summaryChanged) => this.#changed(summaryChanged) })
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
        // Children have no resumable native transcript after a crash.
        if (saved.info.parent) continue
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
      if (session.info.parent) continue
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

  #configChanged(result: ReturnType<Configuration['reload']>): void {
    for (const error of result.errors) this.#log(error)
    if (!result.changed) return
    this.#idleExit = result.config.daemon.idleExit
    clearTimeout(this.#idleTimer)
    this.#idleTimer = undefined
    this.#checkIdle()
    this.usage.configure({ pollInterval: result.config.usage.pollInterval,
      ...(this.outbox ? { pollers: this.#hostPollers() } : {}) })
    for (const session of this.sessions.values()) session.refreshHibernate()
    for (const peer of new Set([...this.#usageClients, ...(this.client ? [this.client] : [])])) {
      peer.notify('config', { config: result.config, errors: result.errors })
    }
    for (const peer of this.#mcp.keys()) peer.notify('mcp/tools_changed', {})
  }

  #hostPollers(): UsageConfig['pollers'] {
    const agents = this.configuration.value.agents
    return Object.fromEntries(['claude', 'codex', 'dsh'].filter((name) => agents[name]).map((name) => [name,
      { command: [agents[name].executable, ...(name === 'dsh' ? ['--profile', 'sdk', '--patch',
        join(checkoutRoot, 'lisp/agent/backend/dsh/emacs.yml')] : [])] }]))
  }

  #tools(value: unknown): void {
    if (this.outbox) {
      const tools = object(value)
      if (Array.isArray(tools.tools) && Array.isArray(tools.readOnly)) value = {
        tools: [...tools.tools.filter((t: any) => !configNames.includes(t.name)), ...configTools],
        readOnly: [...new Set([...tools.readOnly, 'config_read'])],
      }
    }
    if (this.editor.update(value)) {
      for (const connection of this.#mcp.keys()) connection.notify('mcp/tools_changed', {})
      void this.editor.flush().catch((error) => this.#log(`Cannot save tools: ${error}`))
    }
  }

  #request(connection: Connection, method: string, value: unknown, requestId?: unknown): unknown {
    if (this.#stopping) throw new RpcError(ErrorCode.Internal, 'Daemon is stopping')
    if (method === 'usage/hello') {
      if (connection === this.client || this.#mcp.has(connection)) invalid('Connection already has another role')
      this.#usageClients.add(connection)
      this.#checkIdle()
      return new Reply({ daemon: process.pid, version: this.version, capabilities: { usage: 1, stopIfIdle: 1 }, config: this.configuration.value },
        () => connection.notify('usage/quotas', { quotas: this.usage.configure({}).quotas }))
    }
    if (this.#usageClients.has(connection) && !method.startsWith('usage/') && method !== 'ping') {
      throw new RpcError(ErrorCode.NotClient, 'Usage connections may only access usage methods')
    }
    if (method === 'mcp/hello') {
      if (this.#mcp.has(connection)) invalid('MCP connection is already bound to a session')
      const session = string(object(value).session, 'session')
      this.#session({ id: session })
      if (connection === this.client) invalid('An editor connection cannot become an MCP connection')
      this.#mcp.set(connection, session)
      return { remote: !!this.outbox }
    }
    const mcp = this.#mcp.get(connection)
    if (mcp !== undefined) {
      if (method === 'mcp/tools') return { tools: this.collab.tools(this.editor.tools).tools }
      if (method === 'mcp/call') {
        const session = this.#session({ id: mcp })
        const params = object(value)
        const controller = new AbortController()
        let calls = this.#calls.get(connection)
        if (!calls) this.#calls.set(connection, calls = new Map())
        calls.set(requestId, controller)
        const name = string(params.name, 'name'), args = object(params.arguments ?? {})
        return (toolNames.includes(name) ? this.collab.call(session, name, args, controller.signal)
          : this.editor.call(name, args, { session: mcp, root: session.root, place: null }, controller.signal))
          .finally(() => calls!.delete(requestId))
      }
      throw new RpcError(ErrorCode.NotClient, 'MCP connections may only list and call tools')
    }
    if (method !== 'hello' && method !== 'ping' && method !== 'daemon/stop'
      && connection !== this.client && !(this.#usageClients.has(connection) && method.startsWith('usage/'))) {
      throw new RpcError(ErrorCode.NotClient, 'Say hello to become the client')
    }
    const params = object(value)
    switch (method) {
      case 'ping': return { daemon: process.pid, version: this.version, capabilities: { usage: 1, stopIfIdle: 1 },
        liveAgents: [...this.sessions.values()].filter((session) => session.backend.alive()).length }
      case 'hello': {
        if (params.config !== undefined) this.#configChanged(this.configuration.push(params.config))
        if (params.agents !== undefined) {
          if (!Array.isArray(params.agents) || !params.agents.every((s) => typeof s === 'string')) invalid('Expected string[]: agents')
          if (JSON.stringify(this.collab.enabled) !== JSON.stringify(params.agents)) {
            this.collab.enabled = params.agents
            this.collab.save()
            for (const peer of this.#mcp.keys()) peer.notify('mcp/tools_changed', {})
          }
        }
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
        return new Reply({ daemon: process.pid, version: this.version, capabilities: { usage: 1, stopIfIdle: 1 }, config: this.configuration.value }, () => {
          connection.notify('usage/quotas', { quotas: this.usage.configure({}).quotas })
          if (this.outbox) connection.notify('usage/outbox', { entries: this.outbox.entries })
          connection.notify('sessions', { sessions: this.#list() })
        })
      }
      case 'config/call': {
        if (this.outbox) throw new Error('Configuration files belong to the local daemon')
        return this.configFiles.call(string(params.method, 'method'), object(params.arguments))
      }
      case 'usage/ack': {
        if (!this.outbox) throw new Error('Only host daemons have a usage outbox')
        this.outbox.ack(params.source === undefined ? string(params.id, 'id') : string(params.source, 'source'),
          params.source === undefined ? undefined : integer(params.sequence, 'sequence', 1))
        return {}
      }
      case 'config/push': {
        const result = this.configuration.push(params.config)
        this.#configChanged(result)
        return { config: result.config, errors: result.errors }
      }
      case 'config/get': return { config: this.configuration.value, errors: this.configuration.errors }
      case 'config/reload': {
        const result = this.configuration.reload()
        this.#configChanged(result)
        return { config: result.config, errors: result.errors }
      }
      case 'usage/configure': {
        const config: Partial<UsageConfig> = {}
        if (params.agents !== undefined) {
          if (!Array.isArray(params.agents) || !params.agents.every((a) => typeof a === 'string')) invalid('Expected string[]: agents')
          config.agents = params.agents
        }
        // Legacy editors still send this field; cadence belongs to config.json.
        if (params.pollInterval !== undefined) integer(params.pollInterval, 'pollInterval', 0)
        config.pollInterval = this.configuration.value.usage.pollInterval
        if (params.pollers !== undefined) {
          config.pollers = {}
          for (const [source, value] of Object.entries(object(params.pollers))) {
            const command = object(value).command
            if (!Array.isArray(command) || !command.length || !command.every((a) => typeof a === 'string')) invalid('Expected nonempty string[]: command')
            config.pollers[source] = { command }
          }
        }
        if (this.outbox) config.pollers = this.#hostPollers()
        const result = this.usage.configure(config)
        // Persist commands so quota polls continue without an attached editor.
        const file = join(stateDir(this.varDir), 'usage.json')
        writeFileSync(file + '.tmp', JSON.stringify({ agents: this.usage.agents,
          pollInterval: this.usage.pollInterval, pollers: this.usage.pollers }), { mode: 0o600 })
        renameSync(file + '.tmp', file)
        return result
      }
      case 'usage/record': {
        const id = string(params.id, 'id')
        return this.usage.record({ id, record: object(params.record),
          ...(params.source === undefined ? {} : { source: string(params.source, 'source'), sequence: integer(params.sequence, 'sequence', 1) }) })
      }
      case 'usage/quota': {
        const id = string(params.id, 'id')
        const reading = object(params.reading)
        return this.usage.quota({ ...reading, agent: string(reading.agent, 'agent') }, id,
          optionalString(params.source, 'source'), params.source === undefined ? undefined : integer(params.sequence, 'sequence', 1))
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
          info: { handle: this.collab.unique(handle ?? agent), ...(parent ? { parent, parentSession: this.sessions.get(parent)?.resumeId() ?? parent } : {}),
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
        this.collab.name(session, message.text)
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
      case 'session/stop': return this.#closeSession(this.#session(params)).then(() => ({}))
      case 'daemon/stop': {
        if (params.ifIdle !== undefined && typeof params.ifIdle !== 'boolean') invalid('Expected boolean: ifIdle')
        if (params.ifIdle) {
          if (this.collab.starting || [...this.sessions.values()].some((session) =>
            session.backend.alive() || session.busy() || session.asks.size > 0)) return { stopped: false }
          // Commit before yielding or replying, so no new launch can enter.
          this.#stopping = true
          return new Reply({ stopped: true }, () => { void this.stop() })
        }
        // Recheck after the editor's list request: a turn may have started.
        if (params.idleOnly && [...this.sessions.values()].some((session) =>
          session.status === 'running' || session.status === 'starting' || session.info.parent)) {
          throw new RpcError(ErrorCode.InvalidParams, 'Finish active turns, asks and children before restart')
        }
        return new Reply({}, () => { void this.stop() })
      }
      default: throw new RpcError(ErrorCode.MethodNotFound, `Method not found: ${method}`)
    }
  }

  #closeSession(session: Session): Promise<void> {
    let closing = this.#closing.get(session)
    if (!closing) {
      closing = this.#finishCloseSession(session)
      this.#closing.set(session, closing)
    }
    return closing
  }

  async #finishCloseSession(session: Session): Promise<void> {
    const starts = this.collab.beginClose(session)
    for (const [peer, owner] of this.#mcp) {
      if (owner !== session.id) continue
      for (const call of this.#calls.get(peer)?.values() ?? []) call.abort(new Error('Session stopped'))
      this.#calls.delete(peer)
    }
    await starts
    for (const child of [...this.sessions.values()]) {
      if (child.info.parent === session.id) await this.#closeSession(child)
    }
    await session.stop()
    this.sessions.delete(session.id)
    this.client?.notify('collab/closed', { id: session.id })
    this.collab.schedule()
    this.#changed()
    await this.persist()
    await unlink(this.#transcriptFile(session.id)).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== 'ENOENT') throw error
    })
  }

  #checkIdle(): void {
    const busy = this.client !== undefined || this.#usageClients.size > 0 || [...this.sessions.values()].some((session) => session.backend.alive())
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
    clearInterval(this.#outboxTimer)
    this.configuration.close()
    this.collab.stop()
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
