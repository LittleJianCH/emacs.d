// agy.ts --- Antigravity CLI (agy acp) peer over ACP JSON-RPC 2.0 stdio.

import { spawn } from 'node:child_process'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import { extname, isAbsolute, join, relative } from 'node:path'
import { createInterface } from 'node:readline'
import type { AgentConfig } from '../config.ts'
import { checkoutRoot } from '../daemon/paths.ts'
import type { Backend, SessionHost } from './backend.ts'
import { diff } from './dsh.ts'
import type { Capabilities, ChoiceId, Settings, ToolKind, ToolStatus, ToolView } from '../daemon/protocol.ts'

const effortOrder = ['low', 'medium', 'high', 'xhigh', 'max'] as const

export const modes: Record<string, string> = {
  ask: 'default',
  edits: 'accept-edits',
  auto: 'auto',
  plan: 'plan',
}

const fromAcpMode: Record<string, string> = Object.fromEntries(
  Object.entries(modes).map(([emxMode, acpMode]) => [acpMode, emxMode]),
)

const mimeTypes: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
}

/** Include/exclude regexes from the configured identity; absent means all. */
export function allowedModel(id: string, config?: Pick<AgentConfig, 'models'>): boolean {
  const filter = config?.models
  return !filter || (filter.include.some((s) => new RegExp(s, 'i').test(id))
    && !filter.exclude.some((s) => new RegExp(s, 'i').test(id)))
}

/** Instructions appended via ACP _meta.antigravity.systemPrompt.append. */
export function systemPromptAppend(tools?: string[]): string {
  return "This session is hosted by the user's Emacs; the conversation UI is an Emacs buffer.\n"
    + (tools === undefined || tools.includes('context')
      ? 'Unless the user explicitly refers to another application, references to the current page, window, editor, or input box mean Emacs; first discover and call the emacs MCP context tool.\n'
      : 'Unless the user explicitly refers to another application, references to the current page, window, editor, or input box mean Emacs. Use only the available editor tools.\n')
    + 'Use the emacs MCP tools to inspect and operate that UI.'
}

export function launchArgs(config?: Partial<AgentConfig>): string[] {
  return ['acp', ...(config?.extraArgs ?? [])]
}

function unsupported(error: unknown): boolean {
  const value = error as { code?: unknown, message?: unknown }
  return value?.code === -32601
    || typeof value?.message === 'string' && /unknown method|not supported|not found/i.test(value.message)
}

function configOption(options: any[] | undefined, id: string): any | undefined {
  return Array.isArray(options) ? options.find((opt) => opt?.id === id || opt?.category === id) : undefined
}

/** Extract model choices and per-model effort levels from ACP session results or updates. */
export function parseCapabilities(
  source: { models?: any, modes?: any, configOptions?: any[] },
  config?: Pick<AgentConfig, 'models'>,
  commands: Capabilities['commands'] = [],
): Capabilities {
  const availableVariants: any[] = Array.isArray(source.models?.availableModels) ? source.models.availableModels : []
  const modelOpt = configOption(source.configOptions, 'model')
  const thoughtOpt = configOption(source.configOptions, 'thought_level')
  const modeOpt = configOption(source.configOptions, 'mode')

  let models: Capabilities['models']
  if (Array.isArray(modelOpt?.options) && modelOpt.options.length) {
    models = modelOpt.options
      .filter((opt: any) => typeof opt?.value === 'string' && allowedModel(opt.value, config))
      .map((opt: any) => {
        const id: string = opt.value
        const matchedEfforts = new Set<string>()
        for (const variant of availableVariants) {
          const vid = typeof variant?.modelId === 'string' ? variant.modelId : ''
          if (!vid.startsWith(id + '-')) continue
          const suffix = vid.slice(id.length + 1)
          if ((effortOrder as readonly string[]).includes(suffix)) matchedEfforts.add(suffix)
        }
        if (!matchedEfforts.size && modelOpt.currentValue === id && Array.isArray(thoughtOpt?.options)) {
          for (const e of thoughtOpt.options) if (typeof e?.value === 'string') matchedEfforts.add(e.value)
        }
        const efforts = effortOrder.filter((level) => matchedEfforts.has(level))
        return {
          id,
          name: typeof opt.name === 'string' ? opt.name : id,
          ...(typeof opt.description === 'string' ? { description: opt.description } : {}),
          ...(efforts.length ? { efforts } : {}),
        }
      })
  } else {
    models = availableVariants
      .filter((m: any) => typeof m?.modelId === 'string' && allowedModel(m.modelId, config))
      .map((m: any) => ({
        id: m.modelId,
        name: typeof m.name === 'string' ? m.name : m.modelId,
        ...(typeof m.description === 'string' ? { description: m.description } : {}),
      }))
  }

  const rawModes: string[] = Array.isArray(modeOpt?.options) && modeOpt.options.length
    ? modeOpt.options.map((opt: any) => String(opt.value))
    : Array.isArray(source.modes?.availableModes) && source.modes.availableModes.length
      ? source.modes.availableModes.map((m: any) => String(m.id))
      : Object.values(modes)
  const parsedModes = [...new Set(rawModes.map((m) => fromAcpMode[m]).filter((m): m is string => !!m))]

  return {
    models,
    modes: parsedModes.length ? parsedModes : Object.keys(modes),
    commands,
  }
}

