import { sessionSkills } from './backend.ts'
// claude.ts --- local Claude Code stream-json peer and streaming transcript reader.

import { spawn } from 'node:child_process'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { once } from 'node:events'
import { createReadStream, watch } from 'node:fs'
import type { FSWatcher } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, relative } from 'node:path'
import { createInterface } from 'node:readline'
import { checkoutRoot } from '../daemon/paths.ts'
import type { Backend, SessionHost } from './backend.ts'
import type { Block, SessionEvent, Settings, ToolView, Usage } from '../daemon/protocol.ts'
import { diff } from './dsh.ts'

export const modes: Record<string, string> = {
  ask: 'default', edits: 'acceptEdits', auto: 'auto', full: 'bypassPermissions', plan: 'plan',
}
export const defaultDisallowedTools = ['Agent', 'Workflow', 'SendMessage', 'ListAgents']
export interface ClaudeConfiguration {
  executable?: string
  extraArgs?: string[]
  disallowedTools?: string[]
  historyTurns?: number
}

/** Transitional daemon configuration until the shared config-file phase. */
export function configuration(host?: SessionHost): ClaudeConfiguration {
  const config = JSON.parse(process.env.EMX_CLAUDE_CONFIG ?? '{}')
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('EMX_CLAUDE_CONFIG must be a JSON object')
  if (config.executable !== undefined && typeof config.executable !== 'string') throw new Error('Expected string: executable')
  for (const key of ['extraArgs', 'disallowedTools']) {
    if (config[key] !== undefined && (!Array.isArray(config[key]) || !config[key].every((s: unknown) => typeof s === 'string'))) {
      throw new Error(`Expected string[]: ${key}`)
    }
  }
  if (config.historyTurns !== undefined && (!Number.isSafeInteger(config.historyTurns) || config.historyTurns < 1)) {
    throw new Error('Expected an integer >= 1: historyTurns')
  }
  return { ...host?.agentConfig?.(), ...config }
}

const counters = ['input', 'cacheRead', 'cacheWrite', 'output'] as const
const sum = (usage: Usage): number => counters.reduce((n, key) => n + usage[key], 0)
const empty = (): Usage => ({ input: 0, cacheRead: 0, cacheWrite: 0, output: 0 })
const subtract = (a: Usage, b = empty()): Usage => Object.fromEntries(counters.map((k) => [k, a[k] - b[k]])) as unknown as Usage

/** Match agent-usage-totals, including ambiguous restored totals on first report. */
export class ClaudeTotals {
  base: Record<string, Usage> | undefined
  known = false
  newProcess(): void { this.known = false }
  forget(): void { this.base = undefined; this.known = false }
  deltas(totals: Record<string, Usage>, turn: Usage): Record<string, Usage> | undefined {
    const delta = Object.fromEntries(Object.entries(totals).map(([m, u]) => [m, subtract(u, this.base?.[m])]))
    const valid = this.known || this.base && Object.values(delta).every((u) => counters.every((k) => u[k] >= 0))
      && Object.values(delta).reduce((n, u) => n + sum(u), 0) >= sum(turn)
    this.base = totals
    this.known = true
    if (valid) return Object.fromEntries(Object.entries(delta).filter(([, u]) => counters.some((k) => u[k] > 0)))
    if (Object.values(totals).reduce((n, u) => n + sum(u), 0) === sum(turn)) return totals
    return undefined
  }
}

