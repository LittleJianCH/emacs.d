import { sessionSkills } from '../backends/backend.ts'
// collab.ts --- daemon-owned tools, children, mailbox and task context.
import { spawn } from 'node:child_process'
import { accessSync, constants, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { delimiter, isAbsolute, join } from 'node:path'
import { tmpdir } from 'node:os'
import type { Config, Profile } from '../config.ts'
import type { Block, EditorTools, SessionEvent, Settings } from './protocol.ts'
import type { Session } from './session.ts'

export const toolNames = ['sessions', 'session_read', 'session_ask', 'session_start', 'session_stop']
export const forkAgents = ['claude', 'codex', 'dsh', 'pi']
const costRanks: Record<string, number> = { minimal: 0, low: 1, medium: 2, high: 3, premium: 4, unknown: 5 }
const modes = ['plan', 'ask', 'edits', 'auto', 'full']
const icons: Record<string, string> = { command: '$', edit: '✎', read: '≡', search: '⌕', web: '◎', mcp: '⚙', task: '◆', plan: '☰', question: '?', other: '•' }
export const format = (text: string, ...args: unknown[]): string => {
  let i = 0
  return text.replace(/%[sd]/g, () => String(args[i++]))
}
export function executable(command: string, env: NodeJS.ProcessEnv = process.env): boolean {
  for (const path of isAbsolute(command) ? [command] : (env.PATH ?? '').split(delimiter).map((p) => join(p, command))) {
    try { accessSync(path, constants.X_OK); return true } catch { /* Try next. */ }
  }
  return false
}
export function agentExecutable(c: Config, agent: string, env: NodeJS.ProcessEnv = process.env): string {
  return env[`EMX_${agent.toUpperCase()}_EXECUTABLE`] ?? c.agents[agent]?.executable ?? agent
}
function availableAgent(c: Config, agent: string, enabled: string[] | undefined, env: NodeJS.ProcessEnv): boolean {
  return !!c.agents[agent] && (!enabled || enabled.includes(agent)) && executable(agentExecutable(c, agent, env), env)
}
/** Single seam for future quota-based profile costs. */
export function profileCost(name: string, profile: Profile): string {
  return profile.cost ?? 'unknown'
}
export function profiles(c: Config, enabled?: string[], env: NodeJS.ProcessEnv = process.env): [string, Profile][] {
  const rank = ([name, p]: [string, Profile]) => costRanks[profileCost(name, p)] ?? costRanks.unknown
  return Object.entries(c.profiles).filter(([, p]) => availableAgent(c, p.agent, enabled, env))
    .sort((a, b) => rank(a) - rank(b))
}
function profileLines(c: Config, available: [string, Profile][]): string {
  return available.map(([name, p]) => `- ${name}: ${c.agents[p.agent].title}${p.model ? ' ' + p.model : ''}, ${profileCost(name, p)} cost.  ${p.description ?? ''}`).join('\n')
}
export function startSummary(c: Config, enabled?: string[], env: NodeJS.ProcessEnv = process.env): string {
  const groups = new Map<string, string[]>()
  for (const [name, p] of profiles(c, enabled, env)) {
    const cost = profileCost(name, p)
    if (!groups.has(cost)) groups.set(cost, [])
    groups.get(cost)!.push(name)
  }
  return groups.size ? format(c.collab.prompts.startSummary,
    [...groups].map(([cost, names]) => `${names.join(', ')} (${cost})`).join('; ')) : ''
}
export function definitions(c: Config, enabled?: string[], env: NodeJS.ProcessEnv = process.env): EditorTools['tools'] {
  const titles = forkAgents.filter((a) => availableAgent(c, a, enabled, env)).map((a) => c.agents[a].title)
  const joined = titles.length < 2 ? titles.join('') : titles.slice(0, -1).join(', ') + ' and ' + titles.at(-1)
  return c.collab.tools.map((tool) => {
    if (tool.name !== 'session_start') return { ...tool }
    // {forkAgents} occupies a whole line; omit it when no available backend can fork.
    const description = tool.description.replace(/^\{forkAgents\}(?:\n|$)/m,
      titles.length ? format(c.collab.prompts.forkAgents, joined) + '\n' : '')
    return { ...tool, description: description + '\n\n'
      + (c.collab.startGuidance ? c.collab.startGuidance + '\n\n' : '') + c.collab.prompts.profileHeader
      + profileLines(c, profiles(c, enabled, env)) }
  })
}
export function cleanHandle(value: string): string | undefined {
  const last = value.trim().toLowerCase().split('\n').at(-1) ?? ''
  const result = last.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 20).replace(/-+$/, '')
  return /^[a-z]/.test(result) ? result : undefined
}
export function turns(s: Session): Block[][] {
  const result: Block[][] = []
  for (const b of s.blocks) {
    if (b.type === 'user') result.push([b])
    else result.at(-1)?.push(b)
  }
  return result
}
function clip(text: string, limit: number, tail = false): string {
  text = text.trim()
  const extra = [...text].length - limit
  if (extra <= 0) return text
  const chars = [...text]
  return tail ? `… (${extra} characters before)\n${chars.slice(extra).join('')}` : `${chars.slice(0, limit).join('')}\n… (${extra} more characters)`
}
function toolLine(b: Extract<Block, {type: 'tool'}>): string {
  const state = b.status === 'running' ? ' (running)' : b.status === 'error' ? ' (failed)' : b.status === 'declined' ? ' (declined)' : ''
  const diff = b.view.diff?.split('\n')
  const stat = diff ? ` +${diff.filter((l) => l.startsWith('+') && !l.startsWith('+++')).length} -${diff.filter((l) => l.startsWith('-') && !l.startsWith('---')).length}` : ''
  return `- ${icons[b.view.kind] ?? '•'} ${b.view.title}${state}${stat}`
}
export function formatTurn(n: number, turn: Block[], tools: string, running: boolean, limit: number): string {
  const user = turn[0] as Extract<Block, {type: 'user'}>
  const parts = [`## Turn ${n}${running ? ' (in progress)' : ''}\n${user.origin ? 'Message from ' + user.origin : 'User'}:\n${clip(user.text, limit)}`]
  let pending: string[] = []
  const flush = () => { if (pending.length) { parts.push('Tools:\n' + pending.join('\n')); pending = [] } }
  for (const b of turn.slice(1)) {
    if (b.type === 'text' && b.kind !== 'thinking') { flush(); parts.push('Assistant:\n' + clip(b.text, limit)) }
    if (b.type === 'tool' && tools === 'summary') pending.push(toolLine(b))
    if (b.type === 'tool' && tools === 'full') {
      flush(); const body = b.view.diff ?? b.output
      parts.push('Tool' + toolLine(b).slice(1) + (body?.trim() ? '\n' + clip(body, limit, true) : ''))
    }
    if (b.type === 'notice') { flush(); parts.push('Note: ' + (b.notice.args?.message ?? b.notice.kind)) }
  }
  flush()
  return parts.join('\n\n')
}
export interface RemoteRoute { daemon: string, session: string }
interface Pending { target: string, asker: string, block: string, handle?: string, route?: RemoteRoute }
interface Outgoing { id: string, route: RemoteRoute, mail: Mail }
interface Mail { handle: string, text: string }
export interface CollabHost {
  sessions: Map<string, Session>
  config(): Config
  hub?(caller: { id: string, root: string }, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>
  environment?(root: string): NodeJS.ProcessEnv
  varDir: string
  create(agent: string, root: string, settings: Settings, info: Record<string, unknown>): Session
  close(session: Session): Promise<void>
  view(session: Session): Promise<void>
  visible(session: Session): Promise<boolean>
  changed(): void
}
export class Collaboration {
  readonly host: CollabHost
  enabled?: string[]
  pending: Pending[] = []
  mailbox = new Map<string, Mail[]>()
  outgoing: Outgoing[] = []
  receipts = new Set<string>()
  #handoffs = new Map<string, { turn: string, text: string }>()
  #reservations = new Map<string, number>()
  #closing = new WeakSet<Session>()
  #starts = new Map<Session, Set<Promise<unknown>>>()
  #timer?: NodeJS.Timeout
  #stopped = false
  #settling = false
  #settleAgain = false
  #naming = new Set<ReturnType<typeof spawn>>()
  constructor(host: CollabHost) { this.host = host }
  get config(): Config { return this.host.config() }
  #prompt(key: string, ...args: unknown[]): string { return format(this.config.collab.prompts[key], ...args) }
  #handle(s: Session): string { return String(s.info.handle ?? s.agent) }
  #title(s: Session): string { return this.config.agents[s.agent]?.title ?? s.agent }
  #status(s: Session): string { return s.asks.size ? 'awaiting-approval' : s.status }
  #working(s: Session): boolean { return s.busy() }
  #target(name: unknown): Session {
    if (typeof name !== 'string') throw new Error('Name a session by its @handle; list them with sessions')
    const s = [...this.host.sessions.values()].find((s) => this.#handle(s) === name.replace(/^@/, '') || s.id === name)
    if (!s) throw new Error(`No agent session called ${name} in this daemon; list them with sessions`)
    return s
  }
  unique(name: string, current?: Session): string {
    let handle = name, n = 1
    while ([...this.host.sessions.values()].some((s) => s !== current && this.#handle(s) === handle)) handle = `${name}-${++n}`
    return handle
  }
  name(s: Session, text: string): void {
    if (s.info.named || s.info.parent) return
    s.setInfo({ named: true, title: s.info.title ?? text.slice(0, 80) })
    const commands = [this.config.collab.agentHandleCommands[s.agent], this.config.collab.handleCommand]
      .filter((cmd): cmd is string[] => !!cmd?.length && executable(cmd[0]))
    const prompt = this.#prompt('handlePrompt') + [...text].slice(0, 1000).join('')
    const next = (index: number) => {
      if (this.#stopped || !this.host.sessions.has(s.id) || !commands[index]) return
      const [command, ...args] = commands[index]
      const p = spawn(command, [...args, prompt], { cwd: tmpdir(), stdio: ['pipe', 'pipe', 'ignore'] })
      this.#naming.add(p)
      p.stdin?.end()
      let output = ''
      p.stdout?.on('data', (data) => { if (output.length < 65536) output += data })
      const timer = setTimeout(() => p.kill(), this.config.collab.handleTimeout * 1000)
      p.on('error', () => {})
      p.once('close', (code) => {
        clearTimeout(timer); this.#naming.delete(p)
        const handle = code === 0 && cleanHandle(output)
        if (handle && this.host.sessions.has(s.id)) s.setInfo({ handle: this.unique(handle, s) })
        else next(index + 1)
      })
    }
    next(0)
  }
  tools(editor: EditorTools, root?: string): EditorTools {
    return { tools: [...editor.tools.filter((t) => !toolNames.includes(t.name)), ...definitions(this.config, this.enabled, root ? this.host.environment?.(root) : undefined)],
      readOnly: [...new Set([...editor.readOnly.filter((name) =>
        !toolNames.includes(name) && editor.tools.some((tool) => tool.name === name)),
        'sessions', 'session_read'])].sort() }
  }
  startSummary(root?: string): string {
    return startSummary(this.config, this.enabled, root ? this.host.environment?.(root) : undefined)
  }
  /** Include asynchronous visibility/hub delivery after pending entries are removed. */
  restartBlockers(): { session?: string, reason: string }[] {
    return [
      ...(this.starting ? [{ reason: 'child creation in flight' }] : []),
      ...(this.#settling ? [{ reason: 'collaboration delivery in flight' }] : []),
      ...this.pending.map((p) => ({ session: p.target, reason: 'session_ask reply pending' })),
      ...[...this.mailbox.keys()].map((session) => ({ session, reason: 'mailbox delivery pending' })),
      ...this.outgoing.map((p) => ({ session: p.route.session, reason: 'cross-daemon reply pending' })),
    ]
  }

  get starting(): boolean { return this.#starts.size > 0 }
  assertOpen(session: Session): void {
    if (this.#closing.has(session) || !this.host.sessions.has(session.id)) {
      throw new Error('The calling session is closing or has been closed')
    }
  }
  /** Mark synchronously; closing waits until no start can register another child. */
  beginClose(session: Session): Promise<unknown> {
    this.#closing.add(session)
    return Promise.allSettled(this.#starts.get(session) ?? [])
  }
  async call(caller: Session, name: string, p: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    signal.throwIfAborted()
    switch (name) {
      case 'sessions': {
        const sessions = this.list(caller)
        try {
          const peers = this.host.hub ? await this.host.hub(caller, '_collab_sessions', {}, signal) as object[] : []
          return { sessions: [...sessions, ...peers] }
        } catch (error) {
          signal.throwIfAborted()
          return { sessions, note: `Other daemons are unavailable: ${(error as Error).message}` }
        }
      }
      case 'session_read': {
        const local = this.find(p.session)
        if (local) return this.read(local, p)
        if (!this.host.hub) return this.read(this.#target(p.session), p)
        return this.host.hub(caller, '_collab_read', p, signal)
      }
      case 'session_ask': this.assertOpen(caller); return this.#ask(caller, p, signal)
      case 'session_start': {
        this.assertOpen(caller)
        const start = this.#start(caller, p, signal)
        let starts = this.#starts.get(caller)
        if (!starts) this.#starts.set(caller, starts = new Set())
        starts.add(start)
        try { return await start } finally {
          starts.delete(start)
          if (!starts.size) this.#starts.delete(caller)
        }
      }
      case 'session_stop': {
        const target = this.#target(p.session)
        if (target.info.parent !== caller.id) throw new Error(`@${this.#handle(target)} isn't a session you started`)
        this.pending = this.pending.filter((entry) => entry.target !== target.id)
        await this.host.close(target); this.save()
        return `Stopped and closed @${this.#handle(target)}.`
      }
      default: throw new Error(`Unknown collaboration tool: ${name}`)
    }
  }
  find(name: unknown): Session | undefined {
    if (typeof name !== 'string') throw new Error('Name a session by its @handle; list them with sessions')
    return [...this.host.sessions.values()].find((s) => this.#handle(s) === name.replace(/^@/, '') || s.id === name)
  }
  list(caller?: Session) {
    return [...this.host.sessions.values()].map((s) => ({ id: '@' + this.#handle(s), session: s.id,
      agent: s.agent, place: 'here', title: s.info.title ?? this.#handle(s), project: s.root,
      status: this.#status(s), turns: turns(s).length, yours: s === caller,
      parent: this.host.sessions.has(String(s.info.parent)) ? '@' + this.#handle(this.host.sessions.get(String(s.info.parent))!) : null,
      children: [...this.host.sessions.values()].filter((c) => c.info.parent === s.id).map((c) => '@' + this.#handle(c)) }))
  }
  /** Editor-only ingress; confirmation belongs to the asking daemon. */
  remoteAsk(target: Session, prompt: string, route: RemoteRoute, origin: { handle: string, agent: string }): string {
    if (target.info.parent) throw new Error('Task sessions take no messages; start another session')
    if (target.status !== 'idle' || this.pending.some((e) => e.target === target.id)) throw new Error(`@${this.#handle(target)} is busy; try later`)
    const block = target.newId('user')
    this.pending.push({ target: target.id, asker: route.session, block, handle: this.#handle(target), route })
    this.save()
    target.sendMessage(prompt, '@' + origin.handle, this.#prompt('messageNote', origin.agent, origin.handle), block)
    return this.#prompt('sent', this.#handle(target))
  }
  receive(id: string, route: RemoteRoute, mail: Mail): void {
    if (this.receipts.has(id)) return
    this.receipts.add(id)
    if (this.host.sessions.has(route.session)) this.mailbox.set(route.session,
      [...this.mailbox.get(route.session) ?? [], mail])
    this.save(); this.schedule()
  }
  read(s: Session, p: Record<string, unknown>): string {
    const tools = p.tools ?? 'summary'
    if (!['none', 'summary', 'full'].includes(String(tools))) throw new Error(`tools must be none, summary or full, not ${tools}`)
    for (const k of ['last', 'before']) if (p[k] !== undefined && !Number.isSafeInteger(p[k])) throw new Error(`${k} must be an integer`)
    const ts = turns(s), total = ts.length
    const end = p.before === undefined ? total : Math.max(0, Math.min(total, Number(p.before) - 1))
    const start = Math.max(0, end - Math.max(1, Number(p.last ?? 2)))
    const header = `Session @${this.#handle(s)} (${this.#title(s)}, ${this.#status(s)}): ${s.info.title ?? this.#handle(s)}`
    if (start === end) return header + `\nNo turns${total ? ' there' : ' yet'}.`
    return header + `\nTurns ${start + 1}-${end} of ${total}.${start ? ` Earlier turns: call again with before=${start + 1}.` : ''}\n\n`
      + ts.slice(start, end).map((t, i) => formatTurn(start + i + 1, t, String(tools), this.#working(s) && start + i + 1 === total, this.config.collab.textLimit)).join('\n\n')
  }
  #handoff(s: Session): string {
    const ts = turns(s), latest = ts.at(-1)?.[0].id ?? ''
    const cached = this.#handoffs.get(s.id)
    if (cached?.turn === latest) return cached.text
    const texts = ts.map((t, i) => formatTurn(i + 1, t, 'full', this.#working(s) && i === ts.length - 1, this.config.collab.textLimit))
    const length = (text: string) => [...text].length
    let budget = this.config.collab.handoffLimit
    let last = texts.at(-1) ?? ''
    if (length(last) > budget) last = '…' + [...last].slice(-budget).join('')
    budget -= length(last)
    let first = ts.length > 1 ? formatTurn(1, [ts[0][0]], 'none', false, this.config.collab.textLimit) : ''
    if (length(first) > budget) first = ''
    budget -= length(first)
    const middle: string[] = []
    for (const text of texts.slice(1, -1).reverse()) {
      if (length(text) > budget) break
      middle.unshift(text); budget -= length(text)
    }
    const omitted = ts.length - 2 - middle.length
    if (first && omitted === 0 && length(texts[0]) <= budget + length(first)) first = texts[0]
    else if (first && omitted > 0) first += `\n\n(Turns 2-${1 + omitted} left out; read them with session_read.)`
    const text = [first, ...middle, last].filter(Boolean).join('\n\n')
    this.#handoffs.set(s.id, { turn: latest, text })
    return text
  }
  async #confirm(caller: Session, label: string, detail: string, signal: AbortSignal): Promise<void> {
    signal.throwIfAborted()
    // Confirmation is a normal user ask, mirrored by Emacs to the parent footer.
    const before = new Set(caller.asks.keys())
    const answer = caller.ask({ type: 'approval', choices: ['allow', 'deny'],
      description: detail, view: { kind: 'task', name: 'collab', title: label } })
    const id = [...caller.asks.keys()].find((id) => !before.has(id))!
    const seconds = this.config.collab.confirmTimeout
    let expired = false
    const timeout = setTimeout(() => { expired = true; caller.answer(id, {}) }, seconds * 1000)
    const cancel = () => caller.answer(id, {})
    signal.addEventListener('abort', cancel, { once: true })
    try {
      const result = await answer
      signal.throwIfAborted()
      if (expired) throw new Error(`The user didn't confirm within ${seconds} seconds`)
      if (result.choice !== 'allow') throw new Error(result.choice === 'deny' ? 'The user declined' : 'The confirmation expired')
    } finally { clearTimeout(timeout); signal.removeEventListener('abort', cancel) }
  }
  #text(p: Record<string, unknown>): string {
    if (typeof p.prompt !== 'string') throw new Error('Missing required parameter prompt')
    return p.prompt
  }
  async #ask(caller: Session, p: Record<string, unknown>, signal: AbortSignal): Promise<string> {
    const prompt = this.#text(p)
    if (caller.info.parent) throw new Error("A session started for a task reports through its final reply; it doesn't ask other sessions")
    const local = this.find(p.session)
    if (!local && this.host.hub) {
      if (this.config.collab.confirm) {
        await this.host.hub(caller, '_collab_sessions', {}, signal)
        await this.#confirm(caller, `向 ${String(p.session)} 发送消息`, prompt, signal)
      }
      signal.throwIfAborted(); this.assertOpen(caller)
      return this.host.hub(caller, '_collab_ask', { ...p,
        origin: { handle: this.#handle(caller), agent: this.#title(caller) } }, signal) as Promise<string>
    }
    const target = local ?? this.#target(p.session)
    const check = () => {
      this.assertOpen(caller)
      if (target === caller) throw new Error('That is your own session')
      if (caller.info.parent) throw new Error("A session started for a task reports through its final reply; it doesn't ask other sessions")
      if (target.info.parent) throw new Error(`@${this.#handle(target)} works on a task it was started for and takes no messages; for more work, start another session (context handoff passes your conversation)`)
      if (!this.host.sessions.has(target.id)) throw new Error('The target session was closed')
      if (target.status !== 'idle') throw new Error(`@${this.#handle(target)} is ${target.status === 'running' ? 'busy; read it with session_read or try later' : target.status}`)
      if (this.pending.some((e) => e.target === target.id)) throw new Error(`@${this.#handle(target)} is busy; try later`)
    }
    check()
    if (this.config.collab.confirm) await this.#confirm(caller, `向 @${this.#handle(target)} 发送消息`, prompt, signal)
    signal.throwIfAborted(); check()
    this.#send(target, caller, prompt, this.#prompt('messageNote', this.#title(caller), this.#handle(caller)))
    return this.#prompt('sent', this.#handle(target))
  }
  async #start(caller: Session, p: Record<string, unknown>, signal: AbortSignal): Promise<string> {
    const prompt = this.#text(p), context = p.context ?? 'fresh'
    if (caller.info.parent) throw new Error("A session started by another session can't start sessions; do the task yourself")
    if (!['fresh', 'handoff', 'fork'].includes(String(context))) throw new Error(`context must be fresh, handoff or fork, not ${context}`)
    const count = [...this.host.sessions.values()].filter((s) => s.info.parent === caller.id && this.#working(s)).length + (this.#reservations.get(caller.id) ?? 0)
    if (count >= this.config.collab.maxActive) throw new Error(`${count} sessions you started are still working, the most at once; wait for one to finish`)
    let name: string, profile: Profile, fork: string | undefined
    if (context === 'fork') {
      if (p.profile !== undefined) throw new Error('A fork uses your own agent and model; omit profile')
      if (!forkAgents.includes(caller.agent)) throw new Error(`${this.#title(caller)} sessions can't fork; use handoff`)
      fork = caller.resumeId()
      if (!fork) throw new Error('Your session has no conversation to fork yet')
      name = this.#handle(caller) + '-fork'; profile = { agent: caller.agent, ...caller.settings }
    } else {
      const entry = profiles(this.config, this.enabled, this.host.environment?.(caller.root)).find(([name]) => name === p.profile)
      if (!entry) throw new Error(`${p.profile ? `No profile ${p.profile} here` : 'Name a profile'}; choose one of: ${profiles(this.config, this.enabled, this.host.environment?.(caller.root)).map(([n]) => n).join(', ')}`)
      ;[name, profile] = entry
    }
    this.#reservations.set(caller.id, (this.#reservations.get(caller.id) ?? 0) + 1)
    let reserved = true
    const release = () => {
      if (!reserved) return
      reserved = false
      const remaining = (this.#reservations.get(caller.id) ?? 1) - 1
      if (remaining) this.#reservations.set(caller.id, remaining)
      else this.#reservations.delete(caller.id)
    }
    let child: Session | undefined
    try {
      if (profile.confirm) await this.#confirm(caller, `启动子会话 ${name}`, prompt, signal)
      signal.throwIfAborted()
      this.assertOpen(caller)
      if (fork) await caller.backend.flush?.()
      signal.throwIfAborted(); this.assertOpen(caller)
      const cap = Math.max(0, modes.indexOf(caller.settings.mode ?? 'plan'))
      const requested = modes.indexOf(profile.mode ?? '')
      const settings = { model: profile.model, effort: profile.effort, mode: modes[Math.min(cap, requested < 0 ? cap : requested)] }
      child = this.host.create(profile.agent, caller.root, settings, { parent: caller.id,
        parentSession: caller.resumeId(), profile: name, named: true, title: p.title ?? prompt.slice(0, 80),
        handle: this.unique(cleanHandle(String(p.handle ?? '')) ?? name), ...(fork ? { forkFrom: fork } : {}),
        skills: sessionSkills(caller) })
      // The registered starting session now owns the concurrency slot.
      release()
      await this.host.view(child)
      signal.throwIfAborted(); this.assertOpen(caller)
      await child.start()
      signal.throwIfAborted(); this.assertOpen(caller)
      const history = context === 'handoff' ? this.#handoff(caller) : ''
      const text = (history ? this.#prompt('handoff', this.#handle(caller), this.#handle(caller), history) : '') + this.#prompt('task') + prompt
      this.#send(child, caller, text, fork ? this.#prompt('forkNote', this.#handle(caller)) : this.#prompt('taskNote', this.#title(caller), this.#handle(caller)))
      return this.#prompt('started', this.#handle(child), this.#title(child), profile.model ? ' ' + profile.model : '', context)
    } catch (error) {
      if (child) await this.host.close(child)
      throw error
    } finally { release() }
  }
  #send(target: Session, asker: Session, text: string, hidden: string): void {
    const block = target.newId('user')
    this.pending.push({ target: target.id, asker: asker.id, block, handle: this.#handle(target) })
    this.save()
    target.sendMessage(text, '@' + this.#handle(asker), hidden, block)
  }
  event(_session: Session, event: SessionEvent): void {
    if (event.type === 'status' || event.type === 'block/remove') this.schedule()
  }
  schedule(): void {
    if (this.#stopped || this.#timer) return
    this.#timer = setTimeout(() => { this.#timer = undefined; void this.settle() }, 0)
  }
  async settle(): Promise<void> {
    if (this.#stopped) return
    if (this.#settling) { this.#settleAgain = true; return }
    this.#settling = true
    try {
      for (const entry of [...this.pending]) {
        // A prior visibility query may have let session_stop revoke this entry.
        if (!this.pending.includes(entry)) continue
        const target = this.host.sessions.get(entry.target), asker = this.host.sessions.get(entry.asker)
        if (target && (this.#working(target) || target.queue.length)) continue
        this.pending = this.pending.filter((e) => e !== entry)
        if (!asker && !entry.route) continue
        const turn = target && turns(target).find((t) => t[0].id === entry.block)
        const text = turn?.findLast((b) => b.type === 'text' && b.kind !== 'thinking') as Extract<Block, {type: 'text'}> | undefined
        const handle = target ? this.#handle(target) : entry.handle ?? entry.target
        const errors = (turn ?? []).filter((b): b is Extract<Block, {type: 'notice'}> => b.type === 'notice' && b.notice.level === 'error')
        let body = text?.text ?? '(no reply)'
        if (errors.length) {
          const messages = [...new Set(errors.map(({ notice }) => {
            const message = String(notice.args?.message ?? '').trim()
            return message ? this.#prompt('replyError', notice.kind, message) : notice.kind
          }))]
          const partial = (turn ?? []).filter((b): b is Extract<Block, {type: 'text'}> => b.type === 'text' && b.kind !== 'thinking')
            .map((b) => b.text.trim()).filter(Boolean).join('\n\n')
          body = this.#prompt('failedReply', messages.join('\n')) + (partial ? this.#prompt('partialReply', partial) : '')
        }
        let reply = target ? this.#replyText(handle, body) : ''
        const tools = (turn ?? []).filter((b): b is Extract<Block, {type: 'tool'}> => b.type === 'tool').map(toolLine)
        const summary = tools.length ? 'What it did:\n' + tools.slice(0, 12).join('\n') + (tools.length > 12 ? `\n- … ${tools.length - 12} more` : '') + '\n\n' : ''
        reply = target ? this.#prompt('reply', handle, this.#title(target), target.status === 'exited' ? ', which then exited' : '', reply,
          target.info.parent ? summary + this.#prompt('childFollowup') : this.#prompt('followup', handle)) : `"@${handle}" ended without replying: it was closed before it replied`
        if (entry.route) this.outgoing.push({ id: entry.block, route: entry.route, mail: { handle, text: reply } })
        else this.mailbox.set(asker!.id, [...this.mailbox.get(asker!.id) ?? [], { handle, text: reply }])
        this.save()
        if (asker && target?.info.parent === asker.id && target.status === 'idle' && this.config.collab.closeFinished
          && !errors.length && !await this.host.visible(target)) {
          await this.host.close(target)
        }
      }
      for (const entry of [...this.outgoing]) {
        try {
          if (!this.host.hub) continue
          await this.host.hub({ id: '', root: '' }, '_collab_deliver', { ...entry }, AbortSignal.timeout(5000))
          this.outgoing = this.outgoing.filter((e) => e !== entry)
          this.save()
        } catch { /* Keep durable mail until both daemon connections are attached. */ }
      }
      for (const [id, mail] of this.mailbox) {
        const s = this.host.sessions.get(id)
        if (!s) { this.mailbox.delete(id); continue }
        if (s.status !== 'idle' || s.queue.length) continue
        this.mailbox.delete(id); this.save()
        s.sendMessage(mail.map((m) => m.text).join('\n\n---\n\n'), mail.length > 1 ? '会话回复' : '@' + mail[0].handle, this.#prompt('mailbox'))
      }
      this.save()
    } finally {
      this.#settling = false
      if (this.#settleAgain) { this.#settleAgain = false; this.schedule() }
    }
  }
  #replyText(handle: string, text: string): string {
    text = text.trim()
    if ([...text].length <= this.config.collab.replyLimit) return text
    const dir = join(this.host.varDir, 'replies')
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const file = join(dir, `${handle}-${Date.now()}.md`)
    writeFileSync(file, text, { mode: 0o600 })
    return clip(text, this.config.collab.replyLimit) + '\n\nFull reply: ' + file + ' (read it with your file tools).'
  }
  save(): void {
    const file = join(this.host.varDir, 'emx', 'collab.json')
    mkdirSync(join(this.host.varDir, 'emx'), { recursive: true, mode: 0o700 })
    writeFileSync(file + '.tmp', JSON.stringify({ enabled: this.enabled, pending: this.pending, mailbox: [...this.mailbox], outgoing: this.outgoing, receipts: [...this.receipts] }), { mode: 0o600 })
    renameSync(file + '.tmp', file)
    this.host.changed()
  }
  restore(): void {
    try {
      const data = JSON.parse(readFileSync(join(this.host.varDir, 'emx', 'collab.json'), 'utf8'))
      if (!Array.isArray(data.pending) || !Array.isArray(data.mailbox)) throw new Error('Invalid collaboration state')
      if (data.enabled !== undefined && (!Array.isArray(data.enabled) || !data.enabled.every((a: unknown) => typeof a === 'string'))) throw new Error('Invalid enabled agents')
      this.enabled = data.enabled
      this.pending = data.pending
      this.mailbox = new Map(data.mailbox)
      this.outgoing = data.outgoing ?? []
      this.receipts = new Set(data.receipts ?? [])
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e }
    this.schedule()
  }
  stop(): void {
    this.#stopped = true; clearTimeout(this.#timer)
    for (const p of this.#naming) p.kill()
  }
}
