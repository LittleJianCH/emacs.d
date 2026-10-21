import { sessionSkills } from './backend.ts'
// codex.ts --- local Codex app-server peer; no editor process or socket access.

import { spawn } from 'node:child_process'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { once } from 'node:events'
import { isAbsolute, join, relative } from 'node:path'
import { createInterface } from 'node:readline'
import { isDeepStrictEqual } from 'node:util'
import { checkoutRoot } from '../daemon/paths.ts'
import type { Backend, SessionHost } from './backend.ts'
import type { SessionEvent, Settings, ToolStatus, ToolView } from '../daemon/protocol.ts'

export const modes: Record<string, [string, string, string, string]> = {
  ask: ['untrusted', 'readOnly', 'read-only', 'user'],
  edits: ['on-request', 'workspaceWrite', 'workspace-write', 'user'],
  auto: ['on-request', 'workspaceWrite', 'workspace-write', 'auto_review'],
  full: ['never', 'dangerFullAccess', 'danger-full-access', 'user'],
  plan: ['never', 'readOnly', 'read-only', 'user'],
}

/** Preserve configured instructions verbatim, including whitespace. */
export function developerInstructions(result: any): string {
  const config = result?.config
  if (!config || typeof config !== 'object' || Array.isArray(config)
    || (config.developer_instructions != null && typeof config.developer_instructions !== 'string')) {
    throw new Error('Invalid config/read result')
  }
  return (config.developer_instructions == null ? '' : config.developer_instructions + '\n\n')
    + "This session is hosted by the user's Emacs; the conversation UI is an Emacs buffer.\n"
    + 'Unless the user explicitly refers to another application, references to the current page, window, editor, or input box mean Emacs; first discover and call the emacs MCP context tool.\n'
    + 'Use the emacs MCP tools to inspect and operate that UI.'
}

export function itemView(root: string, item: any): ToolView | undefined {
  const path = (value: string): string => isAbsolute(value) ? relative(root, value) : value
  const base = { name: item.type, title: '' }
  switch (item.type) {
    case 'commandExecution': {
      const command = item.command ?? ''
      const inner = command.replace(/^(?:\/bin\/)?(?:ba|z)?sh -l?c '([\s\S]*)'$/, '$1').trim().split('\n')
      return { ...base, kind: 'command', title: inner[0] + (inner.length > 1 ? ' …' : ''), command }
    }
    case 'fileChange': return { ...base, kind: 'edit',
      title: (item.changes ?? []).map((c: any) => path(c.path)).join(', '),
      diff: (item.changes ?? []).map((c: any) => {
        const file = path(c.path), diff = (c.diff ?? '').replace(/\n$/, '')
        if (c.kind?.type === 'add') return `--- /dev/null\n+++ ${file}\n` + diff.split('\n').map((s: string) => '+' + s).join('\n')
        if (c.kind?.type === 'delete') return `--- ${file}\n+++ /dev/null`
        return diff.startsWith('---') ? diff : `--- ${file}\n+++ ${file}\n${diff}`
      }).join('\n') }
    case 'mcpToolCall': return { ...base, kind: 'mcp', title: `${item.server} · ${item.tool}` }
    case 'dynamicToolCall': return { ...base, kind: 'other', title: item.tool }
    case 'webSearch': return { ...base, kind: 'web', title: item.query ?? '' }
    case 'plan': return { ...base, kind: 'plan' }
    case 'imageView': return { ...base, kind: 'read', title: path(item.path), path: path(item.path) }
    case 'collabAgentToolCall': return { ...base, kind: 'task', title: item.prompt ?? '' }
  }
}