function relativePath(root: string, value: unknown): string | undefined {
  if (typeof value !== 'string' || !value) return undefined
  return isAbsolute(value) ? relative(root, value) : value
}

function emacsMcpToolName(name: string): string | undefined {
  if (name.startsWith('mcp__emacs__')) return name.slice('mcp__emacs__'.length)
  if (name.startsWith('mcp_emacs_')) return name.slice('mcp_emacs_'.length)
  if (name.startsWith('emacs:')) return name.slice('emacs:'.length)
  return undefined
}

function mapToolKind(acpKind: unknown, name: string): ToolKind {
  if (name.startsWith('mcp__') || name.startsWith('mcp_') || name.startsWith('emacs:')) return 'mcp'
  switch (acpKind) {
    case 'execute': return 'command'
    case 'read': return 'read'
    case 'edit': case 'delete': case 'move': return 'edit'
    case 'search': return 'search'
    case 'fetch': return 'web'
    case 'switch_mode': return 'plan'
    default: return 'other'
  }
}

/** Normalize an ACP tool_call / tool_call_update payload into an emx ToolView. */
export function toolView(root: string, call: any, existing?: ToolView): ToolView {
  const rawInput = (call?.rawInput && typeof call.rawInput === 'object' ? call.rawInput
    : call?.args && typeof call.args === 'object' ? call.args : {}) as Record<string, any>
  const name = typeof call?.name === 'string' && call.name ? call.name : existing?.name ?? String(call?.kind ?? 'tool')
  const kind = call?.kind !== undefined || call?.name !== undefined
    ? mapToolKind(call?.kind, name)
    : existing?.kind ?? 'other'
  const locationPath = Array.isArray(call?.locations) ? call.locations[0]?.path : undefined
  const path = relativePath(root, locationPath ?? rawInput.Path ?? rawInput.path
    ?? rawInput.TargetFile ?? rawInput.file_path ?? rawInput.AbsolutePath) ?? existing?.path
  const command = typeof rawInput.CommandLine === 'string' ? rawInput.CommandLine
    : typeof rawInput.command === 'string' ? rawInput.command : existing?.command

  let editDiff = existing?.diff
  if (Array.isArray(call?.content)) {
    const diffs = call.content
      .filter((item: any) => item?.type === 'diff')
      .map((item: any) => diff(relativePath(root, item.path) ?? path ?? '', item.oldText, item.newText))
    if (diffs.length) editDiff = diffs.join('\n')
  }
  if (!editDiff && kind === 'edit' && path) {
    if (typeof rawInput.Target === 'string' || typeof rawInput.Replacement === 'string') {
      editDiff = diff(path, rawInput.Target, rawInput.Replacement)
    } else if (typeof rawInput.Content === 'string') {
      editDiff = diff(path, undefined, rawInput.Content)
    }
  }

  let title = typeof call?.title === 'string' && call.title ? call.title : existing?.title ?? ''
  if (!title) {
    if (kind === 'command' && command) title = command.trim().split('\n')[0]
    else if (kind === 'mcp') title = name.replace(/^mcp__/, '').replace(/__/g, ' · ')
    else title = path ?? name
  }

  return {
    kind,
    name,
    title,
    ...(command !== undefined ? { command } : {}),
    ...(path !== undefined ? { path } : {}),
    ...(editDiff !== undefined ? { diff: editDiff } : {}),
  }
}