export function toolView(root: string, name: string, input: any = {}): ToolView {
  const path = typeof input.file_path === 'string' && isAbsolute(input.file_path)
    ? relative(root, input.file_path) : input.file_path
  const view: ToolView = { name, kind: 'other', title: name }
  switch (name) {
    case 'Bash': return { ...view, kind: 'command', title: (input.command ?? '').split('\n')[0], command: input.command }
    case 'Read': return { ...view, kind: 'read', title: path ?? '', path }
    case 'Write': case 'Edit': case 'MultiEdit': return { ...view, kind: 'edit', title: path ?? '', path,
      diff: name === 'MultiEdit' ? (input.edits ?? []).map((e: any) => diff(path ?? '', e.old_string, e.new_string)).join('\n')
        : diff(path ?? '', name === 'Write' ? undefined : input.old_string, name === 'Write' ? input.content : input.new_string) }
    case 'Grep': case 'Glob': return { ...view, kind: 'search', title: `${name} ${input.pattern ?? ''}` }
    case 'WebFetch': case 'WebSearch': return { ...view, kind: 'web', title: input.url ?? input.query ?? '' }
    case 'Task': case 'Agent': return { ...view, kind: 'task', title: input.description ?? name }
    case 'AskUserQuestion': return { ...view, kind: 'question', title: input.title ?? input.questions?.[0]?.question ?? '' }
    case 'TodoWrite': return { ...view, kind: 'plan', title: '', items: (input.todos ?? []).map((todo: any) => ({
      text: todo.content, status: todo.status === 'completed' ? 'done' : todo.status === 'in_progress' ? 'active' : 'pending' })) }
    default: return name.startsWith('mcp__') ? { ...view, kind: 'mcp', title: name.split('__').slice(1).join(' · ') } : view
  }
}

export function resultText(content: any): string {
  return typeof content === 'string' ? content : (content ?? []).map((p: any) => p.text ?? '').join('\n')
}

export function encodePath(root: string): string {
  return (root.replace(/\/$/, '') || '/').replace(/[^\p{L}\p{N}]/gu, '-')
}

