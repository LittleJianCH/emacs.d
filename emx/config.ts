// config.ts --- validated configuration, last-good reloads and directory watches.
import { readFileSync, watchFile, unwatchFile, mkdirSync, writeFileSync, renameSync, rmSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
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
  quotaSkip?: number
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
/** A legacy override takes precedence over an inherited candidates array. */
export function profileCandidates(p: Profile): ProfileCandidate[] {
  return p.agent ? [{ agent: p.agent, model: p.model, mode: p.mode, effort: p.effort }] : p.candidates!
}
/** Split only the first colon and the first following slash; models are opaque. */
function disabledEntry(entry: string): { profile: string, agent?: string, model?: string } {
  const colon = entry.indexOf(':')
  if (colon < 0) return { profile: entry }
  const slash = entry.indexOf('/', colon + 1)
  return { profile: entry.slice(0, colon),
    agent: entry.slice(colon + 1, slash < 0 ? undefined : slash),
    ...(slash < 0 ? {} : { model: entry.slice(slash + 1) }) }
}
export function candidateDisabledBy(c: Config, name: string, candidate: ProfileCandidate): string[] {
  return c.collab.disabled.filter((entry) => {
    const { profile, agent, model } = disabledEntry(entry)
    return profile === name && (agent === undefined || (agent === candidate.agent
      && (model === undefined || model === (candidate.model ?? ''))))
  })
}
function candidateEntry(name: string, candidate: ProfileCandidate): string {
  return `${name}:${candidate.agent}/${candidate.model ?? ''}`
}
export interface Config {
  agents: Record<string, AgentConfig>
  profiles: Record<string, Profile>
  collab: {
    startGuidance: string
    quotaSkip: number
    disabled: string[]
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
/** Keep one candidate form so effective config can also be pushed to hosts. */
function mergeConfiguration(base: any, override: any): any {
  const result = merge(base, override)
  if (object(override?.profiles)) for (const [name, profile] of Object.entries(override.profiles)) {
    if (object(profile) && Object.hasOwn(profile, 'candidates')) {
      for (const key of ['agent', 'model', 'effort', 'mode']) delete result.profiles[name][key]
    } else if (object(profile) && Object.hasOwn(profile, 'agent')) {
      delete result.profiles[name].candidates
    }
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
  const threshold = (v: any, p: string) => {
    if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) fail(p, 'number 0..1')
  }
  const keys = (v: any, allowed: string[], p: string) => {
    obj(v, p)
    for (const key of Object.keys(v)) if (!allowed.includes(key)) throw new Error(`config.${p ? p + '.' : ''}${key}: unknown key`)
  }
  const c = obj(value, '')
  keys(c, ['agents', 'profiles', 'collab', 'usage', 'daemon', 'sessions'], '')
  for (const [name, a] of Object.entries(obj(c.agents, 'agents'))) {
    const p = `agents.${name}`
    if (!name || name.includes('/')) fail(p, 'nonempty agent name without /')
    keys(a, ['title', 'executable', 'extraArgs', 'nativeSubagents', 'disallowedTools', 'historyTurns', 'defaultModel', 'quotaSkip', 'models'], p)
    str(a.title, p + '.title'); str(a.executable, p + '.executable')
    if (!a.executable) fail(p + '.executable', 'nonempty string')
    if (a.extraArgs !== undefined) array(a.extraArgs, p + '.extraArgs')
    if (a.disallowedTools !== undefined) array(a.disallowedTools, p + '.disallowedTools')
    if (a.nativeSubagents !== undefined) bool(a.nativeSubagents, p + '.nativeSubagents')
    if (a.historyTurns !== undefined) num(a.historyTurns, p + '.historyTurns', 1)
    if (a.quotaSkip !== undefined) threshold(a.quotaSkip, p + '.quotaSkip')
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
    if (!name || name.includes(':')) fail(p, 'nonempty profile name without :')
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
  keys(collab, ['startGuidance', 'quotaSkip', 'disabled', 'maxActive', 'handoffLimit', 'closeFinished', 'confirm', 'textLimit', 'replyLimit', 'confirmTimeout', 'handleTimeout', 'handleCommand', 'agentHandleCommands', 'tools', 'prompts'], 'collab')
  str(collab.startGuidance, 'collab.startGuidance')
  threshold(collab.quotaSkip, 'collab.quotaSkip')
  array(collab.disabled, 'collab.disabled')
  for (const entry of collab.disabled) {
    const { profile, agent } = disabledEntry(entry)
    if (!profile || agent === '') {
      fail('collab.disabled', 'profile, profile:agent or profile:agent/model (empty model means default)')
    }
  }
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
  overriddenProfiles: string[] = []
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
      try { this.#base = this.#complete(JSON.parse(readFileSync(this.baseFile, 'utf8'))) }
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
      const next = validate(mergeConfiguration(base, override))
      changed = JSON.stringify(next) !== JSON.stringify(this.value)
      this.value = next
      this.overriddenProfiles = Object.keys(override.profiles ?? {})
      this.errors = []
    } catch (error) { this.errors = [String(error)] }
    return { config: this.value, errors: this.errors, changed }
  }
  /** Edit only the user overlay, validating before atomic publication. */
  set(path: unknown, value: unknown): ReturnType<Configuration['reload']> {
    return this.#edit(path, () => value)
  }
  /** Mutate the current policy synchronously, never a client's cached array. */
  disable(profile: unknown, candidate: unknown, disabled: unknown): ReturnType<Configuration['reload']> {
    if (typeof profile !== 'string' || !profile) throw new Error('collab/disable profile: expected nonempty string')
    if (typeof disabled !== 'boolean') throw new Error('collab/disable disabled: expected boolean')
    if (candidate !== undefined && (!Number.isSafeInteger(candidate) || (candidate as number) < 0)) {
      throw new Error('collab/disable candidate: expected nonnegative integer')
    }
    return this.#edit(['collab', 'disabled'], (current) => {
      const c = validate(current())
      if (!Object.hasOwn(c.profiles, profile)) throw new Error(`Unknown profile: ${profile}`)
      let entries = [...c.collab.disabled]
      const add = (entry: string) => { if (!entries.includes(entry)) entries.push(entry) }
      if (candidate === undefined) {
        if (disabled) add(profile)
        else entries = entries.filter((entry) => entry !== profile)
      } else {
        const candidates = profileCandidates(c.profiles[profile]), selected = candidates[candidate as number]
        if (!selected) throw new Error('collab/disable candidate: index out of range')
        if (disabled) add(candidateEntry(profile, selected))
        else {
          const removed = candidateDisabledBy(c, profile, selected).filter((entry) => entry !== profile)
          entries = entries.filter((entry) => !removed.includes(entry))
          // Expand broad agent entries so enabling one model preserves siblings.
          const covered = { ...c, collab: { ...c.collab, disabled: removed } }
          for (const sibling of candidates) {
            if (candidateEntry(profile, sibling) !== candidateEntry(profile, selected)
              && candidateDisabledBy(covered, profile, sibling).length) add(candidateEntry(profile, sibling))
          }
        }
      }
      return entries
    })
  }
  /** Share the synchronous read/modify/validate/publish path with config/set. */
  #edit(path: unknown, change: (current: () => unknown) => unknown): ReturnType<Configuration['reload']> {
    if (this.host) throw new Error('config/set is only available on local daemons')
    if (!Array.isArray(path) || !path.length || !path.every((key) => typeof key === 'string' && key.length)) {
      throw new Error('config/set path: expected nonempty string[]')
    }
    for (const key of path) {
      if (['__proto__', 'prototype', 'constructor'].includes(key)) throw new Error(`Invalid config key: ${key}`)
    }
    let overlay: Record<string, any> = {}
    try { overlay = JSON.parse(readFileSync(this.override, 'utf8')) }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
    if (!object(overlay)) throw new Error(`${this.override}: expected object`)
    const base = JSON.parse(readFileSync(this.defaults, 'utf8'))
    const value = change(() => mergeConfiguration(base, overlay))
    if (value === undefined) throw new Error('config/set requires value (use null to delete)')
    const edit = (target: Record<string, any>, index: number): void => {
      const key = path[index]
      if (index === path.length - 1) {
        if (value === null) delete target[key]
        else target[key] = value
      } else {
        if (!object(target[key])) {
          if (value === null) return
          target[key] = {}
        }
        edit(target[key], index + 1)
        if (value === null && !Object.keys(target[key]).length) delete target[key]
      }
    }
    edit(overlay, 0)
    // Do not leave dormant legacy fields in an edited candidate override.
    if (path[0] === 'profiles' && path[2] === 'candidates' && value !== null) {
      for (const key of ['agent', 'model', 'effort', 'mode']) delete overlay.profiles[path[1]][key]
    }
    validate(mergeConfiguration(base, overlay))
    mkdirSync(dirname(this.override), { recursive: true, mode: 0o700 })
    const temp = this.override + '.' + randomUUID() + '.tmp'
    try {
      writeFileSync(temp, JSON.stringify(overlay, null, 2) + '\n', { mode: 0o600, flag: 'wx' })
      renameSync(temp, this.override)
    } finally { rmSync(temp, { force: true }) }
    return this.reload()
  }
  /** A client daemon older than this host lacks newer keys; take them from
   * this host's defaults, as a reload after the client's own upgrade would. */
  #complete(value: unknown): Config {
    return validate(mergeConfiguration(JSON.parse(readFileSync(this.defaults, 'utf8')), value))
  }
  push(value: unknown): ReturnType<Configuration['reload']> {
    if (!this.baseFile) throw new Error('Only host daemons accept config/push')
    const base = this.#complete(value)
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
