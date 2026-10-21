// pi.ts --- Pi 1.3 RPC peer; the extension forwards tools, this peer owns policy.
import { spawn } from 'node:child_process'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { once } from 'node:events'
import { lstat, readFile, realpath } from 'node:fs/promises'
import { extname, isAbsolute, join, relative } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { isDeepStrictEqual } from 'node:util'
import { checkoutRoot } from '../daemon/paths.ts'
import type { AgentConfig } from '../config.ts'
import type { Backend, SessionHost } from './backend.ts'
import { sessionSkills } from './backend.ts'
import type { EditorTools, Settings, ToolView } from '../daemon/protocol.ts'
import { diff } from './dsh.ts'

export const permissionModes = ['plan', 'ask', 'edits', 'auto', 'full']
export const defaultModel = 'opencode-go/kimi-k3'
const defaultFilter = { include: ['^opencode-go/'], exclude: ['contributor', 'free', 'preview'] }
const levels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
interface Model {
  id: string, provider: string, name?: string, thinkingLevelMap?: Record<string, unknown>
}
const modelId = (model: Model): string => `${model.provider}/${model.id}`
const efforts = (model: Model): string[] => Object.entries(model.thinkingLevelMap ?? {})
  .filter(([key, value]) => levels.includes(key) && value != null).map(([key]) => key)

/** Keep Pi's default level when the model supports it, never jump to max. */
const preferredEffort = (supported: string[], current?: string): string | undefined =>
  current && supported.includes(current) ? current
    : supported.includes('high') ? 'high' : supported.filter((l) => l !== 'max').at(-1) ?? supported.at(-1)

export function allowedModel(id: string, config?: AgentConfig): boolean {
  const filter = config?.models ?? defaultFilter
  return filter.include.some((s) => new RegExp(s, 'i').test(id))
    && !filter.exclude.some((s) => new RegExp(s, 'i').test(id))
}

export function toolView(root: string, name: string, input: any = {}): ToolView {
  const raw = input.path
  const path = typeof raw === 'string' && isAbsolute(raw) ? relative(root, raw) : raw
  const view: ToolView = { name, kind: 'other', title: path ?? name }
  if (name === 'bash') return { ...view, kind: 'command', command: input.command ?? '',
    title: (input.command ?? '').trim().split('\n')[0] }
  if (name === 'edit' || name === 'write') return { ...view, kind: 'edit', path,
    diff: name === 'edit' ? (Array.isArray(input.edits) ? input.edits : [input])
      .map((e: any) => diff(path ?? '', e.oldText, e.newText)).join('\n')
      : diff(path ?? '', undefined, input.content) }
  if (name === 'read') return { ...view, kind: 'read', path }
  if (['grep', 'find', 'ls'].includes(name)) return { ...view, kind: 'search', path,
    title: `${name} ${input.pattern ?? path ?? ''}` }
  if (name.startsWith('mcp__')) return { ...view, kind: 'mcp', title: name.split('__').slice(1).join(' · ') }
  return view
}

/** Resolve each existing prefix before appending missing path components. */
async function contained(root: string, input: unknown): Promise<boolean> {
  if (typeof input !== 'string' || !input) return false
  let path = input
  try {
    const base = await realpath(root)
    path = path.replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, ' ').replace(/^@/, '')
    if (path === '~') path = homedir()
    else if (path.startsWith('~/')) path = join(homedir(), path.slice(2))
    if (path.startsWith('file://')) path = fileURLToPath(path)
    // Do not normalize '..' before resolving symlinks: link/../x follows the
    // link's target on disk, not the lexical parent in the workspace.
    let target = isAbsolute(path) ? '/' : base
    for (const component of path.split('/').filter(Boolean)) {
      target = join(target, component)
      try { target = await realpath(target) }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') return false
        // A dangling symlink can later create a file outside the root.
        try { if ((await lstat(target)).isSymbolicLink()) return false }
        catch (missing) { if ((missing as NodeJS.ErrnoException).code !== 'ENOENT') return false }
      }
    }
    const rel = relative(base, target)
    return rel !== '..' && !rel.startsWith('../') && !isAbsolute(rel)
  } catch { return false }
}

async function images(paths?: string[]): Promise<object[] | undefined> {
  if (!paths?.length) return undefined
  return Promise.all(paths.map(async (path) => {
    const mimeType = ({ '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
      '.gif': 'image/gif', '.webp': 'image/webp' } as Record<string, string>)[extname(path).toLowerCase()]
    if (!mimeType) throw new Error(`Unsupported Pi image type: ${path}`)
    return { type: 'image', mimeType, data: (await readFile(path)).toString('base64') }
  }))
}
const output = (result: any): string => (result?.content ?? []).map((part: any) => part.text ?? '').join('\n')

