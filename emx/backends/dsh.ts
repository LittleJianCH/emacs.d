// dsh.ts --- peer of the dsh Emacs bridge plugin, for local sessions.

import { spawn } from 'node:child_process'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { once } from 'node:events'
import { isAbsolute, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkoutRoot } from '../daemon/paths.ts'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import type { Backend, SessionHost } from './backend.ts'
import type { Settings, ToolView } from '../daemon/protocol.ts'

/** The bridge depends on dsh internals; other versions warrant a notice. */
export const testedVersion = '0.2.0-rc.2'
export const presets: Record<string, string> = {
  ask: 'read-only', edits: 'workspace-write', auto: 'auto', full: 'danger-full-access',
}
const patch = fileURLToPath(new URL('../../lisp/agent/backend/dsh/emacs.yml', import.meta.url))
const noSubagents = fileURLToPath(new URL('../../lisp/agent/backend/dsh/no-subagents.yml', import.meta.url))
const quiet = new Set(['todo_write', 'exit_plan_mode', 'write', 'edit'])

/** Match the Lisp display diff, including the absence of trailing empty lines. */
export function diff(path: string, old?: string, updated?: string): string {
  const lines = (prefix: string, text?: string): string[] => !text ? []
    : text.replace(/\n$/, '').split('\n').map((line) => prefix + line)
  return [`--- ${path}\n+++ ${path}`, ...lines('-', old), ...lines('+', updated)].join('\n')
}

/** Normalize bridge tool arguments without introducing editor UI wording. */
export function toolView(root: string, name: string, args: any): ToolView {
  const raw = args.file_path ?? args.path
  const path = typeof raw === 'string' && isAbsolute(raw) ? relative(root, raw) : raw
  const view: ToolView = { kind: 'other', name, title: path ?? name }
  switch (name) {
    case 'bash': return { ...view, kind: 'command', title: (args.command ?? '').trim().split('\n')[0],
      command: args.command ?? '' }
    case 'read': case 'read_image': return { ...view, kind: 'read', path }
    case 'write': case 'edit': return { ...view, kind: 'edit', path,
      diff: diff(path ?? '', name === 'edit' ? args.old_string : undefined,
        name === 'edit' ? args.new_string : args.content) }
    case 'grep': case 'glob': return { ...view, kind: 'search', title: `${name} ${args.pattern ?? ''}` }
    case 'web_fetch': return { ...view, kind: 'web', title: args.url ?? name }
    case 'web_search': return { ...view, kind: 'web', title: (args.queries ?? []).join(' · ') }
    case 'subagent': case 'subagent_fork': return { ...view, kind: 'task', title: args.description ?? name }
    case 'todo_write': return { ...view, kind: 'plan', title: '',
      items: (args.todos ?? []).map((todo: any) => ({ text: todo.content,
        status: todo.status === 'completed' ? 'done' : todo.status === 'in_progress' ? 'active' : 'pending' })) }
    case 'exit_plan_mode': return { ...view, kind: 'plan', title: '' }
    case 'skill': return { ...view, title: args.name ?? name }
    default: return name.startsWith('mcp__')
      ? { ...view, kind: 'mcp', title: name.split('__').slice(1).join(' · ') } : view
  }
}