/** Read only complete JSONL records, keeping byte offsets even for UTF-8 text. */
export async function* entries(file: string, start = 0, end = Infinity): AsyncGenerator<{ entry: any, start: number, end: number }> {
  let pending = Buffer.alloc(0)
  let offset = start
  if (end <= start) return
  const stream = createReadStream(file, { start, ...(Number.isFinite(end) ? { end: end - 1 } : {}) })
  try {
    for await (const chunk of stream) {
      pending = Buffer.concat([pending, chunk])
      let index: number
      while ((index = pending.indexOf(10)) >= 0) {
        const line = pending.subarray(0, index)
        const beg = offset
        offset += index + 1
        pending = pending.subarray(index + 1)
        let entry: any
        try { entry = JSON.parse(line.toString('utf8')) } catch { continue }
        if (entry && typeof entry === 'object') yield { entry, start: beg, end: offset }
      }
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  } finally { stream.destroy() }
}

function prompt(entry: any): { text: string, imageCount: number } | undefined {
  if (entry.type !== 'user' || entry.isMeta || entry.isSidechain) return
  const content = entry.message?.content
  const images = Array.isArray(content) ? content.filter((p: any) => p.type === 'image').length : 0
  const text = typeof content === 'string' ? content : Array.isArray(content) && content.length
    && content.every((p: any) => ['text', 'image'].includes(p.type))
    ? content.filter((p: any) => p.type === 'text').map((p: any) => p.text ?? '').join('\n') : undefined
  if (typeof text === 'string' && !text.trimStart().startsWith('<')) return { text, imageCount: images }
}

/** Two streaming passes, retaining at most TURNS offsets and display blocks. */
export async function historyPage(file: string, root: string, turns: number, stop = Infinity): Promise<{ start: number, end: number, blocks: Block[] }> {
  if (!Number.isSafeInteger(turns) || turns < 1) throw new Error('History turns must be an integer >= 1')
  const starts: number[] = []
  let end = 0
  let prompts = 0
  for await (const record of entries(file, 0, stop)) {
    end = record.end
    if (prompt(record.entry)) { prompts++; starts.push(record.start); if (starts.length > turns) starts.shift() }
  }
  const start = prompts > turns ? starts[0] : 0
  const blocks: Block[] = []
  for await (const { entry } of entries(file, start, end)) renderEntry(root, entry, blocks)
  return { start, end, blocks }
}

function renderEntry(root: string, entry: any, blocks: Block[]): void {
  if (entry.isSidechain) return
  const content = entry.message?.content
  const user = prompt(entry)
  if (user) blocks.push({ id: entry.uuid, type: 'user', ...user })
  else if (entry.type === 'attachment' && entry.attachment?.type === 'queued_command'
    && typeof entry.attachment.prompt === 'string' && !entry.attachment.prompt.trimStart().startsWith('<')) {
    blocks.push({ id: entry.uuid, type: 'user', text: entry.attachment.prompt })
  } else if (Array.isArray(content)) content.forEach((part: any, index: number) => {
    if (entry.type === 'assistant' && part.type === 'text') blocks.push({ id: `${entry.uuid}-${index}`, type: 'text', kind: 'assistant', text: part.text ?? '', done: true })
    if (entry.type === 'assistant' && part.type === 'tool_use') blocks.push({ id: part.id, type: 'tool', view: toolView(root, part.name, part.input), status: 'done' })
    if (entry.type === 'user' && part.type === 'tool_result') {
      const block = blocks.find((b) => b.id === part.tool_use_id)
      if (block?.type === 'tool') { block.status = part.is_error ? 'error' : 'done'; block.output = resultText(part.content) }
    }
  })
}

/** Find value boundaries in already validated JSON without normalizing its text. */
function jsonValueEnd(json: string, start: number): number {
  let depth = 0
  let quoted = false
  for (let i = start; i < json.length; i++) {
    const char = json[i]
    if (quoted) {
      if (char === '\\') i++
      else if (char === '"') { quoted = false; if (!depth) return i + 1 }
    } else if (char === '"') quoted = true
    else if (char === '{' || char === '[') depth++
    else if (char === '}' || char === ']') {
      if (!depth) return i
      if (!--depth) return i + 1
    } else if (!depth && /[\s,]/.test(char)) return i
  }
  return json.length
}

function jsonObjectSpans(json: string): Map<string, { start: number, end: number }> {
  const spans = new Map<string, { start: number, end: number }>()
  const skip = (start: number): number => {
    while (/\s/.test(json[start] ?? '') && start < json.length) start++
    return start
  }
  let i = skip(0)
  if (json[i] !== '{') return spans
  i = skip(i + 1)
  while (i < json.length && json[i] !== '}') {
    const keyEnd = jsonValueEnd(json, i)
    const key: string = JSON.parse(json.slice(i, keyEnd))
    const start = skip(skip(keyEnd) + 1) // Skip the colon and surrounding space.
    const end = jsonValueEnd(json, start)
    spans.set(key, { start, end }) // Last duplicate wins, matching JSON.parse.
    i = skip(end)
    if (json[i] !== ',') break
    i = skip(i + 1)
  }
  return spans
}

export function rawJsonField(json: string, key: string): string | undefined {
  const span = jsonObjectSpans(json).get(key)
  return span && json.slice(span.start, span.end)
}

function withJsonField(json: string, key: string, value: unknown): string {
  const spans = jsonObjectSpans(json)
  const span = spans.get(key)
  const encoded = JSON.stringify(value)
  if (span) return json.slice(0, span.start) + encoded + json.slice(span.end)
  const end = json.lastIndexOf('}')
  return json.slice(0, end) + (spans.size ? ',' : '') + JSON.stringify(key) + ':' + encoded + json.slice(end)
}

export class ClaudeBackend implements Backend {
  readonly host: SessionHost
  #process: ChildProcessWithoutNullStreams | undefined
  #lifecycle: Promise<void> | undefined
  #resume: string | undefined
  #running = false
  #restart = false
  #external = false
  #readOnly: string[] = []
  #confirmed: Settings = {}
  #configuration: Promise<void> = Promise.resolve()
  #sending: Promise<void> = Promise.resolve()
  #pending = new Map<string, { resolve: (value: any) => void, reject: (error: Error) => void, timer: NodeJS.Timeout }>()
  #totals = new ClaudeTotals()
  #messageId = ''
  #watch: FSWatcher | undefined
  #timer: NodeJS.Timeout | undefined
  #offset = 0
  #source: string | undefined
  #syncing: Promise<void> = Promise.resolve()
  #stopped = false
  #generation = 0
  #declined = new Set<string>()
  #rateLimits: Extract<SessionEvent, { type: 'quota/rate-limits' }>['rateLimits'] | undefined

  constructor(host: SessionHost) {
    this.host = host
    if (typeof host.info.sessionId === 'string') this.#resume = host.info.sessionId
  }

  #notice(kind: string, args?: Record<string, string | number | boolean>, level?: 'error' | 'warning'): void {
    this.host.addBlock({ id: this.host.newId('notice'), type: 'notice', notice: { kind, args, level } })
  }
  #write(message: unknown): void { this.#process?.stdin.write(JSON.stringify(message) + '\n') }
  #control(request: object): Promise<any> {
    if (!this.alive()) return Promise.reject(new Error('Claude is not running'))
    const id = this.host.newId('control')
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error('Claude control request timed out')) }, 120000)
      this.#pending.set(id, { resolve, reject, timer })
      this.#write({ type: 'control_request', request_id: id, request })
    })
  }
  #file(): string | undefined {
    return this.#resume ? join(process.env.EMX_CLAUDE_PROJECTS_DIR ?? join(homedir(), '.claude/projects'), encodePath(this.host.root), `${this.#resume}.jsonl`) : undefined
  }

  start(resume?: string): Promise<void> {
    if (this.#lifecycle) return this.#lifecycle
    if (this.alive()) return Promise.resolve()
    return this.#transition(() => this.#start(resume))
  }

  #transition(action: () => Promise<void>): Promise<void> {
    const task = action().finally(() => {
      if (this.#lifecycle === task) this.#lifecycle = undefined
    })
    this.#lifecycle = task
    return task
  }

  async #start(resume?: string): Promise<void> {
    if (!isAbsolute(this.host.root) || /^\/[^/]+:/.test(this.host.root)) throw new Error('Claude daemon sessions require a local absolute root; remote projects are not supported')
    if (resume && !/^[\w-]+$/.test(resume)) throw new Error('Invalid Claude resume id')
    this.#stopped = false
    this.#resume = resume
    this.#totals.newProcess()
    const desired = { ...this.host.settings }
    const skills = sessionSkills(this.host)
    const config = configuration(this.host)
    const disallowed = config.disallowedTools ?? defaultDisallowedTools
    const args = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
      '--permission-prompt-tool', 'stdio', '--mcp-config', JSON.stringify({ mcpServers: { emacs: { command: process.execPath,
        args: [join(checkoutRoot, 'bin/emx'), 'mcp'], env: { EMX_DAEMON_SOCKET: this.host.daemonSocket, EMX_SESSION: this.host.id } } } }),
      '--allow-dangerously-skip-permissions', '--permission-mode', modes[desired.mode ?? 'ask'] ?? modes.ask]
    if (disallowed.length) args.push('--disallowedTools', disallowed.join(','))
    if (this.host.info.parent) args.push('--no-session-persistence')
    if (desired.model && desired.model !== 'default') args.push('--model', desired.model)
    if (desired.effort) args.push('--effort', desired.effort)
    const fork = this.host.info.forkFrom as string | undefined
    if (fork) args.push('--resume', fork, '--fork-session')
    else if (resume) args.push('--resume', resume)
    if (skills?.skillsDir) args.push('--add-dir', skills.skillsDir)
    if (skills?.supersededSkills?.length) args.push('--settings', JSON.stringify({ skillOverrides: Object.fromEntries(skills.supersededSkills.map((s) => [s, 'off'])) }))
    args.push(...config.extraArgs ?? [])
    const readOnly = this.host.editorTools().readOnly
    if (readOnly.length) args.push('--allowedTools', readOnly.map((name) => `mcp__emacs__${name}`).join(','))
    const env = await this.host.environment?.()
    if (this.#stopped) return
    const child = spawn(process.env.EMX_CLAUDE_EXECUTABLE ?? config.executable ?? 'claude', args, { cwd: this.host.root, env, stdio: 'pipe' })
    this.#process = child
    this.#readOnly = [...readOnly]
    child.stdin.on('error', () => {})
    child.stderr.resume()
    createInterface({ input: child.stdout }).on('line', (line) => {
      if (this.#process !== child) return
      try { this.#receive(JSON.parse(line), line) } catch (error) { this.#notice('backend-error', { message: String(error) }, 'error') }
    })
    const ended = (error?: Error): void => {
      if (this.#process !== child) return
      this.#process = undefined
      this.#running = false
      for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error ?? new Error('Claude exited')) }
      this.#pending.clear()
      this.host.emit({ type: 'usage/end' })
      this.#notice('backend-error', { message: error?.message ?? `Claude exited (${child.exitCode ?? child.signalCode})` }, 'error')
      this.host.setStatus('exited')
    }
    child.once('error', ended)
    child.once('close', () => ended())
    const init = await this.#control({ subtype: 'initialize' })
    this.#confirmed = { model: null, effort: null, mode: null, ...desired }
    this.host.emit({ type: 'capabilities', capabilities: {
      models: (init.models ?? []).map((m: any) => ({ id: m.value, name: m.displayName, description: m.description, efforts: m.supportedEffortLevels })),
      modes: Object.keys(modes), commands: (init.commands ?? []).map((c: any) => ({ name: c.name, description: c.description, hint: c.argumentHint })),
    } })
    if (!this.host.blocks.length && resume) {
      const page = await historyPage(this.#file()!, this.host.root, config.historyTurns ?? 20)
      for (const block of page.blocks) this.host.addBlock(block)
      this.host.setInfo({ claudeHistoryStart: page.start })
      this.#offset = page.end
      if (page.blocks.length) this.#notice('history-end')
    } else if (this.#file() && !this.#watch) {
      this.#offset = Number(this.host.info.claudeSyncOffset ?? await stat(this.#file()!).then((s) => s.size, () => 0))
    }
    this.host.setInfo({ claudeSyncOffset: this.#offset })
    await this.#watchFile()
    await this.#syncSoon()
    if (!this.#running) this.host.setStatus('idle')
  }

  hasEarlier(): boolean { return Number(this.host.info.claudeHistoryStart ?? 0) > 0 }
  async loadEarlier(turns: number): Promise<Block[]> {
    if (!this.hasEarlier() || !this.#file() || turns <= 0) return []
    const page = await historyPage(this.#file()!, this.host.root, turns, Number(this.host.info.claudeHistoryStart))
    this.host.setInfo({ claudeHistoryStart: page.start })
    return page.blocks
  }

  async #watchFile(): Promise<void> {
    if (this.#watch || this.#stopped || !this.#file() || this.host.info.parent) return
    const file = this.#file()!
    // Watch the directory as well: the transcript appears during the first turn.
    try {
      this.#watch = watch(dirname(file), (_, name) => {
        if (name && name.toString() !== `${this.#resume}.jsonl`) return
        if (!this.#timer) this.#timer = setTimeout(() => {
          this.#timer = undefined
          void this.#syncSoon().catch((error) => this.#notice('backend-error', { message: String(error) }, 'error'))
        }, 500)
      })
      this.#watch.on('error', () => { this.#watch?.close(); this.#watch = undefined })
    } catch { /* A new project's directory can appear during its first turn. */ }
  }

  #syncSoon(): Promise<void> {
    const task = this.#syncing.then(() => this.#sync())
    this.#syncing = task.catch(() => {})
    return task
  }

  async #sync(): Promise<void> {
    const file = this.#file()
    if (!file || this.#stopped) return
    const size = await stat(file).then((s) => s.size, () => 0)
    if (size < this.#offset) this.#offset = size
    for await (const record of entries(file, this.#offset, size)) {
      this.#offset = record.end
      const entry = record.entry
      if (!entry.entrypoint || entry.entrypoint === 'sdk-cli' || entry.isSidechain) continue
      if (!['user', 'assistant', 'attachment'].includes(entry.type)) continue
      if (entry.entrypoint !== this.#source) {
        this.#source = entry.entrypoint
        this.#notice('claude-external-source', { source: entry.entrypoint })
      }
      const blocks: Block[] = []
      renderEntry(this.host.root, entry, blocks)
      if (entry.type === 'user' && Array.isArray(entry.message?.content)) for (const p of entry.message.content) {
        if (p.type === 'tool_result' && this.host.blocks.some((b) => b.id === p.tool_use_id)) {
          this.host.update(p.tool_use_id, { status: p.is_error ? 'error' : 'done', output: resultText(p.content) })
        }
      }
      for (const block of blocks) this.host.addBlock(block)
      if (['user', 'assistant'].includes(entry.type)) this.#external = true
    }
    this.host.setInfo({ claudeSyncOffset: this.#offset })
  }

  configure(settings: Settings): Promise<void> {
    const desired = { ...settings }
    const task = this.#configuration.then(() => this.#configure(desired))
    this.#configuration = task.catch(() => {})
    return task
  }
  async #configure(settings: Settings): Promise<void> {
    const previous = { ...this.#confirmed }
    try {
      if ((settings.model ?? null) !== (previous.model ?? null)) {
        await this.#control({ subtype: 'set_model', model: settings.model ?? null })
        this.#confirmed.model = settings.model ?? null
        this.host.setInfo({ model: this.#confirmed.model })
      }
      if ((settings.mode ?? null) !== (previous.mode ?? null)) {
        await this.#control({ subtype: 'set_permission_mode', mode: modes[settings.mode ?? 'ask'] ?? modes.ask })
        this.#confirmed.mode = settings.mode ?? null
      }
      if ((settings.effort ?? null) !== (previous.effort ?? null)) {
        if (this.host.info.parent) {
          this.#confirmed.effort = previous.effort
          this.host.emit({ type: 'settings', settings: { effort: previous.effort ?? null } })
          this.#notice('claude-child-effort', undefined, 'error')
        } else if (this.#running) {
          this.#confirmed.effort = settings.effort ?? null
          this.#restart = true
          this.#notice('effort-after-turn')
        } else await this.#restartProcess()
      }
    } catch (error) {
      this.host.emit({ type: 'settings', settings: { ...this.#confirmed } })
      this.#notice('backend-error', { message: String(error) }, 'error')
      throw error
    }
  }
  #restartProcess(): Promise<void> {
    if (this.#lifecycle) return this.#lifecycle
    return this.#transition(async () => {
      const generation = this.#generation
      await this.#kill()
      if (generation !== this.#generation) return
      await this.#start(this.#resume)
      this.#restart = false
    })
  }
  async #content(text: string, images?: string[]): Promise<any> {
    if (!images?.length) return text
    const content: any[] = await Promise.all(images.map(async (file) => ({ type: 'image', source: {
      type: 'base64', media_type: /\.jpe?g$/i.test(file) ? 'image/jpeg' : /\.webp$/i.test(file) ? 'image/webp' : /\.gif$/i.test(file) ? 'image/gif' : 'image/png',
      data: (await readFile(file)).toString('base64'),
    } })))
    if (text) content.push({ type: 'text', text })
    return content
  }
  send(text: string, images?: string[], block?: string): Promise<void> {
    // Reserve the turn before asynchronous file I/O. Configure and steer can
    // arrive as soon as session/send returns, while preparation is still busy.
    this.#running = true
    this.host.setStatus('running')
    const task = this.#send(text, images, block).catch((error) => {
      this.#running = false
      throw error
    })
    this.#sending = task
    return task
  }

  async #send(text: string, images?: string[], block?: string): Promise<void> {
    await this.#configuration
    await this.#lifecycle
    await this.#syncSoon()
    const content = await this.#content(text, images)
    if (this.#external) {
      if (this.host.info.parent) throw new Error('Cannot resume a non-persistent Claude child')
      this.#external = false
      this.#totals.forget()
      this.#notice('restart-for-external')
      await this.#restartProcess()
    }
    while (!this.host.info.parent
      && JSON.stringify(this.#readOnly) !== JSON.stringify(this.host.editorTools().readOnly)) {
      await this.#restartProcess()
    }
    this.#source = undefined
    this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images })
    if (!this.alive()) throw new Error('Claude exited while preparing the message')
    this.#write({ type: 'user', message: { role: 'user', content } })
  }
  steer(text: string, images?: string[], block?: string): boolean {
    if (!this.#running || !this.alive()) return false
    void this.#sending.then(() => this.#content(text, images)).then((content) => {
      this.host.addBlock({ id: block ?? this.host.newId('user'), type: 'user', text, images })
      this.#write({ type: 'user', message: { role: 'user', content } })
    }).catch((error) => this.#notice('backend-error', { message: String(error) }, 'error'))
    return true
  }
  interrupt(): void {
    // Preserve input ordering when cancellation arrives during history/image I/O.
    if (this.alive()) void this.#sending.then(() => this.#control({ subtype: 'interrupt' })).catch(() => {})
  }

  #text(id: string, kind: 'assistant' | 'thinking', text: string): void {
    if (!text) return
    if (!this.host.blocks.some((b) => b.id === id)) this.host.addBlock({ id, type: 'text', kind, text: '', done: false })
    this.host.append(id, text)
  }
  #usage(usage: any): void {
    if (!usage) return
    const tokens = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.output_tokens ?? 0)
    if (tokens > 0) this.host.setInfo({ tokens })
  }
  #receive(message: any, line: string): void {
    if (message.parent_tool_use_id) return
    switch (message.type) {
      case 'control_response': {
        const response = message.response
        const pending = this.#pending.get(response.request_id)
        if (!pending) return
        this.#pending.delete(response.request_id); clearTimeout(pending.timer)
        if (response.subtype === 'error') pending.reject(new Error(response.error))
        else pending.resolve(response.response)
        break
      }
      case 'control_request': void this.#ask(message.request_id, message.request, line).catch((error) => this.#notice('backend-error', { message: String(error) }, 'error')); break
      case 'system':
        if (message.subtype === 'init') {
          this.#resume = message.session_id
          this.host.setInfo({ sessionId: this.#resume, model: message.model })
          void this.#watchFile()
        }
        break
      case 'stream_event': {
        const event = message.event
        const id = `${this.#messageId}-${event.index}`
        switch (event.type) {
          case 'message_start': this.#messageId = event.message.id; this.#usage(event.message.usage); break
          case 'message_delta': this.#usage(event.usage); break
          case 'content_block_start': {
            const part = event.content_block
            if (part.type === 'tool_use') this.host.addBlock({ id: part.id, type: 'tool', view: { name: part.name, kind: 'other', title: part.name }, status: 'running' })
            break
          }
          case 'content_block_delta':
            if (event.delta.type === 'text_delta') this.#text(id, 'assistant', event.delta.text)
            if (event.delta.type === 'thinking_delta') this.#text(id + '-thinking', 'thinking', event.delta.thinking)
            break
          case 'content_block_stop':
            for (const key of [id, id + '-thinking']) if (this.host.blocks.some((b) => b.id === key)) this.host.update(key, { done: true })
            break
        }
        break
      }
      case 'assistant':
        for (const part of message.message?.content ?? []) if (part.type === 'tool_use') {
          const view = toolView(this.host.root, part.name, part.input)
          if (this.host.blocks.some((b) => b.id === part.id)) this.host.update(part.id, { view })
          else this.host.addBlock({ id: part.id, type: 'tool', view, status: 'running' })
        }
        break
      case 'user':
        if (Array.isArray(message.message?.content)) for (const part of message.message.content) {
          if (part.type === 'tool_result' && this.host.blocks.some((b) => b.id === part.tool_use_id)) this.host.update(part.tool_use_id,
            { status: this.#declined.has(part.tool_use_id) ? 'declined' : part.is_error ? 'error' : 'done', output: resultText(part.content) })
        }
        break
      case 'rate_limit_event': {
        const windows = message.rate_limit_info?.unifiedWindows
        if (windows) {
          this.#rateLimits = { windows: Object.entries(windows).map(([id, w]: [string, any]) => ({
            id, minutes: id.startsWith('five_hour') ? 300 : 10080, used: w.utilization, resets: w.resetsAt ?? null,
          })) }
          this.reattached()
        }
        break
      }
      case 'result':
        if (!this.#running) break
        this.#modelUsage(message)
        this.host.emit({ type: 'usage/end' })
        if (message.is_error) this.#notice('backend-error', { message: message.result ?? message.subtype }, 'error')
        this.#running = false
        void this.#watchFile()
        // Keep the session non-idle until the deferred restart has completed.
        if (this.#restart) void this.#restartProcess().catch((error) => {
          this.#notice('backend-error', { message: String(error) }, 'error'); this.host.setStatus('exited')
        })
        else this.host.setStatus('idle')
        break
    }
  }
  #modelUsage(result: any): void {
    const u = result.usage ?? {}
    const turn: Usage = { input: u.input_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0,
      cacheWrite: u.cache_creation_input_tokens ?? 0, output: u.output_tokens ?? 0 }
    const totals = Object.fromEntries(Object.entries(result.modelUsage ?? {}).map(([m, u]: [string, any]) => [m, {
      input: u.inputTokens ?? 0, cacheRead: u.cacheReadInputTokens ?? 0, cacheWrite: u.cacheCreationInputTokens ?? 0, output: u.outputTokens ?? 0,
    }]))
    const deltas = this.#totals.deltas(totals, turn)
    for (const [model, usage] of Object.entries(deltas ?? { [String(this.host.info.model ?? Object.keys(totals)[0] ?? 'claude')]: turn })) {
      this.host.emit({ type: 'usage/call', model, usage })
    }
  }
  async #ask(id: string, request: any, line: string): Promise<void> {
    const child = this.#process
    const rawRequest = rawJsonField(line, 'request') ?? '{}'
    let rawInput = rawJsonField(rawRequest, 'input')
    const rawPermissions = rawJsonField(rawRequest, 'permission_suggestions')
    if (request.subtype !== 'can_use_tool') {
      this.#write({ type: 'control_response', response: { subtype: 'error', request_id: id, error: 'Unsupported Claude control request' } }); return
    }
    let response: any
    if (request.tool_name === 'AskUserQuestion') {
      const questions = request.input.questions ?? []
      const answer = await this.host.ask({ type: 'question', tool: request.tool_use_id, questions: questions.map((q: any) => ({
        question: q.question, header: q.header, detail: q.description, options: q.options, multi: q.multiSelect, other: true,
        ...(q.kind === 'number' ? { range: [q.min, q.max, q.unit] } : {}),
      })) })
      if (!answer.answers) response = { behavior: 'deny', message: 'The user declined to answer these questions.' }
      else {
        const answers: Record<string, unknown> = {}
        questions.forEach((q: any, index: number) => {
          const a = answer.answers?.[index]
          if (!a) return
          const values = [...a.selected, ...(a.custom ? [a.custom] : [])]
          if (values.length) answers[q.question] = q.multiSelect ? values : values[0]
        })
        response = { behavior: 'allow', updatedInput: { ...request.input, answers } }
        if (rawInput) rawInput = withJsonField(rawInput, 'answers', answers)
      }
    } else {
      const answer = await this.host.ask({ type: 'approval', tool: request.tool_use_id,
        view: toolView(this.host.root, request.tool_name, request.input), description: request.description,
        choices: request.permission_suggestions?.length ? ['allow', 'always', 'deny'] : ['allow', 'deny'] })
      response = answer.choice === 'allow' || answer.choice === 'always'
        ? { behavior: 'allow', updatedInput: request.input,
          ...(answer.choice === 'always' ? { updatedPermissions: request.permission_suggestions } : {}) }
        : { behavior: 'deny', message: 'The user declined this operation.' }
    }
    if (response.behavior === 'deny') this.#declined.add(request.tool_use_id)
    if (this.#process === child) {
      // The CLI compares these arguments with its original JSON, so splice only
      // captured values; the parsed input above is for display and new answers.
      const fields = Object.entries(response).filter(([, value]) => value !== undefined).map(([key, value]) => {
        const raw = key === 'updatedInput' ? rawInput : key === 'updatedPermissions' ? rawPermissions : undefined
        return JSON.stringify(key) + ':' + (raw ?? JSON.stringify(value))
      }).join(',')
      this.#process?.stdin.write('{"type":"control_response","response":{"subtype":"success","request_id":'
        + JSON.stringify(id) + ',"response":{' + fields + '}}}\n')
    }
  }

  reattached(): void {
    if (this.#rateLimits) this.host.emit({ type: 'quota/rate-limits', rateLimits: this.#rateLimits })
  }

  async #kill(): Promise<void> {
    const child = this.#process
    if (!child) return
    this.#process = undefined
    for (const p of this.#pending.values()) { clearTimeout(p.timer); p.reject(new Error('Claude stopped')) }
    this.#pending.clear()
    const closed = once(child, 'close').catch(() => {})
    child.kill('SIGTERM')
    const timer = setTimeout(() => child.kill('SIGKILL'), 1000)
    await closed; clearTimeout(timer)
  }
  async stop(): Promise<void> {
    this.#generation++
    this.#stopped = true
    this.#watch?.close(); this.#watch = undefined
    if (this.#timer) clearTimeout(this.#timer)
    this.#timer = undefined
    await this.#syncing
    await this.#kill()
    await this.#lifecycle?.catch(() => {})
    this.#running = false
  }
  // A lifecycle transition owns the next process even while the old one exits.
  alive(): boolean { return !!this.#lifecycle || !!this.#process && this.#process.exitCode === null && !this.#process.killed }
  resumeId(): string | undefined { return this.#resume }
}