/** JSON strings are TOML basic strings too; each table key is emitted once. */
export function launchArgs(host: SessionHost, readOnly = host.editorTools().readOnly): string[] {
  const config = codexConfig(host)
  const context = sessionSkills(host)
  const overrides: Record<string, unknown> = {
    'mcp_servers.emacs.command': process.execPath,
    'mcp_servers.emacs.args': [join(checkoutRoot, 'bin/emx'), 'mcp'],
    'mcp_servers.emacs.tool_timeout_sec': 1800,
  }
  for (const name of readOnly) {
    // Quote non-bare names so a dot cannot turn one tool into nested tables.
    const key = /^[A-Za-z0-9_-]+$/.test(name) ? name : JSON.stringify(name)
    overrides[`mcp_servers.emacs.tools.${key}.approval_mode`] = 'approve'
  }
  // TOML inline tables use '=' rather than JSON's ':'.
  const args = ['app-server', ...Object.entries(overrides).flatMap(([key, value]) => ['-c', `${key}=${JSON.stringify(value)}`]),
    '-c', `mcp_servers.emacs.env={EMX_DAEMON_SOCKET=${JSON.stringify(host.daemonSocket)},EMX_SESSION=${JSON.stringify(host.id)}}`]
  if (!config.nativeSubagents) args.push('-c', 'agents.enabled=false')
  if (context?.supersededSkills?.length) args.push('-c', 'skills.config=[' + context.supersededSkills
    .map((name) => `{name=${JSON.stringify(name)},enabled=false}`).join(',') + ']')
  return [...args, ...(config.extraArgs ?? [])]
}

/** Transitional daemon configuration, independent of the Lisp backend options. */
function codexConfig(host?: SessionHost): { executable?: string, nativeSubagents?: boolean, extraArgs?: string[] } {
  const config = JSON.parse(process.env.EMX_CODEX_CONFIG ?? '{}')
  if (!config || typeof config !== 'object' || Array.isArray(config)
    || (config.executable !== undefined && typeof config.executable !== 'string')
    || (config.nativeSubagents !== undefined && typeof config.nativeSubagents !== 'boolean')
    || (config.extraArgs !== undefined && (!Array.isArray(config.extraArgs) || !config.extraArgs.every((s: unknown) => typeof s === 'string')))) {
    throw new Error('Invalid EMX_CODEX_CONFIG')
  }
  return { ...host?.agentConfig?.(), ...config }
}

export class CodexBackend implements Backend {
  readonly host: SessionHost
  #process?: ChildProcessWithoutNullStreams
  #pending = new Map<number, { resolve: (value: any) => void, reject: (error: Error) => void, timer: NodeJS.Timeout }>()
  #next = 0
  #resume?: string
  #turn?: string
  #completedTurn?: string
  #interruptPending = false
  #stopping = false
  #tools: unknown
  #usageTotal: unknown
  #rateReading?: Extract<SessionEvent, { type: 'quota/rate-limits' }>['rateLimits']
  #texts = new Set<string>()
  #users = new Map<string, string>()
  #pendingUsers: { id: string, text: string, imageCount: number }[] = []

  constructor(host: SessionHost) { this.host = host }