export class PiBackend implements Backend {
  readonly host: SessionHost
  #process?: ChildProcessWithoutNullStreams
  #pending = new Map<string, { resolve: (value: any) => void, reject: (error: Error) => void, timer: NodeJS.Timeout }>()
  #resume?: string
  #running = false
  #stopping = false
  #cancelled = false
  #tools: EditorTools = { tools: [], readOnly: [] }
  #models: Model[] = []
  #confirmed: Settings = {}
  #beforePlan = 'edits'
  #always = new Set<string>()
  #dialogs = new Map<string, () => void>()
  #messagePrefix = ''
  #texts = new Map<number, string>()
  #calls = new Map<string, { name: string, input: any }>()
  #messageCalls = new Set<string>()
  #stderr = ''

  constructor(host: SessionHost) { this.host = host }
  #write(message: object): void { this.#process?.stdin.write(JSON.stringify(message) + '\n') }
  #request(type: string, params: object = {}): Promise<any> {
    if (!this.alive()) return Promise.reject(new Error('Pi is not running'))
    const id = this.host.newId('pi-rpc')
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error(`Pi request timed out: ${type}`)) }, 120000)
      this.#pending.set(id, { resolve, reject, timer })
      this.#write({ id, type, ...params })
    })
  }
  #notice(message: string, level: 'error' | 'warning' = 'error'): void {
    this.host.addBlock({ id: this.host.newId('notice'), type: 'notice',
      notice: { kind: 'backend-error', args: { message }, level } })
  }
  #model(settings: Settings): string {
    return settings.model || this.host.agentConfig?.()?.defaultModel || defaultModel
  }
  validateSettings(settings: Settings): void {
    const model = this.#model(settings)
    if (!allowedModel(model, this.host.agentConfig?.())) throw new Error(`Pi model excluded by configuration: ${model}`)
    if (!permissionModes.includes(settings.mode ?? 'edits')) throw new Error(`Unknown Pi permission mode: ${settings.mode}`)
    if (settings.beforePlan && (!permissionModes.includes(settings.beforePlan) || settings.beforePlan === 'plan')) {
      throw new Error(`Invalid Pi beforePlan mode: ${settings.beforePlan}`)
    }
    if (settings.effort && !levels.includes(settings.effort)) throw new Error(`Unknown Pi thinking level: ${settings.effort}`)
  }

  async start(resume?: string): Promise<void> {
    if (!isAbsolute(this.host.root) || /^\/[^/]+:/.test(this.host.root)) throw new Error('Pi sessions require a local absolute root')
    const desired = { ...this.host.settings }
    this.validateSettings(desired)
    this.#stopping = false; this.#cancelled = false; this.#running = false; this.#stderr = ''
    this.#tools = structuredClone(this.host.editorTools())
    const config = this.host.agentConfig?.()
    const fork = this.host.info.forkFrom as string | undefined
    const args = ['--mode', 'rpc', '-e', join(checkoutRoot, 'lisp/agent/backend/pi/emacs-extension.js'),
      ...(resume ? ['--session', resume] : fork ? ['--fork', fork] : []),
      '--model', this.#model(desired), ...(desired.effort ? ['--thinking', desired.effort] : [])]
    // Pi's --no-session takes precedence over --fork/--session, discarding
    // inherited history. Native forks must retain persistence in Pi 1.3.
    if (this.host.info.parent && !fork && !resume) args.push('--no-session')
    const skills = sessionSkills(this.host)
    // An installed emx skill set replaces native discovery, including superseded
    // CLI workflows. Explicit skill roots still load with --no-skills.
    if (skills?.skillsDir) args.push('--no-skills', '--skill', join(skills.skillsDir, '.claude/skills'))
    args.push(...config?.extraArgs ?? [])
    const env = { ...process.env, ...await this.host.environment?.(),
      EMX_DAEMON_SOCKET: this.host.daemonSocket, EMX_SESSION: this.host.id,
      EMX_PI_EMX: join(checkoutRoot, 'bin/emx') }
    const child = spawn(process.env.EMX_PI_EXECUTABLE ?? config?.executable ?? 'pi', args,
      { cwd: this.host.root, env, stdio: 'pipe' })
    this.#process = child
    child.stdin.on('error', () => {})
    child.stderr.setEncoding('utf8').on('data', (data: string) => { this.#stderr = (this.#stderr + data).slice(-8000) })
    let buffer = ''
    child.stdout.setEncoding('utf8').on('data', (data: string) => {
      if (this.#process !== child) return
      buffer += data
      let end: number
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1)
        try { this.#message(JSON.parse(line)) } catch (error) { this.#notice(String(error)) }
      }
    })
    const ended = (error?: Error): void => {
      if (this.#process !== child) return
      this.#cancelDialogs()
      this.#process = undefined; this.#running = false
      this.#finishTexts()
      for (const p of this.#pending.values()) { clearTimeout(p.timer); p.reject(error ?? new Error('Pi RPC exited')) }
      this.#pending.clear()
      this.host.emit({ type: 'usage/end' })
      if (!this.#stopping) {
        this.#notice(error?.message ?? `Pi exited (${child.exitCode ?? child.signalCode}) ${this.#stderr}`)
        this.host.setStatus('exited')
      }
    }
    child.once('error', ended); child.once('close', () => ended())
    try {
      const state = await this.#request('get_state')
      // Without an explicit effort Pi starts at its own default level (high).
      const initial = state.thinkingLevel as string | undefined
      this.#resume = state.sessionId
      if (!this.#resume) throw new Error('Pi did not return a sessionId')
      this.host.setInfo({ sessionId: this.#resume })
      this.#models = (await this.#request('get_available_models')).models ?? []
      const commands = (await this.#request('get_commands')).commands ?? []
      this.host.emit({ type: 'capabilities', capabilities: { modes: permissionModes,
        models: this.#models.filter((m) => allowedModel(modelId(m), config)).map((m) => ({
          id: modelId(m), name: m.name ?? m.id, efforts: efforts(m), defaultEffort: preferredEffort(efforts(m), initial),
        })), commands: commands.map((c: any) => ({ name: c.name, description: c.description })) } })
      await this.configure(desired)
      this.host.setStatus('idle')
    } catch (error) { await this.stop(); throw error }
  }

  async configure(settings: Settings): Promise<void> {
    const previous = { ...this.#confirmed }
    try {
      this.validateSettings(settings)
      const model = this.#model(settings), mode = settings.mode ?? 'edits'
      const offered = this.#models.find((m) => modelId(m) === model)
      if (!offered) throw new Error(`Pi model is not available: ${model}`)
      const supported = efforts(offered)
      let requestedEffort = settings.effort
      if (requestedEffort && offered.thinkingLevelMap && !supported.includes(requestedEffort)) {
        // The editor sends its current effort with a model selection, then
        // clears incompatible effort. Accept that transition atomically.
        if (model !== previous.model && requestedEffort === previous.effort) requestedEffort = undefined
        else throw new Error(`Pi model ${model} does not support thinking level: ${requestedEffort}`)
      }
      let state = await this.#request('get_state')
      if (!state.model || modelId(state.model) !== model) {
        await this.#request('set_model', { provider: offered.provider, modelId: offered.id })
        state = await this.#request('get_state')
      }
      const effort = requestedEffort ?? (supported.includes(state.thinkingLevel) || !supported.length
        ? state.thinkingLevel : preferredEffort(supported, 'high'))
      if (effort && effort !== state.thinkingLevel) {
        await this.#request('set_thinking_level', { level: effort })
        state = await this.#request('get_state')
      }
      if (!state.model || modelId(state.model) !== model || (effort && state.thinkingLevel !== effort)) {
        throw new Error('Pi did not confirm the requested model and thinking level')
      }
      this.#beforePlan = mode === 'plan' ? settings.beforePlan ?? (previous.mode !== 'plan' ? previous.mode : null)
        ?? this.#beforePlan : mode
      this.#confirmed = { model, effort: state.thinkingLevel, mode, beforePlan: this.#beforePlan }
      this.host.setInfo({ model })
      this.host.emit({ type: 'settings', settings: this.#confirmed })
    } catch (error) {
      if (previous.model) this.host.emit({ type: 'settings', settings: previous })
      throw error
    }
  }

  async prepare(): Promise<void> {
    while (this.#resume && !this.host.info.parent && !isDeepStrictEqual(this.#tools, this.host.editorTools())) {
      await this.stop(); await this.start(this.#resume)
    }
  }
  // Pi writes session entries synchronously before subsequent RPC commands.
  async flush(): Promise<void> { await this.#request('get_state') }

  async send(text: string, paths?: string[], block?: string): Promise<void> {
    await this.configure(this.host.settings)
    const attachments = await images(paths)
    this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images: paths })
    this.#cancelled = false; this.#running = true
    this.host.setStatus('running')
    try {
      const result = await this.#request('prompt', { message: text, images: attachments })
      // Extension commands can consume input without starting model work.
      if (result?.disposition === 'handled') {
        const state = await this.#request('get_state')
        if (!state.isStreaming && !state.isCompacting && !state.pendingMessageCount) this.#settled()
      }
    } catch (error) { this.#settled(); throw error }
  }
  steer(text: string, paths?: string[], block?: string): boolean {
    if (!this.#running || !this.alive()) return false
    this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images: paths })
    const child = this.#process
    void images(paths).then((attachments) => {
      if (this.#process === child && this.#running && !this.#cancelled) return this.#request('steer', { message: text, images: attachments })
    }).catch((error) => this.#notice(error.message))
    return true
  }
  interrupt(): void {
    this.#cancelled = true; this.#cancelDialogs()
    if (this.alive()) void this.#request('clear_queue').then(() => this.#request('abort')).catch((error) => this.#notice(error.message))
  }
  #cancelDialogs(): void { for (const cancel of this.#dialogs.values()) cancel(); this.#dialogs.clear() }

  async #approval(request: any): Promise<void> {
    const child = this.#process
    let replied = false
    const reply = (value?: string): void => {
      if (replied) return
      replied = true; this.#dialogs.delete(request.id)
      if (this.#process === child) this.#write({ type: 'extension_ui_response', id: request.id,
        ...(value ? { value } : { cancelled: true }) })
    }
    this.#dialogs.set(request.id, () => reply())
    try {
      const { tool, id, input = {} } = JSON.parse(request.title.slice('emx-approval '.length))
      if (typeof tool !== 'string' || typeof id !== 'string' || this.#cancelled) { reply(); return }
      const mode = this.host.settings.mode ?? this.#confirmed.mode ?? 'edits'
      const readOnly = ['read', 'grep', 'find', 'ls'].includes(tool)
        || this.#tools.readOnly.some((name) => tool === `mcp__emacs__${name}`)
      let choice: string | undefined
      if (readOnly) choice = 'allow'
      else if (mode === 'plan') choice = 'deny-plan'
      else if (mode === 'full' || this.#always.has(tool)) choice = 'allow'
      else if (mode === 'auto' && tool === 'bash') choice = 'allow'
      else if (['edits', 'auto'].includes(mode) && ['write', 'edit'].includes(tool)
        && await contained(this.host.root, input.path)) choice = 'allow'
      else choice = (await this.host.ask({ type: 'approval', tool: id,
        view: toolView(this.host.root, tool, input), choices: ['allow', 'always', 'deny'] })).choice
      if (replied || this.#cancelled) { reply(); return }
      // A live switch to plan also constrains a previously pending approval.
      if (!readOnly && (this.host.settings.mode ?? this.#confirmed.mode) === 'plan') choice = 'deny-plan'
      if (choice === 'always') this.#always.add(tool)
      reply(choice)
    } catch (error) { this.#notice(String(error)); reply() }
  }

  #finishTexts(): void {
    for (const id of this.#texts.values()) this.host.update(id, { done: true })
    this.#texts.clear()
  }
  #text(index: number, kind: 'assistant' | 'thinking', delta?: string, final?: string): void {
    let id = this.#texts.get(index)
    if (!id) {
      if (!this.#messagePrefix) this.#messagePrefix = this.host.newId('pi-message')
      id = `${this.#messagePrefix}-${index}`; this.#texts.set(index, id)
      this.host.addBlock({ id, type: 'text', kind, text: '', done: false })
    }
    if (delta) this.host.append(id, delta)
    if (final !== undefined) this.host.update(id, { kind, text: final, done: true })
  }
  #tool(id: string, name: string, input: any): void {
    this.#calls.set(id, { name, input })
    const view = toolView(this.host.root, name, input)
    if (this.host.blocks.some((b) => b.id === id)) this.host.update(id, { view })
    else this.host.addBlock({ id, type: 'tool', view, status: 'running' })
  }
  #settled(): void {
    this.#running = false; this.#finishTexts(); this.#cancelDialogs()
    this.host.emit({ type: 'usage/end' }); this.host.setStatus('idle')
  }
  #message(event: any): void {
    if (event.type === 'response') {
      const pending = this.#pending.get(event.id)
      if (!pending) return
      this.#pending.delete(event.id); clearTimeout(pending.timer)
      if (event.success) pending.resolve(event.data)
      else pending.reject(new Error(event.error ?? `Pi command failed: ${event.command}`))
      return
    }
    switch (event.type) {
      case 'extension_ui_request':
        if (event.method === 'select' && event.title?.startsWith('emx-approval ')) void this.#approval(event)
        else if (['select', 'confirm', 'input', 'editor'].includes(event.method)) {
          this.#write({ type: 'extension_ui_response', id: event.id, cancelled: true })
          this.#notice(`Unsupported Pi extension dialog: ${event.title ?? event.method}`, 'warning')
        } else if (event.method === 'notify') this.#notice(event.message ?? '', event.notifyType === 'error' ? 'error' : 'warning')
        break
      case 'agent_start': this.#running = true; this.host.setStatus('running'); break
      case 'agent_settled': this.#settled(); break
      case 'message_start':
        if (event.message?.role === 'assistant') {
          this.#finishTexts(); this.#messageCalls.clear(); this.#messagePrefix = this.host.newId('pi-message')
        }
        break
      case 'message_update': {
        const e = event.assistantMessageEvent ?? {}, index = e.contentIndex ?? 0
        const kind = e.type?.startsWith('thinking_') ? 'thinking' : 'assistant'
        if (/^(text|thinking)_(start|delta|end)$/.test(e.type)) {
          this.#text(index, kind, e.delta, e.type.endsWith('_end') ? e.content : undefined)
        } else if (e.type === 'toolcall_end' && e.toolCall) {
          this.#messageCalls.add(e.toolCall.id)
          this.#tool(e.toolCall.id, e.toolCall.name, e.toolCall.arguments ?? {})
        }
        break
      }
      case 'message_end': {
        const message = event.message
        if (message?.role !== 'assistant') break
        const kept = new Set<number>(), calls = new Set<string>()
        ;(message.content ?? []).forEach((part: any, index: number) => {
          if (part.type === 'text' || part.type === 'thinking') {
            kept.add(index); this.#text(index, part.type === 'thinking' ? 'thinking' : 'assistant', undefined,
              part.type === 'thinking' ? part.thinking ?? '' : part.text ?? '')
          } else if (part.type === 'toolCall') {
            calls.add(part.id); this.#tool(part.id, part.name, part.arguments ?? {})
          }
        })
        for (const [index, id] of this.#texts) if (!kept.has(index)) { this.host.remove([id]); this.#texts.delete(index) }
        for (const id of this.#messageCalls) if (!calls.has(id)) { this.host.remove([id]); this.#calls.delete(id) }
        this.#messageCalls.clear()
        if (message.errorMessage) this.#notice(message.errorMessage)
        if (message.stopReason === 'length') this.host.addBlock({ id: this.host.newId('notice'), type: 'notice', notice: { kind: 'max-tokens', level: 'error' } })
        if (message.usage && this.#running) {
          const u = message.usage
          this.host.setInfo({ tokens: u.totalTokens ?? (u.input ?? 0) + (u.output ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0) })
          this.host.emit({ type: 'usage/call', model: message.provider && message.model
            ? `${message.provider}/${message.model}` : String(this.#confirmed.model),
          usage: { input: u.input ?? 0, output: u.output ?? 0, cacheRead: u.cacheRead ?? 0, cacheWrite: u.cacheWrite ?? 0 } })
        }
        this.#finishTexts(); this.#messagePrefix = ''
        break
      }
      case 'tool_execution_start': this.#tool(event.toolCallId, event.toolName, event.args ?? {}); break
      case 'tool_execution_update':
        this.host.update(event.toolCallId, { output: output(event.partialResult) }); break
      case 'tool_execution_end': {
        if (!this.#calls.has(event.toolCallId)) this.#tool(event.toolCallId, event.toolName, {})
        this.host.update(event.toolCallId, { status: event.isError ? 'error' : 'done', output: output(event.result) })
        this.#calls.delete(event.toolCallId)
        break
      }
      case 'extension_error': this.#notice(event.error ?? 'Pi extension error'); break
      case 'auto_retry_start': this.#notice(event.errorMessage ?? `Pi retry ${event.attempt}`, 'warning'); break
      case 'auto_retry_end': if (!event.success && event.finalError) this.#notice(event.finalError); break
      case 'error': this.#notice(event.message ?? event.error ?? 'Pi error'); break
    }
  }

  async stop(): Promise<void> {
    this.#stopping = true; this.#cancelled = true; this.#cancelDialogs()
    const child = this.#process
    if (!child) return
    const closed = once(child, 'close').catch(() => {})
    child.stdin.end()
    const timer = setTimeout(() => child.kill('SIGKILL'), 1000)
    await closed; clearTimeout(timer)
  }
  alive(): boolean { return !!this.#process && this.#process.exitCode === null && !this.#process.killed }
  resumeId(): string | undefined { return this.#resume }
}
