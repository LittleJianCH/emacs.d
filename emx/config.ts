// config.ts --- validated configuration, last-good reloads and directory watches.
import { readFileSync, watchFile, unwatchFile, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { emxRoot, stateDir } from './daemon/paths.ts'
import type { EditorTools } from './daemon/protocol.ts'

export interface AgentConfig {
  title: string
  executable: string
  extraArgs?: string[]
  nativeSubagents?: boolean
  disallowedTools?: string[]
  historyTurns?: number
}
export interface Profile {
  agent: string
  model?: string | null
  effort?: string | null
  mode?: string | null
  cost?: string
  description?: string
  confirm?: boolean
}
export interface Config {
  agents: Record<string, AgentConfig>
  profiles: Record<string, Profile>
  collab: {
    startGuidance: string
    maxActive: number
    handoffLimit: number
    closeFinished: boolean
    confirm: boolean
    textLimit: number
    replyLimit: number
    confirmTimeout: number
    handleTimeout: number
    handleCommand: string[]
    agentHandleCommands: Record<string, string[]>
    tools: EditorTools['tools']
    prompts: Record<string, string>
  }
  usage: { pollInterval: number }
  daemon: { idleExit: number }
  sessions: { hibernateAfter: number }
}
function object(value: unknown): value is Record<string, any> {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}
/** Objects merge recursively; arrays, null and scalars replace. */
export function merge(base: any, override: any): any {
  if (!object(base) || !object(override)) return structuredClone(override)
  const result = structuredClone(base)
  for (const key of Object.keys(override)) {
    if (['__proto__', 'prototype', 'constructor'].includes(key)) throw new Error(`Invalid config key: ${key}`)
    result[key] = Object.hasOwn(base, key) ? merge(base[key], override[key]) : structuredClone(override[key])
  }
  return result
}
export function validate(value: unknown): Config {
  const fail = (path: string, type: string): never => { throw new Error(`config.${path}: expected ${type}`) }
  const obj = (v: any, p: string) => { if (!object(v)) fail(p, 'object'); return v as Record<string, any> }
  const str = (v: any, p: string) => { if (typeof v !== 'string') fail(p, 'string') }
  const bool = (v: any, p: string) => { if (typeof v !== 'boolean') fail(p, 'boolean') }
  const num = (v: any, p: string, min = 0) => {
    if (!Number.isSafeInteger(v) || v < min || v > 2147483) fail(p, `integer ${min}..2147483`)
  }
  const array = (v: any, p: string) => {
    if (!Array.isArray(v) || !v.every((s) => typeof s === 'string')) fail(p, 'string[]')
  }
  const keys = (v: any, allowed: string[], p: string) => {
    obj(v, p)
    for (const key of Object.keys(v)) if (!allowed.includes(key)) throw new Error(`config.${p ? p + '.' : ''}${key}: unknown key`)
  }
  const c = obj(value, '')
  keys(c, ['agents', 'profiles', 'collab', 'usage', 'daemon', 'sessions'], '')
  for (const [name, a] of Object.entries(obj(c.agents, 'agents'))) {
    const p = `agents.${name}`
    keys(a, ['title', 'executable', 'extraArgs', 'nativeSubagents', 'disallowedTools', 'historyTurns'], p)
    str(a.title, p + '.title'); str(a.executable, p + '.executable')
    if (!a.executable) fail(p + '.executable', 'nonempty string')
    if (a.extraArgs !== undefined) array(a.extraArgs, p + '.extraArgs')
    if (a.disallowedTools !== undefined) array(a.disallowedTools, p + '.disallowedTools')
    if (a.nativeSubagents !== undefined) bool(a.nativeSubagents, p + '.nativeSubagents')
    if (a.historyTurns !== undefined) num(a.historyTurns, p + '.historyTurns', 1)
  }
  for (const [name, a] of Object.entries(obj(c.profiles, 'profiles'))) {
    const p = `profiles.${name}`
    keys(a, ['agent', 'model', 'effort', 'mode', 'cost', 'description', 'confirm'], p)
    str(a.agent, p + '.agent')
    if (!c.agents[a.agent]) fail(p + '.agent', 'configured agent')
    for (const k of ['model', 'effort', 'mode', 'cost', 'description']) if (a[k] != null) str(a[k], p + '.' + k)
    if (a.mode != null && !['plan', 'ask', 'edits', 'auto', 'full'].includes(a.mode)) fail(p + '.mode', 'permission mode')
    if (a.cost !== undefined && !['minimal', 'low', 'medium', 'high', 'premium'].includes(a.cost)) fail(p + '.cost', 'cost tier')
    if (a.confirm !== undefined) bool(a.confirm, p + '.confirm')
  }
  const collab = obj(c.collab, 'collab')
  keys(collab, ['startGuidance', 'maxActive', 'handoffLimit', 'closeFinished', 'confirm', 'textLimit', 'replyLimit', 'confirmTimeout', 'handleTimeout', 'handleCommand', 'agentHandleCommands', 'tools', 'prompts'], 'collab')
  str(collab.startGuidance, 'collab.startGuidance')
  for (const k of ['maxActive', 'handoffLimit', 'textLimit', 'replyLimit', 'confirmTimeout', 'handleTimeout']) num(collab[k], 'collab.' + k, 1)
  for (const k of ['closeFinished', 'confirm']) bool(collab[k], 'collab.' + k)
  array(collab.handleCommand, 'collab.handleCommand')
  for (const [k, v] of Object.entries(obj(collab.agentHandleCommands, 'collab.agentHandleCommands'))) array(v, 'collab.agentHandleCommands.' + k)
  for (const [k, v] of Object.entries(obj(collab.prompts, 'collab.prompts'))) str(v, 'collab.prompts.' + k)
  for (const k of ['handoff', 'forkNote', 'taskNote', 'messageNote', 'mailbox', 'reply', 'childFollowup', 'followup', 'started', 'sent', 'mention', 'profileHeader', 'handlePrompt', 'task']) str(collab.prompts[k], 'collab.prompts.' + k)
  if (!Array.isArray(collab.tools) || collab.tools.length !== 5) fail('collab.tools', 'five tool definitions')
  for (const name of ['sessions', 'session_read', 'session_ask', 'session_start', 'session_stop']) {
    const t = collab.tools.find((t: any) => t.name === name)
    if (!t || typeof t.description !== 'string' || t.inputSchema?.type !== 'object'
      || !object(t.inputSchema.properties) || !Array.isArray(t.inputSchema.required)) fail('collab.tools.' + name, 'tool definition')
  }
  for (const [section, key] of [['usage', 'pollInterval'], ['daemon', 'idleExit'], ['sessions', 'hibernateAfter']]) {
    keys(c[section], [key], section); num(c[section][key], section + '.' + key)
  }
  return c as Config
}
export class Configuration {
  value: Config
  errors: string[] = []
  readonly defaults: string
  readonly override: string
  #watched: string[] = []
  #timer?: NodeJS.Timeout
  constructor(varDir: string, defaults = join(emxRoot, 'config.json')) {
    this.defaults = defaults
    this.override = join(stateDir(varDir), 'config.json')
    this.value = validate(JSON.parse(readFileSync(defaults, 'utf8')))
    this.reload()
  }
  reload(): { config: Config, errors: string[], changed: boolean } {
    let changed = false
    try {
      const base = JSON.parse(readFileSync(this.defaults, 'utf8'))
      let override = {}
      try { override = JSON.parse(readFileSync(this.override, 'utf8')) }
      catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e }
      if (!object(override)) throw new Error(`${this.override}: expected object`)
      const next = validate(merge(base, override))
      changed = JSON.stringify(next) !== JSON.stringify(this.value)
      this.value = next
      this.errors = []
    } catch (error) { this.errors = [String(error)] }
    return { config: this.value, errors: this.errors, changed }
  }
  watch(changed: (result: ReturnType<Configuration['reload']>) => void): void {
    mkdirSync(dirname(this.override), { recursive: true, mode: 0o700 })
    for (const file of [this.defaults, this.override]) {
      // Poll the two tiny files, including inode replacement and deletion.
      // fs.watch can exhaust kqueue watches in long-lived editor processes.
      watchFile(file, { interval: 250, persistent: false }, () => {
        clearTimeout(this.#timer)
        this.#timer = setTimeout(() => changed(this.reload()), 75)
      })
      this.#watched.push(file)
    }
  }
  close(): void { clearTimeout(this.#timer); for (const file of this.#watched) unwatchFile(file) }
}
