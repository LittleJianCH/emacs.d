import { sessionSkills } from '../backends/backend.ts'
import { delegationProfiles, profileTools, sessionProfile } from './profiles.ts'
// collab.ts --- daemon-owned tools, children, mailbox and task context.
import { spawn } from 'node:child_process'
import { accessSync, appendFileSync, constants, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { delimiter, isAbsolute, join } from 'node:path'
import { homedir, tmpdir } from 'node:os'
import { allowedModel, defaultModel as piDefaultModel } from '../backends/pi.ts'
import type { UsageService } from '../usage/service.ts'
import type { Config, Profile, ProfileCandidate } from '../config.ts'
import { candidateDisabledBy, profileCandidates } from '../config.ts'
import type { Block, CollabProfiles, EditorTools, SessionEvent, Settings, Usage } from './protocol.ts'
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
/** Model names that quota window ids may carry to scope a window to one model. */
const scopedModels = ['fable', 'opus', 'sonnet', 'haiku']
/** Static role display tier, shared by descriptions and summaries. */
export function profileCost(name: string, profile: Profile): string {
  return profile.cost ?? 'unknown'
}
export { profileCandidates }
/** Shared runtime checks for guidance, the catalog and candidate selection. */
function candidateUnavailable(c: Config, candidate: ProfileCandidate, enabled: string[] | undefined, env: NodeJS.ProcessEnv): string | undefined {
  const { agent, model } = candidate
  if (!availableAgent(c, agent, enabled, env)) return c.collab.prompts.candidateUnavailable
  if (agent === 'pi' && !allowedModel(model || c.agents.pi.defaultModel || piDefaultModel, c.agents.pi)) {
    return c.collab.prompts.candidateModelExcluded
  }
}
export function profiles(c: Config, enabled?: string[], env: NodeJS.ProcessEnv = process.env): [string, Profile][] {
  const rank = ([name, p]: [string, Profile]) => costRanks[profileCost(name, p)] ?? costRanks.unknown
  return Object.entries(c.profiles).filter(([name, p]) => name !== 'orchestrator' && profileCandidates(p).some((candidate) =>
    !candidateDisabledBy(c, name, candidate).length && !candidateUnavailable(c, candidate, enabled, env)))
    .sort((a, b) => rank(a) - rank(b))
}
function profileLines(available: [string, Profile][]): string {
  return available.map(([name, p]) => `- ${name}: ${profileCost(name, p)} cost.  ${p.description ?? ''}`).join('\n')
}
export function startSummary(c: Config, enabled?: string[], env: NodeJS.ProcessEnv = process.env): string {
  const lines = profiles(c, enabled, env).map(([name, p]) => `  - ${name} (${profileCost(name, p)})${p.use ? ': ' + p.use : ''}`)
  return lines.length ? c.collab.prompts.delegation + '\n' + format(c.collab.prompts.startSummary, lines.join('\n')) : ''
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
      + profileLines(profiles(c, enabled, env)) }
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
interface Pending { target: string, asker: string, block: string, handle?: string, route?: RemoteRoute, run?: number }
/** What a run record needs that is gone once its child closes. */
interface RunStart { run: number, start: number, root: string, parent: { session: string, handle: string, agent: string, model: string | null },
  handle: string, title: string, profile: string, context: string, agent: string, model: string | null, effort: string | null, mode: string | null }
type RunOutcome = { outcome: 'ok' | 'failed' | 'closed', errors?: string[], turn?: Block[], reply?: number }
interface Outgoing { id: string, route: RemoteRoute, mail: Mail }
interface Mail { handle: string, text: string, source?: string }
export interface CollabHost {
  sessions: Map<string, Session>
  config(): Config
  hub?(caller: { id: string, root: string }, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>
  environment?(root: string): NodeJS.ProcessEnv
  usage?: Pick<UsageService, 'quotas'> & Partial<Pick<UsageService, 'candidateAvailability'>>
  /** Token sums by model over a session's original backend events. */
  runUsage?(id: string): Map<string, Usage> | undefined
  varDir: string
  create(agent: string, root: string, settings: Settings, info: Record<string, unknown>): Session
  close(session: Session, completed?: boolean): Promise<void>
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
  /** Run numbers handed out so far, daemon-wide and persisted. */
  runs = 0
  /** Children not yet in the run log, by session id. */
  active = new Map<string, RunStart>()
  #handoffs = new Map<string, { turn: string, text: string }>()
  #reservations = new Map<string, number>()
  #closing = new WeakSet<Session>()
  #deliveries = new Map<Outgoing, AbortController>()
  #starts = new Map<Session, Set<Promise<unknown>>>()
  #startControllers = new Map<Session, Set<AbortController>>()
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
  #working(s: Session): boolean { return s.busy() || s.pendingWork() }
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
  tools(editor: EditorTools, root?: string, caller?: Session): EditorTools {
    const source: EditorTools = { tools: [...editor.tools.filter((t) => !toolNames.includes(t.name)), ...definitions(this.config, this.enabled, this.#environment(root))],
      readOnly: [...new Set([...editor.readOnly.filter((name) =>
        !toolNames.includes(name) && editor.tools.some((tool) => tool.name === name)),
        'sessions', 'session_read'])].sort() }
    if (!caller) return source
    const filtered = profileTools(this.config, caller, source)
    const targets = delegationProfiles(this.config, caller)
    if (!caller.info.parent && targets === undefined) return filtered
    for (const tool of filtered.tools) if (tool.name === 'session_start') {
      const allowed = profiles(this.config, this.enabled, this.#environment(root))
        .filter(([name]) => name !== 'orchestrator' && (!targets || targets.includes(name)))
      if (!allowed.length && (caller.info.parent || targets)) {
        filtered.tools = filtered.tools.filter((entry) => entry !== tool)
        continue
      }
      const description = caller.info.parent
        ? 'Start one bounded helper task. Only context fresh or handoff is allowed; forks are forbidden. The final reply arrives automatically.'
        : 'Start a bounded task with context fresh, handoff or fork. A fork inherits your own provider conversation and profile.'
      tool.description = description + '\n' + this.config.collab.startGuidance + '\n'
        + this.config.collab.prompts.profileHeader + profileLines(allowed)
      if (targets || caller.info.parent) tool.inputSchema = { ...tool.inputSchema,
        properties: { ...(tool.inputSchema.properties as object),
          profile: { type: 'string', enum: allowed.map(([name]) => name) },
          ...(caller.info.parent ? { context: { type: 'string', enum: ['fresh', 'handoff'],
            description: 'How the helper gets context: fresh (default) or bounded text handoff' } } : {}) } }
    }
    return filtered
  }
  startSummary(root?: string, caller?: Session): string {
    if (!caller) return startSummary(this.config, this.enabled, this.#environment(root))
    const tools = this.tools({ tools: [], readOnly: [] }, root, caller)
    if (!tools.tools.some((tool) => tool.name === 'session_start')) {
      return 'Do the assigned work with your available tools. Delegation is unavailable; report through your final reply.'
    }
    if (caller.info.parent || delegationProfiles(this.config, caller)) return 'You may delegate bounded helper tasks only to the listed profiles. Wait for their results before your final reply.'
    return startSummary(this.config, this.enabled, this.#environment(root))
  }
  projectEnvironment(root: string): NodeJS.ProcessEnv { return this.#environment(root) }
  #environment(root?: string): NodeJS.ProcessEnv {
    return (root === undefined ? undefined : this.host.environment?.(root)) ?? process.env
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
  /** Revoke the entire subtree before any persistence or visibility await. */
  beginClose(session: Session, completed = false): Promise<unknown> {
    const subtree = new Set([session])
    for (const node of subtree) {
      this.#closing.add(node)
      node.beginClose()
      for (const controller of this.#startControllers.get(node) ?? []) controller.abort(new Error('Session is closing'))
      for (const child of this.host.sessions.values()) if (child.info.parent === node.id) subtree.add(child)
    }
    const ids = new Set([...subtree].map((node) => node.id))
    // A child closed before its result was delivered: stopped, or torn down with its parent.
    for (const node of subtree) if (this.active.has(node.id)) this.#logRun(node, { outcome: 'closed' })
    this.pending = this.pending.filter((entry) => !ids.has(entry.target) && (!!entry.route || !ids.has(entry.asker)))
    const cancelledSource = (source?: string) => !!source && ids.has(source) && !(completed && source === session.id)
    for (const [id, mail] of this.mailbox) {
      const kept = mail.filter((entry) => !cancelledSource(entry.source))
      if (ids.has(id) || !kept.length) this.mailbox.delete(id)
      else this.mailbox.set(id, kept)
    }
    this.outgoing = this.outgoing.filter((entry) => {
      if (!cancelledSource(entry.mail.source)) return true
      this.#deliveries.get(entry)?.abort(new Error('Session is closing'))
      return false
    })
    this.save()
    return Promise.allSettled([...subtree].flatMap((node) => [...this.#starts.get(node) ?? []]))
  }

  async call(caller: Session, name: string, p: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    signal.throwIfAborted()
    if (!this.tools({ tools: [], readOnly: [] }, caller.root, caller).tools.some((tool) => tool.name === name)) {
      throw new Error(`Tool ${name} is not allowed for profile ${sessionProfile(caller)}${name === 'session_start' ? "; this profile can't start sessions" : name === 'session_ask' ? "; a task session doesn't ask other sessions" : ''}`)
    }
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
        const controller = new AbortController()
        let controllers = this.#startControllers.get(caller)
        if (!controllers) this.#startControllers.set(caller, controllers = new Set())
        controllers.add(controller)
        const start = this.#start(caller, p, AbortSignal.any([signal, controller.signal]))
        let starts = this.#starts.get(caller)
        if (!starts) this.#starts.set(caller, starts = new Set())
        starts.add(start)
        try { return await start } finally {
          controllers.delete(controller)
          if (!controllers.size) this.#startControllers.delete(caller)
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
    this.assertOpen(target)
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
    const target = this.host.sessions.get(route.session)
    if (target && !this.#closing.has(target)) this.mailbox.set(route.session,
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
      this.assertOpen(target)
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
  /** Shared by selection and the editor catalog; keep quota reasons identical. */
  #strain({ agent, model }: ProfileCandidate, quotaSkip: number): string | undefined {
    // Only this daemon's local account matters, including on a host daemon.
    const quota = this.host.usage?.quotas.find((q) => q.agent === agent && q.host == null && !q.duplicate)
    if (!quota) return
    const now = Date.now() / 1000
    // Ignore expired readings, overage credit and windows scoped to other models.
    const applies = (w: { id: string, resets?: number | null }) => !(w.resets != null && w.resets <= now)
      && !/overage/.test(w.id)
      && ((scope) => !scope || (model ?? '').includes(scope))(scopedModels.find((m) => w.id.includes(m)))
    const window = quota.windows.find((w) => applies(w) && (w.limited || (w.used ?? -1) >= quotaSkip))
    // Window labels belong to the Chinese UI; ids keep agent notes in English.
    if (window) return window.limited
      ? this.#prompt('candidateQuotaLimited', window.id)
      : this.#prompt('candidateQuotaUsed', window.id, Math.round(window.used! * 100))
    if (quota.balance?.length && quota.balance.every((b) => b.amount <= 0)) return this.#prompt('candidateBalanceExhausted')
  }
  candidateStatus(name: string, candidate: ProfileCandidate, env: NodeJS.ProcessEnv): Omit<CollabProfiles['profiles'][number]['candidates'][number], 'agent' | 'model' | 'effort'> {
    const { agent } = candidate
    const availability = this.host.usage?.candidateAvailability?.(agent, agentExecutable(this.config, agent, env), env)
    const accountUnavailable = availability?.state === 'unavailable'
      ? availability.reason === 'unauthenticated' ? 'Claude is not logged in'
        : 'The current Claude subscription does not support Claude Code'
      : undefined
    const unavailable = candidateUnavailable(this.config, candidate, this.enabled, env) ?? accountUnavailable
    const disabledBy = candidateDisabledBy(this.config, name, candidate)
    const quotaSkip = this.config.agents[agent].quotaSkip ?? this.config.collab.quotaSkip
    return { disabled: disabledBy.length > 0, disabledBy, available: !unavailable,
      ...(availability ? {availability} : {}), unavailable,
      strained: availability && availability.state !== 'available' ? undefined : this.#strain(candidate, quotaSkip), quotaSkip }
  }
  profiles(overridden: string[] = [], root?: string): CollabProfiles {
    const env = this.#environment(root)
    return { quotaSkip: this.config.collab.quotaSkip, profiles: Object.entries(this.config.profiles).map(([name, role]) => {
      const candidates = profileCandidates(role).map((candidate) => ({ agent: candidate.agent, model: candidate.model ?? null,
        ...(candidate.effort != null ? { effort: candidate.effort } : {}),
        ...(candidate.mode != null ? { mode: candidate.mode } : {}), ...this.candidateStatus(name, candidate, env) }))
      return { name, cost: profileCost(name, role), description: role.description ?? '',
        disabled: candidates.every((candidate) => candidate.disabled), overridden: overridden.includes(name), candidates }
    }) }
  }
  #select(caller: Session, name: string, role: Profile): { candidate: ProfileCandidate, note: string } {
    const env = this.#environment(caller.root)
    const candidates = profileCandidates(role).filter((candidate) => !candidateDisabledBy(this.config, name, candidate).length).map((candidate) => ({
      candidate, label: (this.config.agents[candidate.agent]?.title ?? candidate.agent) + (candidate.model ? ' ' + candidate.model : ''),
      ...this.candidateStatus(name, candidate, env),
    }))
    if (!candidates.length) throw new Error(`Profile ${name} is disabled`)
    const available = candidates.filter((c) => !c.unavailable)
    const healthy = available.filter((c) => !c.strained)
    const chosen = (role.preferOtherAgent && healthy.find((c) => c.candidate.agent !== caller.agent)) || healthy[0] || available[0]
    const reason = (c: typeof candidates[number]) => this.#prompt('candidateSkipped', c.label,
      c.unavailable ?? c.strained ?? this.#prompt('candidateSameAgent'))
    if (!chosen) throw new Error(this.#prompt('noCandidate', name, candidates.map(reason).join('; ')))
    const skipped = candidates.slice(0, candidates.indexOf(chosen)).map(reason)
    return { candidate: chosen.candidate, note: skipped.length ? this.#prompt('candidatesSkipped', skipped.join('; ')) : '' }
  }
  /** Availability for a project, shared by open, model lists and selection. */
  profileCandidate(name: string, root: string, agent?: string, model?: string | null, settings: Settings = {}): ProfileCandidate {
    const role = this.config.profiles[name]
    if (!role) throw new Error(`Unknown profile: ${name}`)
    const candidates = profileCandidates(role).filter((candidate) =>
      (agent === undefined || candidate.agent === agent) && (model === undefined || (candidate.model ?? null) === model)
      && (settings.effort === undefined || (candidate.effort ?? null) === settings.effort)
      && (settings.mode === undefined || (candidate.mode ?? null) === settings.mode))
    const candidate = candidates.find((candidate) => {
      const status = this.candidateStatus(name, candidate, this.#environment(root))
      return status.available && !status.disabled && !status.strained
    })
    if (!candidate) throw new Error(`No selectable candidate for profile ${name}`)
    return structuredClone(candidate)
  }
  modelStatus(name: string, root: string, candidate: ProfileCandidate) {
    return this.candidateStatus(name, candidate, this.#environment(root))
  }
  /** Descendant creation and undelivered results keep a task alive. */
  hasDependencies(session: Session): boolean {
    return this.#starts.has(session) || this.mailbox.has(session.id)
      || this.pending.some((entry) => entry.asker === session.id)
      || [...this.host.sessions.values()].some((child) => child.info.parent === session.id
        && (child.busy() || child.operating || child.asks.size > 0 || child.queue.length > 0 || this.hasDependencies(child)))
  }
  rootSession(session: Session): Session {
    const seen = new Set<string>()
    while (typeof session.info.parent === 'string') {
      if (seen.has(session.id)) throw new Error('Invalid session ancestry')
      seen.add(session.id)
      const parent = this.host.sessions.get(session.info.parent)
      if (!parent) throw new Error('Parent session is closed')
      this.assertOpen(parent)
      session = parent
    }
    return session
  }
  async #start(caller: Session, p: Record<string, unknown>, signal: AbortSignal): Promise<string> {
    const prompt = this.#text(p), context = p.context ?? 'fresh'
    const targets = delegationProfiles(this.config, caller)
    if (targets?.length === 0) throw new Error("This profile cannot start sessions; do the task yourself")
    if (caller.info.parent && context === 'fork') throw new Error('Nested task sessions cannot fork')
    if (context !== 'fork' && (p.profile === 'orchestrator' || targets && !targets.includes(String(p.profile)))) {
      throw new Error(`Profile ${String(p.profile)} is not an allowed delegation target`)
    }
    if (!['fresh', 'handoff', 'fork'].includes(String(context))) throw new Error(`context must be fresh, handoff or fork, not ${context}`)
    const root = this.rootSession(caller)
    const count = [...this.host.sessions.values()].filter((s) => s.info.parent && this.rootSession(s) === root
      && (this.#working(s) || this.hasDependencies(s) || this.pending.some((entry) => entry.target === s.id))).length
      + (this.#reservations.get(root.id) ?? 0)
    if (count >= this.config.collab.maxActive) throw new Error(`${count} sessions you started are still working, the most at once; wait for one to finish`)
    let name: string, profile: ProfileCandidate, fork: string | undefined, confirm = false, note = ''
    if (context === 'fork') {
      if (p.profile !== undefined) throw new Error('A fork uses your own agent and model; omit profile')
      if (!forkAgents.includes(caller.agent)) throw new Error(`${this.#title(caller)} sessions can't fork; use handoff`)
      fork = caller.resumeId()
      if (!fork) throw new Error('Your session has no conversation to fork yet')
      name = this.#handle(caller) + '-fork'; profile = { agent: caller.agent, ...caller.settings }
    } else {
      const role = typeof p.profile === 'string' && Object.hasOwn(this.config.profiles, p.profile) ? this.config.profiles[p.profile] : undefined
      if (!role) throw new Error(`${p.profile ? `No profile ${p.profile} here` : 'Name a profile'}; choose one of: ${profiles(this.config, this.enabled, this.host.environment?.(caller.root)).map(([n]) => n).join(', ')}`)
      name = String(p.profile)
      const selected = this.#select(caller, name, role)
      profile = selected.candidate; note = selected.note; confirm = !!role.confirm
    }
    this.#reservations.set(root.id, (this.#reservations.get(root.id) ?? 0) + 1)
    let reserved = true
    const release = () => {
      if (!reserved) return
      reserved = false
      const remaining = (this.#reservations.get(root.id) ?? 1) - 1
      if (remaining) this.#reservations.set(root.id, remaining)
      else this.#reservations.delete(root.id)
    }
    let child: Session | undefined
    try {
      if (confirm) await this.#confirm(caller, `启动子会话 ${name}`, prompt, signal)
      signal.throwIfAborted()
      this.assertOpen(caller)
      if (fork) await caller.backend.flush?.()
      signal.throwIfAborted(); this.assertOpen(caller)
      const cap = Math.max(0, modes.indexOf(caller.settings.mode ?? 'plan'))
      const requested = modes.indexOf(profile.mode ?? '')
      const settings = { model: profile.model, effort: profile.effort, mode: modes[Math.min(cap, requested < 0 ? cap : requested)] }
      const run = ++this.runs
      child = this.host.create(profile.agent, caller.root, settings, { parent: caller.id, run,
        parentSession: caller.resumeId(), profile: context === 'fork' ? sessionProfile(caller) : name, named: true, title: p.title ?? prompt.slice(0, 80),
        handle: this.unique(cleanHandle(String(p.handle ?? '')) ?? name), ...(fork ? { forkFrom: fork } : {}),
        skills: sessionSkills(caller) })
      // The registered starting session now owns the concurrency slot.
      release()
      this.active.set(child.id, { run, start: Date.now() / 1000, root: child.root,
        parent: { session: caller.id, handle: this.#handle(caller), agent: caller.agent, model: this.#model(caller) },
        handle: this.#handle(child), title: String(child.info.title ?? ''), profile: String(child.info.profile),
        context: String(context), agent: profile.agent, model: settings.model ?? null,
        effort: settings.effort ?? null, mode: settings.mode ?? null })
      this.save()
      await this.host.view(child)
      signal.throwIfAborted(); this.assertOpen(caller); this.assertOpen(child)
      await child.start()
      signal.throwIfAborted(); this.assertOpen(caller); this.assertOpen(child)
      const history = context === 'handoff' ? this.#handoff(caller) : ''
      const text = (history ? this.#prompt('handoff', this.#handle(caller), this.#handle(caller), history) : '') + this.#prompt('task') + prompt
      const taskNote = fork ? this.#prompt('forkNote', this.#handle(caller)) : this.#prompt('taskNote', this.#title(caller), this.#handle(caller))
      const canDelegate = this.tools({ tools: [], readOnly: [] }, child.root, child).tools.some((tool) => tool.name === 'session_start')
      this.#send(child, caller, text, canDelegate
        ? taskNote.replace("You can't start sessions yourself.", 'You may start only the bounded helper profiles listed in your session_start tool. Wait for their results before your final reply.')
        : taskNote)
      return this.#prompt('started', this.#handle(child), this.#title(child), context) + note
    } catch (error) {
      if (child && this.active.has(child.id)) this.#logRun(child, this.#closing.has(caller) || this.#closing.has(child)
        ? { outcome: 'closed' } : { outcome: 'failed', errors: ['startup'] })
      if (child) await this.host.close(child)
      throw error
    } finally { release() }
  }
  #send(target: Session, asker: Session, text: string, hidden: string): void {
    this.assertOpen(target); this.assertOpen(asker)
    const block = target.newId('user')
    const run = this.active.get(target.id)?.parent.session === asker.id ? this.active.get(target.id)!.run : undefined
    this.pending.push({ target: target.id, asker: asker.id, block, handle: this.#handle(target), ...(run ? { run } : {}) })
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
        if (target && this.#closing.has(target) || asker && this.#closing.has(asker) && !entry.route) {
          this.pending = this.pending.filter((e) => e !== entry)
          continue
        }
        if (target && (this.#working(target) || target.operating || target.queue.length || target.asks.size || this.hasDependencies(target))) continue
        if (!asker && !entry.route) {
          this.pending = this.pending.filter((e) => e !== entry)
          continue
        }
        const history = target ? turns(target) : []
        const first = history.findIndex((turn) => turn[0].id === entry.block)
        // A nested helper result starts a continuation turn in its coder.
        // Deliver the coder's last integrated reply, not its pre-helper answer.
        const turn = first < 0 ? undefined : target?.info.parent ? history.slice(first).flat() : history[first]
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
        const run = entry.run !== undefined && !entry.route ? this.active.get(entry.target) : undefined
        const label = entry.run !== undefined ? this.#prompt('runLabel', entry.run) : ''
        reply = target ? this.#prompt('reply', handle, this.#title(target), label + (target.status === 'exited' ? ', which then exited' : ''), reply,
          target.info.parent ? summary + this.#prompt('childFollowup') : this.#prompt('followup', handle)) : `"@${handle}"${label} ended without replying: it was closed before it replied`
        // Keep the pending entry revocable while visibility is in flight.
        const close = asker && target?.info.parent === asker.id && target.status === 'idle'
          && this.config.collab.closeFinished && !errors.length && !await this.host.visible(target)
        if (!this.pending.includes(entry) || target && this.#closing.has(target)
          || asker && this.#closing.has(asker) && !entry.route) continue
        this.pending = this.pending.filter((e) => e !== entry)
        if (target && run?.run === entry.run) this.#logRun(target, { outcome: errors.length ? 'failed' : 'ok',
          errors: [...new Set(errors.map(({ notice }) => notice.kind))], turn, reply: [...(text?.text ?? '').trim()].length })
        const mail = { handle, text: reply, source: entry.target }
        if (entry.route) this.outgoing.push({ id: entry.block, route: entry.route, mail })
        else this.mailbox.set(asker!.id, [...this.mailbox.get(asker!.id) ?? [], mail])
        this.save()
        // Persist the reply before teardown, preserving this completed result.
        if (close) await this.host.close(target!, true)
      }
      for (const entry of [...this.outgoing]) {
        if (!this.outgoing.includes(entry)) continue
        const controller = new AbortController()
        this.#deliveries.set(entry, controller)
        try {
          if (!this.host.hub) continue
          await this.host.hub({ id: '', root: '' }, '_collab_deliver', { ...entry }, AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]))
          this.outgoing = this.outgoing.filter((e) => e !== entry)
          this.save()
        } catch { /* Keep durable mail until both daemon connections are attached. */ }
        finally { this.#deliveries.delete(entry) }
      }
      for (const [id, mail] of this.mailbox) {
        const s = this.host.sessions.get(id)
        if (!s || this.#closing.has(s)) { this.mailbox.delete(id); continue }
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
  #model(s: Session): string | null {
    return typeof s.info.model === 'string' ? s.info.model : s.settings.model ?? null
  }
  get #runFile(): string { return join(this.host.varDir, 'emx', 'subagent-runs.jsonl') }
  /** Rows of var/emx/subagent-runs.jsonl, skipping damaged lines. */
  runLog(): Record<string, any>[] {
    let text = ''
    try { text = readFileSync(this.#runFile, 'utf8') } catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e }
    return text.split('\n').flatMap((line) => {
      try { const row = JSON.parse(line); return row && typeof row === 'object' ? [row] : [] } catch { return [] }
    })
  }
  #append(row: object): void {
    mkdirSync(join(this.host.varDir, 'emx'), { recursive: true, mode: 0o700 })
    appendFileSync(this.#runFile, JSON.stringify(row) + '\n', { mode: 0o600 })
  }
  /** Append the run record of a child once, when its result is settled or lost. */
  #logRun(target: Session | undefined, result: RunOutcome, id = target!.id): void {
    const start = this.active.get(id)
    if (!start) return
    this.active.delete(id)
    const end = Date.now() / 1000
    const usage = this.host.runUsage?.(id) ?? new Map<string, Usage>()
    const tokens = { input: 0, cache_read: 0, cache_write: 0, output: 0 }
    let model: string | null = null, most = -1
    for (const [name, u] of usage) {
      tokens.input += u.input; tokens.cache_read += u.cacheRead; tokens.cache_write += u.cacheWrite; tokens.output += u.output
      const total = u.input + u.cacheRead + u.cacheWrite + u.output
      if (total > most) { most = total; model = name }
    }
    const blocks = result.turn ?? target?.blocks ?? []
    const texts = blocks.filter((b): b is Extract<Block, {type: 'text'}> => b.type === 'text' && b.kind !== 'thinking')
    const home = homedir()
    try {
      this.#append({ type: 'run', run: start.run, start: start.start, end, duration: Math.round((end - start.start) * 10) / 10,
        root: start.root.startsWith(home + '/') ? '~' + start.root.slice(home.length) : start.root,
        parent: start.parent, handle: start.handle, title: start.title, profile: start.profile, context: start.context,
        agent: start.agent, effort: start.effort, mode: start.mode, requested_model: start.model,
        model: model ?? (target ? this.#model(target) : null) ?? start.model,
        ...(usage.size > 1 ? { models: [...usage.keys()] } : {}),
        outcome: result.outcome, ...(result.errors?.length ? { errors: result.errors } : {}),
        tools: blocks.filter((b) => b.type === 'tool').length,
        reply: result.reply ?? [...(texts.at(-1)?.text ?? '').trim()].length, tokens })
    } catch { /* The run log is best-effort; delivery must not depend on it. */ }
    this.save()
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
    writeFileSync(file + '.tmp', JSON.stringify({ enabled: this.enabled, pending: this.pending, mailbox: [...this.mailbox], outgoing: this.outgoing, receipts: [...this.receipts],
      runs: this.runs, active: [...this.active] }), { mode: 0o600 })
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
      if (Number.isSafeInteger(data.runs)) this.runs = data.runs
      if (Array.isArray(data.active)) this.active = new Map(data.active)
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e }
    // Never reuse a logged run number, even if collab.json was lost.
    for (const row of this.runLog()) if (Number.isSafeInteger(row.run) && row.run > this.runs) this.runs = row.run
    // Children are not restored: their runs ended with the previous daemon.
    for (const id of this.active.keys()) if (!this.host.sessions.has(id)) this.#logRun(undefined, { outcome: 'closed' }, id)
    this.schedule()
  }
  stop(): void {
    this.#stopped = true; clearTimeout(this.#timer)
    for (const p of this.#naming) p.kill()
  }
}