export function toolOutput(call: any): string | undefined {
  if (Array.isArray(call?.content)) {
    const parts: string[] = []
    for (const item of call.content) {
      if (item?.type === 'content' && item.content?.type === 'text' && typeof item.content.text === 'string') {
        parts.push(item.content.text)
      } else if (item?.type === 'text' && typeof item.text === 'string') {
        parts.push(item.text)
      }
    }
    if (parts.length) return parts.join('\n')
  }
  const raw = call?.rawOutput
  if (typeof raw === 'string') return raw
  if (raw && typeof raw === 'object') {
    if (typeof raw.output === 'string') return raw.output
    if (typeof raw.stdout === 'string') return raw.stdout
    if (typeof raw.error === 'string') return raw.error
  }
  return undefined
}

function mapToolStatus(status: unknown): ToolStatus {
  switch (status) {
    case 'completed': return 'done'
    case 'failed': case 'error': return 'error'
    case 'declined': case 'cancelled': return 'declined'
    default: return 'running'
  }
}

export class AgyBackend implements Backend {
  readonly host: SessionHost
  #process?: ChildProcessWithoutNullStreams
  #pending = new Map<number, { resolve: (value: any) => void, reject: (error: Error) => void, timer?: NodeJS.Timeout }>()
  #next = 0
  #resume?: string
  #running = false
  #stopping = false
  #replay: 'none' | 'render' | 'skip' = 'none'
  #replayUserId?: string
  #activeText?: { id: string, kind: 'assistant' | 'thinking' }
  #commands: Capabilities['commands'] = []
  #lastConfigSource: { models?: any, modes?: any, configOptions?: any[] } = {}
  #currentModel?: string
  #currentEffort?: string
  #currentMode?: string
  #planId?: string

  constructor(host: SessionHost) { this.host = host }

  #title(): string { return this.host.agentConfig?.()?.title || 'Antigravity' }