  #write(message: object): void {
    this.#process?.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
  }

  #request(method: string, params: unknown = {}): Promise<any> {
    const id = ++this.#next
    return new Promise((resolve, reject) => {
      if (!this.alive()) { reject(new Error('Codex is not running')); return }
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error(`Codex request timed out: ${method}`)) }, 120000)
      this.#pending.set(id, { resolve, reject, timer })
      this.#write({ id, method, params })
    })
  }

  #notice(kind: string, message?: string): void {
    this.host.addBlock({ id: this.host.newId('notice'), type: 'notice',
      notice: { kind, ...(message === undefined ? {} : { args: { message }, level: 'error' }) } })
  }

  async start(resume?: string): Promise<void> {
    if (!isAbsolute(this.host.root) || /^\/[^/]+:/.test(this.host.root)) {
      throw new Error('Codex daemon sessions require a local absolute root; remote projects are not supported')
    }
    this.#stopping = false
    this.#turn = undefined
    this.#completedTurn = undefined
    this.#usageTotal = undefined
    const env = await this.host.environment?.()
    const tools = structuredClone(this.host.editorTools())
    this.#tools = tools
    const child = spawn(process.env.EMX_CODEX_EXECUTABLE ?? codexConfig(this.host).executable ?? 'codex', launchArgs(this.host, tools.readOnly),
      { cwd: this.host.root, env, stdio: 'pipe' })
    this.#process = child
    child.stdin.on('error', () => {})
    child.stderr.resume()
    createInterface({ input: child.stdout }).on('line', (line) => {
      let message: any
      try { message = JSON.parse(line) } catch { return }
      this.#message(message)
    })
    const ended = (error?: Error): void => {
      if (this.#process !== child) return
      this.#process = undefined
      if (this.#turn) this.host.emit({ type: 'usage/end' })
      this.#turn = undefined
      this.#pendingUsers = []
      for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error ?? new Error('Codex app-server exited')) }
      this.#pending.clear()
      if (!this.#stopping) {
        this.#notice('backend-error', error?.message ?? `Codex exited (${child.exitCode ?? child.signalCode})`)
        this.host.setStatus('exited')
      }
    }
    child.once('error', ended)
    child.once('close', () => ended())
    await this.#request('initialize', { clientInfo: { name: 'emacs', title: 'Emacs', version: 'emx' } })
    this.#write({ method: 'initialized' })
    const models = await this.#request('model/list', { limit: 50 })
    this.host.emit({ type: 'capabilities', capabilities: { modes: Object.keys(modes), commands: [],
      models: (models.data ?? []).filter((m: any) => !m.hidden).map((m: any) => ({ id: m.model,
        name: m.displayName, description: m.description,
        efforts: (m.supportedReasoningEfforts ?? []).map((e: any) => e.reasoningEffort),
        defaultEffort: m.defaultReasoningEffort })) } })
    const context = sessionSkills(this.host)
    if (context?.skillsDir) await this.#request('skills/extraRoots/set', { extraRoots: [join(context.skillsDir, '.claude/skills')] })
    let instructions: string | undefined
    try { instructions = developerInstructions(await this.#request('config/read', { cwd: this.host.root })) }
    catch (error) { this.#notice('codex-config-read-failed', (error as Error).message) }
    const mode = modes[this.host.settings.mode ?? 'edits'] ?? modes.edits
    const fork = this.host.info.forkFrom as string | undefined
    const result = fork ? await this.#request('thread/fork', { threadId: fork, ephemeral: true, excludeTurns: true })
      : await this.#request(resume ? 'thread/resume' : 'thread/start', {
      cwd: this.host.root, approvalPolicy: mode[0], sandbox: mode[2],
      ...(instructions === undefined ? {} : { developerInstructions: instructions }),
      ...(this.host.settings.model ? { model: this.host.settings.model } : {}),
      ...(resume ? { threadId: resume, excludeTurns: true } : {}),
      ...(this.host.info.parent ? { ephemeral: true } : {}),
    })
    this.#resume = result.thread.id
    this.host.setInfo({ sessionId: this.#resume, model: this.host.settings.model ?? result.model })
    if (resume && !this.host.blocks.length) {
      // Fetch all pages once; Session owns attach/earlier slicing thereafter.
      let cursor: string | undefined
      const seen = new Set<string>()
      do {
        const page = await this.#request('thread/turns/list', { threadId: this.#resume, itemsView: 'full', sortDirection: 'asc', limit: 200,
          ...(cursor ? { cursor } : {}) })
        for (const turn of page.data ?? []) for (const item of turn.items ?? []) this.#item(item, true, true)
        cursor = page.nextCursor ?? undefined
        if (cursor && seen.has(cursor)) throw new Error('Codex history repeated its cursor')
        if (cursor) seen.add(cursor)
      } while (cursor)
      this.#notice('history-end')
    }
    await this.#quota()
    this.host.setStatus('idle')
  }

  configure(settings: Settings): void {
    // app-server takes all settings on turn/start; changes apply next turn.
    if (Object.hasOwn(settings, 'model')) this.host.setInfo({ model: settings.model })
  }

  #input(text: string, images?: string[]): object[] {
    return [...(text ? [{ type: 'text', text }] : []), ...(images ?? []).map((path) => ({ type: 'localImage', path }))]
  }

  #addUser(text: string, images?: string[], block?: string): string {
    const id = block ?? this.host.newId('user')
    this.host.addBlock({ id, type: 'user', text, images })
    this.#pendingUsers.push({ id, text, imageCount: images?.length ?? 0 })
    return id
  }

  async prepare(): Promise<void> {
    while (this.#resume && !this.host.info.parent && !isDeepStrictEqual(this.#tools, this.host.editorTools())) {
      this.#notice('codex-tools-changed')
      await this.stop()
      await this.start(this.#resume)
    }
  }

  async send(text: string, images?: string[], block?: string): Promise<void> {
    this.#interruptPending = false
    this.#addUser(text, images, block)
    this.host.setStatus('running')
    const settings = this.host.settings, mode = modes[settings.mode ?? 'edits'] ?? modes.edits
    const result = await this.#request('turn/start', { threadId: this.#resume, input: this.#input(text, images), summary: 'detailed',
      approvalPolicy: mode[0], approvalsReviewer: mode[3], sandboxPolicy: { type: mode[1] },
      ...(settings.model ? { model: settings.model } : {}), ...(settings.effort ? { effort: settings.effort } : {}) })
    // turn/started normally precedes the response. Do not revive a completed turn.
    if (!this.#turn && result.turn?.status === 'inProgress' && result.turn.id !== this.#completedTurn) {
      this.#turn = result.turn.id
      if (this.#interruptPending) { this.#interruptPending = false; this.interrupt() }
    }
  }

  steer(text: string, images?: string[], block?: string): boolean {
    if (!this.#turn || !this.alive()) return false
    const id = this.#addUser(text, images, block)
    void this.#request('turn/steer', { threadId: this.#resume, expectedTurnId: this.#turn, input: this.#input(text, images) })
      .catch((e) => {
        this.#pendingUsers = this.#pendingUsers.filter((user) => user.id !== id)
        this.#notice('backend-error', e.message)
      })
    return true
  }

  interrupt(): void {
    if (!this.#turn) { this.#interruptPending = true; return }
    void this.#request('turn/interrupt', { threadId: this.#resume, turnId: this.#turn }).catch((e) => this.#notice('backend-error', e.message))
  }

  async #quota(): Promise<void> {
    try { this.#rateLimits((await this.#request('account/rateLimits/read')).rateLimits) } catch { /* Supplemental account data. */ }
  }

  #rateLimits(snapshot: any): void {
    if (!snapshot) return
    const reading = {
      ...(snapshot.planType == null ? {} : { plan: snapshot.planType }),
      windows: ['primary', 'secondary'].flatMap((key) => {
        const w = snapshot[key]
        return w ? [{ id: String(w.windowDurationMins ?? key), minutes: w.windowDurationMins ?? null,
          used: (w.usedPercent ?? 0) / 100, resets: w.resetsAt ?? null }] : []
      }),
      ...(snapshot.credits?.unlimited ? { credits: 'unlimited' as const }
        : snapshot.credits?.balance != null ? { credits: Number(snapshot.credits.balance) } : {}),
    }
    const windows = new Map((this.#rateReading?.windows ?? []).map((w) => [w.id, w]))
    for (const window of reading.windows) windows.set(window.id, window)
    this.#rateReading = { ...this.#rateReading, ...reading, windows: [...windows.values()] }
    this.host.emit({ type: 'quota/rate-limits', rateLimits: reading })
  }

  reattached(): void {
    if (this.#rateReading) this.host.emit({ type: 'quota/rate-limits', rateLimits: this.#rateReading })
  }

  #message(message: any): void {
    if (!message.method) {
      const pending = this.#pending.get(message.id)
      if (!pending) return
      this.#pending.delete(message.id); clearTimeout(pending.timer)
      if (message.error) pending.reject(new Error(message.error.message))
      else pending.resolve(message.result)
      return
    }
    const p = message.params ?? {}
    if (message.id !== undefined) { void this.#ask(message.id, message.method, p); return }
    if (p.threadId && this.#resume && p.threadId !== this.#resume) return
    switch (message.method) {
      case 'turn/started':
        this.#turn = p.turn.id
        this.host.setStatus('running')
        if (this.#interruptPending) { this.#interruptPending = false; this.interrupt() }
        break
      case 'turn/completed':
        if (p.turn.error) this.#notice('backend-error', p.turn.error.message)
        this.#completedTurn = p.turn.id
        this.#turn = undefined
        this.#pendingUsers = []
        this.host.emit({ type: 'usage/end' })
        void this.#quota()
        this.host.setStatus('idle'); break
      case 'item/started': this.#item(p.item, false); break
      case 'item/completed': this.#item(p.item, true); break
      case 'item/agentMessage/delta': this.#text(p.itemId, 'assistant', p.delta); break
      case 'item/reasoning/summaryTextDelta': case 'item/reasoning/textDelta': this.#text(p.itemId + '-thinking', 'thinking', p.delta); break
      case 'item/commandExecution/outputDelta': this.host.append(p.itemId, p.delta); break
      case 'turn/plan/updated': {
        const id = p.turnId + '-plan'
        const view: ToolView = { kind: 'plan', name: 'plan', title: '', items: (p.plan ?? []).map((s: any) => ({ text: s.step,
          status: s.status === 'completed' ? 'done' : s.status === 'inProgress' ? 'active' : 'pending' })) }
        if (this.host.blocks.some((b) => b.id === id)) this.host.update(id, { view, status: 'done', output: p.explanation })
        else this.host.addBlock({ id, type: 'tool', view, status: 'done', output: p.explanation })
        break
      }
      case 'thread/tokenUsage/updated': {
        const usage = p.tokenUsage, last = usage?.last
        if (!last) break
        this.host.setInfo({ tokens: last.totalTokens })
        if (this.#turn && !isDeepStrictEqual(usage.total, this.#usageTotal)) {
          this.#usageTotal = structuredClone(usage.total)
          const cached = last.cachedInputTokens ?? 0, written = last.cacheWriteInputTokens ?? 0
          this.host.emit({ type: 'usage/call', model: String(this.host.info.model ?? 'codex'), usage: {
            input: Math.max(0, (last.inputTokens ?? 0) - cached - written), cacheRead: cached,
            cacheWrite: written, output: last.outputTokens ?? 0 } })
        }
        break
      }
      case 'account/rateLimits/updated': this.#rateLimits(p.rateLimits); break
      case 'model/rerouted': this.host.setInfo({ model: p.toModel }); break
      case 'error': if (!p.willRetry) this.#notice('backend-error', p.error?.message ?? 'Codex error'); break
    }
  }

  #text(id: string, kind: 'thinking' | 'assistant', delta?: string, final?: string): void {
    if (!this.#texts.has(id)) {
      this.#texts.add(id)
      this.host.addBlock({ id, type: 'text', kind, text: '', done: false })
    }
    if (delta) this.host.append(id, delta)
    if (final !== undefined) this.host.update(id, { text: final, done: true })
  }

  #item(item: any, done: boolean, history = false): void {
    const id: string = item.id
    if (item.type === 'userMessage') {
      const text = (item.content ?? []).map((p: any) => p.text ?? '').join('')
      const imageCount = (item.content ?? []).filter((p: any) => p.type === 'image' || p.type === 'localImage').length
      let blockId = this.#users.get(id)
      if (!blockId) {
        // Only live echoes consume client messages; history owns its item ids.
        const pending = history ? -1 : this.#pendingUsers.findIndex((user) => user.text === text && user.imageCount === imageCount)
        blockId = pending < 0 ? id : this.#pendingUsers.splice(pending, 1)[0].id
        this.#users.set(id, blockId)
      }
      const existing = this.host.blocks.find((block) => block.id === blockId)
      if (existing?.type === 'user') {
        const fields: Record<string, unknown> = {}
        if (existing.text !== text) fields.text = text
        if ((existing.images?.length ?? existing.imageCount ?? 0) !== imageCount) fields.imageCount = imageCount
        if (Object.keys(fields).length) this.host.update(blockId, fields)
      } else this.host.addBlock({ id: blockId, type: 'user', text, imageCount })
    } else if (item.type === 'agentMessage') {
      this.#text(id, 'assistant', undefined, done ? item.text ?? '' : undefined)
    } else if (item.type === 'reasoning') {
      const textId = id + '-thinking'
      if (done && this.#texts.has(textId)) this.host.update(textId, { done: true })
      else if (done) this.#text(textId, 'thinking', undefined, [...(item.summary ?? []), ...(item.content ?? [])]
        .map((s: any) => typeof s === 'string' ? s : s.text ?? '').join('\n'))
    } else {
      const view = itemView(this.host.root, item)
      if (!view) return
      const output = item.type === 'commandExecution' ? item.aggregatedOutput
        : item.type === 'mcpToolCall' ? item.error ? String(item.error.message ?? item.error)
          : item.result?.content?.map((c: any) => c.text ?? '').join('\n')
        : item.type === 'plan' ? item.text : undefined
      const status: ToolStatus = !done || ['inProgress', 'in_progress'].includes(item.status) ? 'running'
        : item.status === 'declined' ? 'declined'
        : ['failed', 'error'].includes(item.status) || item.exitCode ? 'error' : 'done'
      const fields = { view, status, ...(output === undefined ? {} : { output }) }
      if (this.host.blocks.some((b) => b.id === id)) this.host.update(id, fields)
      else this.host.addBlock({ id, type: 'tool', ...fields })
    }
  }

  async #ask(id: string | number, method: string, params: any): Promise<void> {
    // A cancelled ask from an old process must never reply into its replacement.
    const child = this.#process
    let result: any
    if (['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'].includes(method)) {
      const block = this.host.blocks.find((b) => b.id === params.itemId)
      const answer = await this.host.ask({ type: 'approval', tool: params.itemId,
        view: block?.type === 'tool' ? block.view : itemView(this.host.root,
          method.includes('commandExecution') ? { type: 'commandExecution', command: params.command } : { type: 'fileChange', changes: params.changes }),
        description: params.reason, choices: ['allow', 'always', 'deny'] })
      result = { decision: answer.choice === 'allow' ? 'accept' : answer.choice === 'always' ? 'acceptForSession' : 'decline' }
    } else if (method === 'item/tool/requestUserInput') {
      const questions = params.questions ?? []
      const answer = await this.host.ask({ type: 'question', tool: params.itemId, questions: questions.map((q: any) => ({
        question: q.question, header: q.header, options: q.options, other: q.isOther, secret: q.isSecret })) })
      result = { answers: Object.fromEntries(questions.flatMap((q: any, index: number) => {
        const entry = answer.answers?.[index]
        return entry && (entry.selected.length || entry.custom)
          ? [[q.id, { answers: [...entry.selected, ...(entry.custom ? [entry.custom] : [])] }]] : []
      })) }
    } else {
      if (this.#process === child) this.#write({ id, error: { code: -32601, message: `Unsupported Codex request: ${method}` } })
      return
    }
    if (this.#process === child) this.#write({ id, result })
  }

  async stop(): Promise<void> {
    this.#stopping = true
    const child = this.#process
    if (!child) return
    const closed = once(child, 'close').catch(() => {})
    child.kill('SIGTERM')
    const timer = setTimeout(() => child.kill('SIGKILL'), 1000)
    await closed; clearTimeout(timer)
  }

  alive(): boolean { return !!this.#process && this.#process.exitCode === null && !this.#process.killed }
  resumeId(): string | undefined { return this.#resume }
}