export class DshBackend implements Backend {
  readonly host: SessionHost
  #process: ChildProcessWithoutNullStreams | undefined
  #pending = new Map<number, { resolve: (value: any) => void, reject: (error: Error) => void,
    timer: NodeJS.Timeout }>()
  #next = 0
  #resume: string | undefined
  #running = false
  #turnError = false
  #stopping = false
  #confirmed: Settings = {}
  #beforePlan = 'edits'
  #configuration: Promise<void> = Promise.resolve()
  #tools = new Map<string, string>()
  #texts = new Set<string>()

  constructor(host: SessionHost) { this.host = host }

  #write(message: unknown): void {
    if (this.#process?.stdin.writable) this.#process.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message as object }) + '\n')
  }

  #request(method: string, params: unknown = {}): Promise<any> {
    const id = ++this.#next
    return new Promise((resolve, reject) => {
      if (!this.alive()) { reject(new Error('dsh is not running')); return }
      const timer = setTimeout(() => {
        this.#pending.delete(id)
        reject(new Error(`dsh request timed out: ${method}`))
      }, method === 'balance' ? 15_000 : 120_000)
      this.#pending.set(id, { resolve, reject, timer })
      this.#write({ id, method, params })
    })
  }

  #notice(kind: string, args?: Record<string, string | number | boolean>, level?: 'error' | 'warning'): void {
    this.host.addBlock({ id: this.host.newId('notice'), type: 'notice', notice: { kind, args, level } })
  }

  async start(resume?: string): Promise<void> {
    if (!isAbsolute(this.host.root) || /^\/[^/]+:/.test(this.host.root)) {
      throw new Error('dsh daemon sessions require a local absolute root; remote projects are not supported')
    }
    this.#stopping = false
    const desired = { ...this.host.settings }
    this.#beforePlan = desired.beforePlan ?? 'edits'
    const mode = desired.mode ?? 'edits'
    if (mode !== 'plan') this.#beforePlan = mode
    // An executable override supports installations outside PATH and protocol fixtures.
    const config = this.host.agentConfig?.()
    const child = spawn(process.env.EMX_DSH_EXECUTABLE ?? config?.executable ?? 'dsh',
      ['--profile', 'sdk', '--patch', patch,
        ...config?.nativeSubagents ? [] : ['--patch', noSubagents], ...(config?.extraArgs ?? [])],
      { cwd: this.host.root, stdio: 'pipe' })
    this.#process = child
    child.stdin.on('error', () => {})
    child.stderr.resume()
    createInterface({ input: child.stdout }).on('line', (line) => {
      try { this.#message(JSON.parse(line)) } catch { /* dsh may log before the bridge loads. */ }
    })
    const ended = (error?: Error): void => {
      if (this.#process !== child) return
      this.#process = undefined
      this.#running = false
      for (const pending of this.#pending.values()) {
        clearTimeout(pending.timer)
        pending.reject(error ?? new Error('dsh bridge exited'))
      }
      this.#pending.clear()
      if (!this.#stopping) {
        this.#notice('backend-error', { message: error?.message ?? `dsh exited (${child.exitCode ?? child.signalCode})` }, 'error')
        this.host.setStatus('exited')
      }
    }
    child.once('error', ended)
    child.once('close', () => ended())
    const result = await this.#request('initialize', {
      cwd: this.host.root.replace(/\/$/, '') || '/', preset: presets[mode === 'plan' ? this.#beforePlan : mode] ?? presets.edits,
      plan: mode === 'plan', mcpServers: [{ name: 'emacs', command: process.execPath,
        args: [join(checkoutRoot, 'bin/emx'), 'mcp'],
        env: { EMX_DAEMON_SOCKET: this.host.daemonSocket, EMX_SESSION: this.host.id },
        timeoutMs: 1800000, readOnly: this.host.editorTools().readOnly }], resume,
      parent: this.host.info.parentSession ?? this.host.info.parent, forkFrom: this.host.info.forkFrom, model: desired.model ?? undefined,
      effort: desired.effort ?? undefined,
    })
    this.#resume = result.sessionId
    this.host.setInfo({ sessionId: this.#resume, ...(result.title && !this.host.info.title ? { title: result.title } : {}) })
    this.host.emit({ type: 'capabilities', capabilities: {
      models: (result.models ?? []).map((model: any) => ({ ...model,
        efforts: (model.efforts ?? []).map((effort: any) => effort.id) })),
      modes: [...Object.keys(presets).filter((mode) => !result.presets || result.presets.includes(presets[mode])),
        ...result.plan ? ['plan'] : []], commands: result.commands ?? [],
    } })
    // Resume restores the logged route rather than initialize's choices.
    this.#config(result.config)
    await this.configure({ ...this.host.settings, ...desired })
    if (!this.host.blocks.length && result.history?.length) {
      for (const item of result.history) this.#notification(item.method, item.params, true)
      this.#notice('history-end')
    }
    for (const message of result.warnings ?? []) this.#notice('dsh-warning', { message }, 'warning')
    if (result.version && result.version !== testedVersion) {
      this.#notice('dsh-version', { version: result.version, tested: testedVersion })
    }
    void this.#balance()
    this.host.setStatus('idle')
  }

  #config(config: any): void {
    if (!config) return
    this.host.setInfo({ model: config.model })
    const settings: Settings = { model: config.model, effort: config.effort }
    settings.mode = config.plan ? 'plan'
      : Object.keys(presets).find((mode) => presets[mode] === config.preset) ?? this.#beforePlan
    if (settings.mode !== 'plan') this.#beforePlan = settings.mode
    settings.beforePlan = this.#beforePlan
    // Only bridge reports advance confirmed settings, including plan reviews.
    this.#confirmed = { ...settings }
    this.host.emit({ type: 'settings', settings })
  }

  configure(settings: Settings): Promise<void> {
    const desired = { ...settings }
    const task = this.#configuration.then(() => this.#configure(desired))
    this.#configuration = task.catch(() => {})
    return task
  }

  async #configure(settings: Settings): Promise<void> {
    const previous = this.#confirmed
    const changed = (['model', 'effort', 'mode'] as const).filter((key) => settings[key] !== previous[key])
    if (!changed.length) return
    const params: any = {}
    if (changed.includes('model') || changed.includes('effort')) {
      params.model = settings.model ?? null
      params.effort = settings.effort ?? null
    }
    if (changed.includes('mode')) {
      const beforePlan = settings.beforePlan ?? (previous.mode !== 'plan' ? previous.mode : null) ?? this.#beforePlan
      const mode = settings.mode ?? 'edits'
      params.preset = presets[mode === 'plan' ? beforePlan : mode] ?? presets.edits
      params.plan = mode === 'plan'
    }
    try {
      const result = await this.#request('configure', params)
      this.#config(result.config)
    } catch (error) {
      this.host.emit({ type: 'settings', settings: { ...this.#confirmed } })
      this.#notice('backend-error', { message: (error as Error).message }, 'error')
      throw error
    }
  }

  async flush(): Promise<void> { await this.#request('flush') }

  async send(text: string, images?: string[], block?: string): Promise<void> {
    this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images })
    this.#running = true
    this.#turnError = false
    this.host.setStatus('running')
    const result = await this.#request('prompt', { text, images })
    if (result.command) {
      this.#notice(result.command.kind === 'error' ? 'command-error' : 'command-result',
        result.command.text == null && result.command.kind !== 'error'
          ? undefined : { message: result.command.text ?? '' },
        result.command.kind === 'error' ? 'error' : undefined)
      if (result.status === 'idle') { this.#running = false; this.host.setStatus('idle') }
    }
  }

  steer(text: string, images?: string[], block?: string): boolean {
    if (!this.#running || !this.alive()) return false
    this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images })
    void this.#request('steer', { text, images }).catch((error) => this.#notice('backend-error', { message: error.message }, 'error'))
    return true
  }

  interrupt(): void {
    if (this.alive()) void this.#request('cancel').catch(() => {})
  }

  async #balance(): Promise<void> {
    try {
      const result = await this.#request('balance')
      const balance = (result.balances ?? []).filter((entry: any) => entry.total != null)
        .map((entry: any) => ({ amount: Number(entry.total), currency: entry.currency }))
        .filter((entry: any) => Number.isFinite(entry.amount) && typeof entry.currency === 'string')
      if (balance.length && !this.#stopping) this.host.emit({ type: 'quota', balance })
    } catch { /* Balance is supplemental; failure must not interrupt a turn. */ }
  }

  #message(message: any): void {
    if (message.method) {
      if (message.id !== undefined) void this.#ask(message.id, message.method, message.params ?? {})
      else this.#notification(message.method, message.params ?? {})
    } else {
      const pending = this.#pending.get(message.id)
      if (!pending) return
      this.#pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.error) pending.reject(new Error(message.error.message))
      else pending.resolve(message.result)
    }
  }

  async #ask(id: string | number, method: string, params: any): Promise<void> {
    if (method === 'approval') {
      const block = this.host.blocks.find((block) => block.id === params.callId)
      const answer = await this.host.ask({ type: 'approval', tool: params.callId,
        view: block?.type === 'tool' ? block.view : toolView(this.host.root, params.toolName, {}),
        description: params.reason, choices: ['allow', 'deny'] })
      this.#write({ id, result: { decision: answer.choice === 'allow' ? 'allow' : 'reject' } })
    } else if (method === 'question') {
      const questions = params.questions ?? []
      const answer = await this.host.ask({ type: 'question', tool: params.callId,
        questions: questions.map((q: any) => ({ question: q.question, header: q.header,
          detail: q.detail, options: q.options, multi: q.multiSelect, other: true, intent: q.intent })) })
      this.#write({ id, result: { answers: questions.map((q: any, index: number) => ({ id: q.id,
        selected: answer.answers?.[index]?.selected ?? [],
        ...(answer.answers?.[index]?.custom ? { custom: answer.answers[index].custom } : {}) })) } })
    } else this.#write({ id, error: { code: -32601, message: `Unsupported bridge request: ${method}` } })
  }

  #notification(method: string, params: any, history = false): void {
    const id = params.id
    switch (method) {
      case 'status':
        this.#running = params.status === 'running'
        this.host.setStatus(this.#running ? 'running' : 'idle'); break
      case 'user': this.host.addBlock({ id, type: 'user', text: params.text ?? '', imageCount: params.images ?? 0 }); break
      case 'text':
      case 'text/done': {
        if (!this.#texts.has(id)) {
          this.#texts.add(id)
          this.host.addBlock({ id, type: 'text', kind: params.kind === 'thinking' ? 'thinking' : 'assistant', text: '', done: false })
        }
        if (method === 'text') this.host.append(id, params.delta ?? '')
        else this.host.update(id, { done: true, ...(params.text === undefined ? {} : { text: params.text }) })
        break
      }
      case 'discard':
        this.host.remove(params.ids)
        for (const id of params.ids) { this.#texts.delete(id); this.#tools.delete(id) }
        break
      case 'tool': {
        let args = {}
        try { args = JSON.parse(params.arguments) ?? {} } catch { /* Partial/invalid arguments. */ }
        this.#tools.set(id, params.name)
        this.host.addBlock({ id, type: 'tool', view: toolView(this.host.root, params.name, args),
          status: 'running', ...(params.name === 'exit_plan_mode' ? { output: (args as any).plan } : {}) })
        break
      }
      case 'tool/done': {
        const name = this.#tools.get(id)
        if (name) this.host.update(id, { status: params.isError ? 'error' : 'done',
          ...quiet.has(name) && !params.isError ? {} : { output: params.output } })
        this.#tools.delete(id)
        break
      }
      case 'turn/end':
        if (history) break
        // Some dsh failures (e.g. request extension preparation) emit only
        // turn/end, without agent/error. Avoid both silent and duplicate errors.
        if (params.reason === 'error' && !this.#turnError) {
          this.#notice('backend-error', { message: params.error ?? 'dsh turn failed' }, 'error')
        }
        if (params.reason === 'max-tokens') this.#notice('max-tokens', undefined, 'error')
        this.host.emit({ type: 'usage/end' })
        void this.#balance()
        break
      case 'config': this.#config(params.config); break
      case 'usage':
        this.host.setInfo({ tokens: params.usage.totalTokens })
        if (!history && this.#running) this.host.emit({ type: 'usage/call', model: params.model ?? String(this.host.info.model ?? 'dsh'),
          usage: { input: params.usage.inputTokens ?? 0, cacheRead: params.usage.cacheReadTokens ?? 0,
            cacheWrite: params.usage.cacheWriteTokens ?? 0, output: params.usage.outputTokens ?? 0 } })
        break
      case 'error':
        this.#turnError = true
        this.#notice('backend-error', { message: params.message }, 'error'); break
    }
  }

  async stop(): Promise<void> {
    this.#stopping = true
    const child = this.#process
    if (!child) return
    const closed = once(child, 'close').catch(() => {})
    child.kill('SIGTERM')
    const timer = setTimeout(() => child.kill('SIGKILL'), 1000)
    await closed
    clearTimeout(timer)
  }

  alive(): boolean { return !!this.#process && this.#process.exitCode === null && !this.#process.killed }
  resumeId(): string | undefined { return this.#resume }
}
