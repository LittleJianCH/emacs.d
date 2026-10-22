// config.ts --- validated configuration, last-good reloads and directory watches.
import { readFileSync, watchFile, unwatchFile, mkdirSync, writeFileSync, renameSync } from 'node:fs'
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
  defaultModel?: string
  models?: { include: string[], exclude: string[] }
}
export interface ProfileCandidate {
  agent: string
  model?: string | null
  effort?: string | null
  mode?: string | null
}
export interface Profile extends Partial<ProfileCandidate> {
  candidates?: ProfileCandidate[]
  preferOtherAgent?: boolean
  cost?: string
  description?: string
  /** A few words on when to start it, shown in every session's MCP instructions. */
  use?: string
  confirm?: boolean
}
export interface Config {
  agents: Record<string, AgentConfig>
  profiles: Record<string, Profile>
  collab: {
    startGuidance: string
    quotaSkip: number
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
    keys(a, ['title', 'executable', 'extraArgs', 'nativeSubagents', 'disallowedTools', 'historyTurns', 'defaultModel', 'models'], p)
    str(a.title, p + '.title'); str(a.executable, p + '.executable')
    if (!a.executable) fail(p + '.executable', 'nonempty string')
    if (a.extraArgs !== undefined) array(a.extraArgs, p + '.extraArgs')
    if (a.disallowedTools !== undefined) array(a.disallowedTools, p + '.disallowedTools')
    if (a.nativeSubagents !== undefined) bool(a.nativeSubagents, p + '.nativeSubagents')
    if (a.historyTurns !== undefined) num(a.historyTurns, p + '.historyTurns', 1)
    if (a.defaultModel !== undefined) {
      str(a.defaultModel, p + '.defaultModel')
      if (!a.defaultModel) fail(p + '.defaultModel', 'nonempty string')
    }
    if (a.models !== undefined) {
      keys(a.models, ['include', 'exclude'], p + '.models')
      for (const key of ['include', 'exclude']) {
        array(a.models[key], p + '.models.' + key)
        for (const pattern of a.models[key]) {
          try { new RegExp(pattern, 'i') }
          catch { fail(p + '.models.' + key, 'valid regular expressions') }
        }
      }
    }
  }
  for (const [name, a] of Object.entries(obj(c.profiles, 'profiles'))) {
    const p = `profiles.${name}`
    keys(a, ['agent', 'model', 'effort', 'mode', 'cost', 'description', 'use', 'confirm', 'preferOtherAgent', 'candidates'], p)
    const candidate = (v: any, path: string) => {
      obj(v, path)
      str(v.agent, path + '.agent')
      if (!c.agents[v.agent]) fail(path + '.agent', 'configured agent')
      for (const k of ['model', 'effort', 'mode']) if (v[k] != null) str(v[k], path + '.' + k)
      if (v.mode != null && !['plan', 'ask', 'edits', 'auto', 'full'].includes(v.mode)) fail(path + '.mode', 'permission mode')
    }
    if (a.candidates !== undefined) {
      if (!Array.isArray(a.candidates) || !a.candidates.length) fail(p + '.candidates', 'nonempty candidate array')
      a.candidates.forEach((v: any, i: number) => {
        const path = `${p}.candidates.${i}`
        keys(v, ['agent', 'model', 'effort', 'mode'], path)
        candidate(v, path)
      })
    }
    // Legacy overrides can inherit candidates through the recursive config merge.
    if (a.candidates === undefined || ['agent', 'model', 'mode', 'effort'].some((k) => a[k] !== undefined)) candidate(a, p)
    for (const k of ['cost', 'description', 'use']) if (a[k] != null) str(a[k], p + '.' + k)
    if (a.preferOtherAgent !== undefined) bool(a.preferOtherAgent, p + '.preferOtherAgent')
    if (a.cost !== undefined && !['minimal', 'low', 'medium', 'high', 'premium'].includes(a.cost)) fail(p + '.cost', 'cost tier')
    if (a.confirm !== undefined) bool(a.confirm, p + '.confirm')
  }
  const collab = obj(c.collab, 'collab')
  keys(collab, ['startGuidance', 'quotaSkip', 'maxActive', 'handoffLimit', 'closeFinished', 'confirm', 'textLimit', 'replyLimit', 'confirmTimeout', 'handleTimeout', 'handleCommand', 'agentHandleCommands', 'tools', 'prompts'], 'collab')
  str(collab.startGuidance, 'collab.startGuidance')
  if (typeof collab.quotaSkip !== 'number' || !Number.isFinite(collab.quotaSkip)
    || collab.quotaSkip < 0 || collab.quotaSkip > 1) fail('collab.quotaSkip', 'number 0..1')
  for (const k of ['maxActive', 'handoffLimit', 'textLimit', 'replyLimit', 'confirmTimeout', 'handleTimeout']) num(collab[k], 'collab.' + k, 1)
  for (const k of ['closeFinished', 'confirm']) bool(collab[k], 'collab.' + k)
  array(collab.handleCommand, 'collab.handleCommand')
  for (const [k, v] of Object.entries(obj(collab.agentHandleCommands, 'collab.agentHandleCommands'))) array(v, 'collab.agentHandleCommands.' + k)
  for (const [k, v] of Object.entries(obj(collab.prompts, 'collab.prompts'))) str(v, 'collab.prompts.' + k)
  for (const k of ['handoff', 'forkNote', 'taskNote', 'messageNote', 'mailbox', 'reply', 'failedReply', 'replyError', 'partialReply', 'childFollowup', 'followup', 'started', 'candidateSkipped', 'candidatesSkipped', 'candidateUnavailable', 'candidateModelExcluded', 'candidateQuotaUsed', 'candidateQuotaLimited', 'candidateBalanceExhausted', 'candidateSameAgent', 'noCandidate', 'sent', 'mention', 'profileHeader', 'forkAgents', 'delegation', 'startSummary', 'handlePrompt', 'task']) str(collab.prompts[k], 'collab.prompts.' + k)
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
  #base?: Config
  readonly baseFile?: string
  readonly host: boolean
  #watched: string[] = []
  #timer?: NodeJS.Timeout
  constructor(varDir: string, defaults = join(emxRoot, 'config.json'), hostOverride?: string) {
    this.defaults = defaults
    this.host = hostOverride !== undefined
    this.override = hostOverride ?? join(stateDir(varDir), 'config.json')
    if (this.host) {
      this.baseFile = join(stateDir(varDir), 'client-config.json')
      try { this.#base = validate(JSON.parse(readFileSync(this.baseFile, 'utf8'))) }
      catch { /* First connection supplies the effective local config. */ }
    }
    this.value = validate(JSON.parse(readFileSync(defaults, 'utf8')))
    this.reload()
  }
  reload(): { config: Config, errors: string[], changed: boolean } {
    let changed = false
    try {
      const base = this.#base ?? JSON.parse(readFileSync(this.defaults, 'utf8'))
      let override = {}
      try { override = JSON.parse(readFileSync(this.override, 'utf8')) }
      catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e }
      if (!object(override)) throw new Error(`${this.override}: expected object`)
      if (this.host) {
        if (Object.keys(override).some((k) => k !== 'agents') || (override.agents !== undefined && !object(override.agents))) {
          throw new Error('Host config may only override agents.<name>.executable')
        }
        for (const [name, agent] of Object.entries(override.agents ?? {})) {
          if (!object(agent) || Object.keys(agent).some((k) => k !== 'executable') || !base.agents[name]) {
            throw new Error('Host config may only override configured agents executables')
          }
        }
      }
      const next = validate(merge(base, override))
      changed = JSON.stringify(next) !== JSON.stringify(this.value)
      this.value = next
      this.errors = []
    } catch (error) { this.errors = [String(error)] }
    return { config: this.value, errors: this.errors, changed }
  }
  push(value: unknown): ReturnType<Configuration['reload']> {
    if (!this.baseFile) throw new Error('Only host daemons accept config/push')
    const base = validate(structuredClone(value))
    mkdirSync(dirname(this.baseFile), { recursive: true, mode: 0o700 })
    writeFileSync(this.baseFile + '.tmp', JSON.stringify(base), { mode: 0o600 })
    renameSync(this.baseFile + '.tmp', this.baseFile)
    this.#base = base
    return this.reload()
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