  #executable(): string {
    const config = this.host.agentConfig?.()
    return process.env[`EMX_${this.host.agent.toUpperCase()}_EXECUTABLE`]
      ?? config?.executable ?? 'agy'
  }

  #write(message: object): void {
    if (this.#process?.stdin.writable) {
      this.#process.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
    }
  }

  #request(method: string, params: unknown = {}, timeoutMs = 120_000): Promise<any> {
    const id = ++this.#next
    return new Promise((resolve, reject) => {
      if (!this.alive()) { reject(new Error(`${this.#title()} is not running`)); return }
      const timer = timeoutMs > 0 ? setTimeout(() => {
        this.#pending.delete(id)
        reject(new Error(`${this.#title()} request timed out: ${method}`))
      }, timeoutMs) : undefined
      this.#pending.set(id, { resolve, reject, timer })
      this.#write({ id, method, params })
    })
  }

  #notice(kind: string, message?: string): void {
    this.host.addBlock({
      id: this.host.newId('notice'),
      type: 'notice',
      notice: { kind, ...(message === undefined ? {} : { args: { message }, level: 'error' }) },
    })
  }

  #closeText(): void {
    if (this.#activeText) {
      this.host.update(this.#activeText.id, { done: true })
      this.#activeText = undefined
    }
    this.#replayUserId = undefined
  }

  #appendText(kind: 'assistant' | 'thinking', delta: string): void {
    if (!delta) return
    this.#replayUserId = undefined
    if (this.#activeText && this.#activeText.kind !== kind) {
      this.host.update(this.#activeText.id, { done: true })
      this.#activeText = undefined
    }
    if (!this.#activeText) {
      const id = this.host.newId(kind)
      this.#activeText = { id, kind }
      this.host.addBlock({ id, type: 'text', kind, text: '', done: false })
    }
    this.host.append(this.#activeText.id, delta)
  }

  #emitCapabilities(source?: { models?: any, modes?: any, configOptions?: any[] }): void {
    if (source) {
      this.#lastConfigSource = {
        models: source.models ?? this.#lastConfigSource.models,
        modes: source.modes ?? this.#lastConfigSource.modes,
        configOptions: source.configOptions ?? this.#lastConfigSource.configOptions,
      }
    }
    const modelOpt = configOption(this.#lastConfigSource.configOptions, 'model')
    const thoughtOpt = configOption(this.#lastConfigSource.configOptions, 'thought_level')
    const modeOpt = configOption(this.#lastConfigSource.configOptions, 'mode')
    if (typeof modelOpt?.currentValue === 'string') this.#currentModel = modelOpt.currentValue
    else if (typeof this.#lastConfigSource.models?.currentModelId === 'string' && !this.#currentModel) {
      this.#currentModel = this.#lastConfigSource.models.currentModelId
    }
    if (typeof thoughtOpt?.currentValue === 'string') this.#currentEffort = thoughtOpt.currentValue
    if (typeof modeOpt?.currentValue === 'string') this.#currentMode = modeOpt.currentValue
    else if (typeof this.#lastConfigSource.modes?.currentModeId === 'string') {
      this.#currentMode = this.#lastConfigSource.modes.currentModeId
    }
    this.host.emit({
      type: 'capabilities',
      capabilities: parseCapabilities(this.#lastConfigSource, this.host.agentConfig?.(), this.#commands),
    })
  }

  #mcpServers(): object[] {
    return [{
      name: 'emacs',
      command: process.execPath,
      args: [join(checkoutRoot, 'bin/emx'), 'mcp'],
      env: [
        { name: 'EMX_DAEMON_SOCKET', value: this.host.daemonSocket },
        { name: 'EMX_SESSION', value: this.host.id },
      ],
    }]
  }

  async start(resume?: string): Promise<void> {
    if (!isAbsolute(this.host.root) || /^\/[^/]+:/.test(this.host.root)) {
      throw new Error(`${this.#title()} daemon sessions require a local absolute root; remote projects are not supported`)
    }
    this.#stopping = false
    this.#running = false
    this.#activeText = undefined
    this.#replayUserId = undefined
    this.#planId = undefined
    this.#lastConfigSource = {}
    const env = await this.host.environment?.()
    const config = this.host.agentConfig?.()
    const child = spawn(this.#executable(), launchArgs(config), { cwd: this.host.root, env, stdio: 'pipe' })
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
      if (this.#running) {
        this.#closeText()
        this.host.emit({ type: 'usage/end' })
      }
      this.#running = false
      for (const pending of this.#pending.values()) {
        if (pending.timer) clearTimeout(pending.timer)
        pending.reject(error ?? new Error(`${this.#title()} ACP server exited`))
      }
      this.#pending.clear()
      if (!this.#stopping) {
        this.#notice('backend-error', error?.message ?? `${this.#title()} exited (${child.exitCode ?? child.signalCode})`)
        this.host.setStatus('exited')
      }
    }
    child.once('error', ended)
    child.once('close', () => ended())

    const init = await this.#request('initialize', {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: 'emacs', title: 'Emacs', version: 'emx' },
    })

    const mcpServers = this.#mcpServers()
    const supportsAppend = !!init?.agentCapabilities?._meta?.antigravity?.systemPrompt?.append
    const meta = supportsAppend
      ? { _meta: { antigravity: { systemPrompt: { append: systemPromptAppend(this.host.editorTools().tools.map((t) => t.name)) } } } }
      : {}

    let sessionResult: any
    if (resume) {
      const hasBlocks = this.host.blocks.length > 0
      if (hasBlocks && init?.agentCapabilities?.sessionCapabilities?.resume !== undefined) {
        try {
          sessionResult = await this.#request('session/resume', { sessionId: resume, cwd: this.host.root, mcpServers, ...meta })
        } catch (error) {
          if (!unsupported(error)) throw error
        }
      }
      if (!sessionResult) {
        this.#replay = hasBlocks ? 'skip' : 'render'
        try {
          sessionResult = await this.#request('session/load', { sessionId: resume, cwd: this.host.root, mcpServers, ...meta })
        } finally {
          const rendered = this.#replay === 'render'
          this.#replay = 'none'
          this.#closeText()
          if (rendered) this.#notice('history-end')
        }
      }
      this.#resume = sessionResult.sessionId ?? resume
    } else {
      sessionResult = await this.#request('session/new', { cwd: this.host.root, mcpServers, ...meta })
      this.#resume = sessionResult.sessionId
    }

    this.#emitCapabilities(sessionResult)
    await this.configure(this.host.settings)
    this.host.setInfo({
      sessionId: this.#resume,
      ...(this.#currentModel ? { model: this.#currentModel } : {}),
    })
    this.host.setStatus('idle')
  }

  async configure(settings: Settings): Promise<void> {
    if (!this.alive() || !this.#resume) return
    if (settings.model && settings.model !== this.#currentModel) {
      const res = await this.#request('session/set_config_option', {
        sessionId: this.#resume, configId: 'model', value: settings.model,
      })
      this.#currentModel = settings.model
      if (res?.configOptions) this.#emitCapabilities(res)
      this.host.setInfo({ model: this.#currentModel })
    }
    if (settings.effort && settings.effort !== this.#currentEffort) {
      const res = await this.#request('session/set_config_option', {
        sessionId: this.#resume, configId: 'thought_level', value: settings.effort,
      })
      this.#currentEffort = settings.effort
      if (res?.configOptions) this.#emitCapabilities(res)
    }
    const desiredMode = settings.mode ? modes[settings.mode] : undefined
    if (desiredMode && desiredMode !== this.#currentMode) {
      const res = await this.#request('session/set_config_option', {
        sessionId: this.#resume, configId: 'mode', value: desiredMode,
      })
      this.#currentMode = desiredMode
      if (res?.configOptions) this.#emitCapabilities(res)
    }
  }

  async send(text: string, images?: string[], block?: string): Promise<void> {
    const id = block ?? this.host.newId('user')
    this.host.addBlock({ id, type: 'user', text, images })
    const prompt: object[] = []
    if (text) prompt.push({ type: 'text', text })
    for (const path of images ?? []) {
      const data = (await readFile(path)).toString('base64')
      const mimeType = mimeTypes[extname(path).toLowerCase()] ?? 'image/png'
      prompt.push({ type: 'image', data, mimeType })
    }
    this.#running = true
    this.#planId = undefined
    this.host.setStatus('running')
    const turn = this.#request('session/prompt', { sessionId: this.#resume, prompt }, 0)
    void turn.then((result) => {
      this.#closeText()
      this.#running = false
      const usage = result?.usage
      if (usage && typeof usage === 'object') {
        const input = Math.max(0, Number(usage.inputTokens ?? 0))
        const cacheRead = Math.max(0, Number(usage.cachedReadTokens ?? 0))
        const cacheWrite = Math.max(0, Number(usage.cachedWriteTokens ?? 0))
        const output = Math.max(0, Number(usage.outputTokens ?? 0) + Number(usage.thoughtTokens ?? 0))
        if (input || cacheRead || cacheWrite || output) {
          this.host.emit({
            type: 'usage/call',
            model: String(this.host.info.model ?? this.#currentModel ?? 'agy'),
            usage: { input, cacheRead, cacheWrite, output },
          })
        }
      }
      this.host.emit({ type: 'usage/end' })
      if (result?.stopReason === 'cancelled') this.#notice('interrupted')
      else if (result?.stopReason === 'max_tokens') this.#notice('max-tokens')
      this.host.setStatus('idle')
    }).catch((error) => {
      this.#closeText()
      const wasRunning = this.#running
      this.#running = false
      if (wasRunning) this.host.emit({ type: 'usage/end' })
      if (!this.#stopping && this.alive()) {
        this.#notice('backend-error', (error as Error).message)
        this.host.setStatus('idle')
      }
    })
  }

  steer(): boolean { return false }

  interrupt(): void {
    if (!this.alive() || !this.#resume) return
    this.#write({ method: 'session/cancel', params: { sessionId: this.#resume } })
  }

  #message(message: any): void {
    if (!message.method) {
      const pending = this.#pending.get(message.id)
      if (!pending) return
      this.#pending.delete(message.id)
      if (pending.timer) clearTimeout(pending.timer)
      if (message.error) {
        const error = new Error(message.error.message ?? `${this.#title()} request failed`)
        if (message.error.code !== undefined) Object.assign(error, { code: message.error.code })
        pending.reject(error)
      } else pending.resolve(message.result)
      return
    }
    const p = message.params ?? {}
    if (message.id !== undefined) {
      void this.#ask(message.id, message.method, p)
      return
    }
    if (message.method !== 'session/update') return
    if (p.sessionId && this.#resume && p.sessionId !== this.#resume) return
    const update = p.update
    if (!update || typeof update !== 'object') return

    switch (update.sessionUpdate) {
      case 'user_message_chunk': {
        if (this.#replay !== 'render') break
        this.#activeText && this.#closeText()
        const text = update.content?.type === 'text' && typeof update.content.text === 'string' ? update.content.text : ''
        const imageCount = update.content?.type === 'image' ? 1 : 0
        if (!this.#replayUserId) {
          this.#replayUserId = this.host.newId('user')
          this.host.addBlock({ id: this.#replayUserId, type: 'user', text, ...(imageCount ? { imageCount } : {}) })
        } else {
          const existing = this.host.blocks.find((b) => b.id === this.#replayUserId)
          if (existing?.type === 'user') {
            this.host.update(this.#replayUserId, {
              text: existing.text + text,
              ...(imageCount ? { imageCount: (existing.imageCount ?? 0) + imageCount } : {}),
            })
          }
        }
        break
      }
      case 'agent_message_chunk': {
        if (this.#replay === 'skip') break
        if (update.content?.type === 'text' && typeof update.content.text === 'string') {
          this.#appendText('assistant', update.content.text)
        }
        break
      }
      case 'agent_thought_chunk': {
        if (this.#replay === 'skip') break
        if (update.content?.type === 'text' && typeof update.content.text === 'string') {
          this.#appendText('thinking', update.content.text)
        }
        break
      }
      case 'tool_call':
      case 'tool_call_update': {
        if (this.#replay === 'skip') break
        this.#closeText()
        const id = String(update.toolCallId ?? this.host.newId('tool'))
        const existing = this.host.blocks.find((b) => b.id === id)
        const view = toolView(this.host.root, update, existing?.type === 'tool' ? existing.view : undefined)
        const output = toolOutput(update)
        const status = mapToolStatus(update.status)
        const fields = { view, status, ...(output !== undefined ? { output } : {}) }
        if (existing) this.host.update(id, fields)
        else this.host.addBlock({ id, type: 'tool', ...fields })
        break
      }
      case 'plan': {
        if (this.#replay === 'skip') break
        this.#closeText()
        const id = this.#planId ??= this.host.newId('plan')
        const entries = Array.isArray(update.entries) ? update.entries : []
        const view: ToolView = {
          kind: 'plan',
          name: 'plan',
          title: '',
          items: entries.map((e: any) => ({
            text: String(e?.content ?? ''),
            status: e?.status === 'completed' ? 'done' : e?.status === 'in_progress' ? 'active' : 'pending',
          })),
        }
        if (this.host.blocks.some((b) => b.id === id)) this.host.update(id, { view, status: 'done' })
        else this.host.addBlock({ id, type: 'tool', view, status: 'done' })
        break
      }
      case 'available_commands_update': {
        const list = Array.isArray(update.availableCommands) ? update.availableCommands : []
        this.#commands = list
          .filter((c: any) => typeof c?.name === 'string')
          .map((c: any) => ({
            name: c.name,
            ...(typeof c.description === 'string' ? { description: c.description } : {}),
            ...(typeof c.input?.hint === 'string' ? { hint: c.input.hint } : {}),
          }))
        this.#emitCapabilities()
        break
      }
      case 'current_mode_update': {
        if (typeof update.currentModeId === 'string') this.#currentMode = update.currentModeId
        break
      }
      case 'config_option_update': {
        if (Array.isArray(update.configOptions)) {
          this.#emitCapabilities({ configOptions: update.configOptions })
          if (this.#currentModel) this.host.setInfo({ model: this.#currentModel })
        }
        break
      }
      case 'session_info_update': {
        if (typeof update.title === 'string' && update.title.trim() && !this.host.info.title) {
          this.host.setInfo({ title: update.title.trim() })
        }
        break
      }
      case 'usage_update': {
        if (typeof update.used === 'number') this.host.setInfo({ tokens: update.used })
        break
      }
    }
  }

  async #ask(id: string | number, method: string, params: any): Promise<void> {
    const child = this.#process
    if (method !== 'session/request_permission') {
      if (this.#process === child) {
        this.#write({ id, error: { code: -32601, message: `Unsupported ${this.#title()} request: ${method}` } })
      }
      return
    }
    const call = params?.toolCall ?? {}
    const options: { optionId: string, name?: string, kind?: string }[] = Array.isArray(params?.options) ? params.options : []
    const findOption = (...kinds: string[]) => options.find((o) => o.kind && kinds.includes(o.kind))

    const mcpTool = typeof call.name === 'string' ? emacsMcpToolName(call.name) : undefined
    if (mcpTool && this.host.editorTools().readOnly.includes(mcpTool)) {
      const allow = findOption('allow_once', 'allow_always') ?? options[0]
      if (this.#process === child) {
        this.#write({
          id,
          result: { outcome: allow ? { outcome: 'selected', optionId: allow.optionId } : { outcome: 'cancelled' } },
        })
      }
      return
    }

    const toolId = typeof call.toolCallId === 'string' ? call.toolCallId : undefined
    const block = toolId ? this.host.blocks.find((b) => b.id === toolId) : undefined
    const view = toolView(this.host.root, call, block?.type === 'tool' ? block.view : undefined)
    const choices: ChoiceId[] = []
    if (findOption('allow_once')) choices.push('allow')
    if (findOption('allow_always')) choices.push('always')
    if (findOption('reject_once', 'reject_always')) choices.push('deny')
    if (!choices.length) choices.push('allow', 'deny')

    const answer = await this.host.ask({
      type: 'approval',
      ...(toolId ? { tool: toolId } : {}),
      view,
      choices,
    })

    if (this.#process !== child) return
    let picked: { optionId: string } | undefined
    if (answer.choice === 'allow') picked = findOption('allow_once', 'allow_always')
    else if (answer.choice === 'always') picked = findOption('allow_always', 'allow_once')
    else if (answer.choice === 'deny') picked = findOption('reject_once', 'reject_always')
    this.#write({
      id,
      result: { outcome: picked ? { outcome: 'selected', optionId: picked.optionId } : { outcome: 'cancelled' } },
    })
  }

  async stop(): Promise<void> {
    this.#stopping = true
    const child = this.#process
    if (!child) return
    const closed = child.exitCode !== null || child.signalCode !== null
      ? Promise.resolve()
      : once(child, 'close').catch(() => {})
    if (this.#resume && this.alive()) {
      await this.#request('session/close', { sessionId: this.#resume }, 2000).catch(() => {})
    }
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM')
      const timer = setTimeout(() => child.kill('SIGKILL'), 1000)
      await closed
      clearTimeout(timer)
    } else {
      await closed
    }
  }

  alive(): boolean { return !!this.#process && this.#process.exitCode === null && !this.#process.killed }
  resumeId(): string | undefined { return this.#resume }
}
