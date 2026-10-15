// emacs-bridge.mjs --- dsh plugin that serves Emacs (agent-dsh.el) over stdio.
//
// Loaded into the shipped `sdk` profile by emacs.yml, which disables the SDK
// JSON-RPC server and mounts this plugin in its place:
//
//   dsh --profile sdk --patch lisp/agent/dsh/emacs.yml
//
// Wire format: newline-delimited JSON-RPC 2.0. One process drives one session.
//
// Requests (Emacs -> dsh):
//   initialize {cwd, resume?, model?, effort?, preset?, plan?, mcpServers?}
//                -> {sessionId, title, config, models, presets, plan, commands,
//                    history, warnings}
//   configure  {model?, effort?, preset?, plan?}         -> {config}
//   prompt     {text, images?}       -> {messageId} | {command: {kind, text?}, status}
//   steer      {text, images?}                           -> {messageId}
//   cancel     {}                                        -> {}
//   sessions/list {cwds}            -> {sessions: [{id, cwd, title, time}]}  (no initialize needed)
//
// images are absolute file paths. A prompt naming a dsh slash command runs
// the command instead of starting a turn. mcpServers are stdio servers
// [{name, command, args, env, timeoutMs?}] mounted for this agent only. commands is
// [{name, description, hint?}]. history (resumed sessions only) replays the
// transcript as a list of {method, params} in the notification vocabulary
// below, plus `user` {id, text, images}.
//
// A model is named "provider/model". config is {model, effort, preset, plan};
// models is [{id, name, description?, efforts: [{id, name}], defaultEffort?}];
// presets lists the permission presets that can be selected (read-only,
// workspace-write, danger-full-access, and auto when auto-review is loaded);
// plan says whether plan mode is available.
// A model, effort or preset that initialize cannot apply falls back to the
// default and is reported in warnings. configure calls apply in order; an
// omitted effort keeps the current one for the same model, null selects the
// model's default.
//
// Requests (dsh -> Emacs):
//   approval   {callId?, toolName, reason?}                -> {decision: allow|reject}
//   question   {callId?, questions: [{id, question, header?, detail?,
//               options?: [{label, description?}], multiSelect?, intent?}]}
//                                     -> {answers: [{id, selected: [label], custom?}]}
//
// Notifications (dsh -> Emacs):
//   status     {status: running|idle}
//   text       {id, kind: assistant|thinking, delta}      streamed block text
//   text/done  {id, text?}                                 block finished
//   discard    {ids}                                       abandoned attempt's blocks
//   tool       {id, name, arguments}                       tool call committed
//   tool/done  {id, isError, output}                       tool result
//   turn/end   {reason, error?}
//   usage      {usage}
//   config     {config}                                    settings changed by dsh
//   error      {message}

import { createRequire } from 'node:module'
import { realpathSync } from 'node:fs'
import { readFile, realpath } from 'node:fs/promises'
import { extname } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createInterface } from 'node:readline'

export const name = 'emacs-bridge'
export const inject = ['agents', 'sessions', 'sessionPersistence', 'llm', 'permissionPresets']

// Plugin files outside the dsh installation cannot import its packages by
// name, so resolve them from the running dsh binary.
const dshRequire = createRequire(realpathSync(process.argv[1]))
const { createUserMessage, ReasoningEffortId } = await import(dshRequire.resolve('@deepseek-ai/dsh-llm'))
const { installModelSelection } = await import(dshRequire.resolve('@deepseek-ai/dsh-agent'))
const McpClient = await import(dshRequire.resolve('@deepseek-ai/dsh-mcp-client'))

const IMAGE_TYPES = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
                      '.gif': 'image/gif', '.webp': 'image/webp' }

// Session events whose user/message is something the user typed.
const isTypedMessage = (message) => message?.source?.kind === 'user'

/** Plain text of a content block list. */
function contentText(content) {
  if (typeof content === 'string') return content
  return (content ?? []).map((block) => block.type === 'text' ? block.text : '').join('')
}

/** tool/done params for a tool/result event; NAMES maps call ids to tool names. */
function toolResult(data, names) {
  const id = data.message.toolCallId
  const output = data.error?.reason ?? contentText(data.message.content)
  // bash reports a failing command as a successful result ending in
  // "[exit code: N]".
  const exit = names.get(id) === 'bash' ? /\[exit code: (\d+)\]\s*$/.exec(output) : null
  names.delete(id)
  return {
    id,
    isError: data.message.isError === true || data.error !== undefined
      || (exit !== null && exit[1] !== '0'),
    output,
  }
}

/** Human-readable message of an unknown failure. */
function errorMessage(error) {
  if (error == null) return 'unknown error'
  if (typeof error === 'string') return error
  return error.message ?? JSON.stringify(error)
}

export function apply(ctx) {
  const logger = ctx.logger?.('emacs-bridge') ?? console
  let handle = null
  let nextId = 0
  const pending = new Map()
  // Model for the agent's next step; installModelSelection reads it.
  const selection = { current: undefined, assembled: undefined }
  let configuring = Promise.resolve()
  // attemptId -> Map(block index -> {id, kind, text})
  const attempts = new Map()

  const write = (message) => {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
  }
  const notify = (method, params) => write({ method, params })
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = `dsh-${++nextId}`
    pending.set(id, { resolve, reject })
    write({ id, method, params })
  })

  const owns = (agent) => handle !== null && agent === handle.agent
  const ownsSession = (session) => handle !== null && session === handle.agent.session

  // Live assistant output: forward deltas as they stream.
  ctx.on('agent/assistant-stream', ({ agent, frame }) => {
    if (!owns(agent)) return
    switch (frame.type) {
      case 'start':
        attempts.set(frame.attemptId, new Map())
        break
      case 'chunk': {
        const blocks = attempts.get(frame.attemptId)
        if (blocks === undefined) break
        const chunk = frame.chunk
        if (chunk.type === 'text-delta' || chunk.type === 'reasoning-delta') {
          let block = blocks.get(chunk.index)
          if (block === undefined) {
            block = {
              id: `${frame.attemptId}/${chunk.index}`,
              kind: chunk.type === 'text-delta' ? 'assistant' : 'thinking',
              text: '',
            }
            blocks.set(chunk.index, block)
          }
          block.text += chunk.text
          notify('text', { id: block.id, kind: block.kind, delta: chunk.text })
        } else if (chunk.type === 'block-end') {
          const block = blocks.get(chunk.index)
          if (block !== undefined && !block.done) {
            block.done = true
            notify('text/done', { id: block.id, text: block.text })
          }
        } else if (chunk.type === 'usage') {
          notify('usage', { usage: chunk.usage })
        }
        break
      }
      case 'end': {
        const blocks = attempts.get(frame.attemptId)
        attempts.delete(frame.attemptId)
        if (blocks === undefined) break
        if (frame.outcome.kind === 'abandoned') {
          notify('discard', { ids: [...blocks.values()].map((block) => block.id) })
        } else {
          for (const block of blocks.values()) {
            if (!block.done) notify('text/done', { id: block.id, text: block.text })
          }
        }
        break
      }
    }
  })

  // callId -> tool name, to interpret results.
  const toolNames = new Map()

  // Durable facts: tool calls, tool results, turn boundaries.
  ctx.on('session/event', (session, event) => {
    if (!ownsSession(session)) return
    const data = event.data ?? event
    switch (event.type) {
      case 'tool/call':
        toolNames.set(data.callId, data.name)
        notify('tool', { id: data.callId, name: data.name, arguments: data.arguments })
        break
      case 'tool/result':
        notify('tool/done', toolResult(data, toolNames))
        break
      case 'plan/mode':
        notify('config', { config: currentConfig() })
        break
      case 'turn/end': {
        const reason = data.reason ?? {}
        notify('turn/end', {
          reason: reason.kind,
          ...(reason.kind === 'error' ? { error: errorMessage(reason.error) } : {}),
        })
        break
      }
    }
  })

  ctx.on('agent/status', ({ agent, status }) => {
    if (owns(agent)) notify('status', { status })
  })

  ctx.on('agent/error', ({ agent, error }) => {
    if (owns(agent)) notify('error', { message: errorMessage(error) })
  })

  ctx.on('approval/request', (req, next) => {
    if (!owns(req.agent)) return next()
    return request('approval', { callId: req.callId, toolName: req.toolName, reason: req.reason })
      .then((result) => result?.decision === 'allow' ? 'allowed-once' : 'rejected',
            () => 'cancelled')
  })

  /** Validate MODEL ("provider/model") and an optional EFFORT into a full selection. */
  const resolveSelection = async (model, effort) => {
    const slash = model.indexOf('/')
    if (slash <= 0) throw new Error(`model must be "provider/model": ${model}`)
    const resolved = await ctx.llm.resolveCallConfig({
      provider: model.slice(0, slash),
      model: model.slice(slash + 1),
      ...effort ? { reasoningEffort: ReasoningEffortId(effort) } : {},
    })
    return {
      provider: resolved.provider,
      model: resolved.model,
      ...resolved.reasoningEffort === undefined ? {} : { reasoningEffort: resolved.reasoningEffort },
    }
  }

  /** Every model of every provider, with its reasoning efforts. */
  const listModels = async () => {
    const groups = await Promise.all(ctx.llm.listProviders().map(async (provider) => {
      try {
        return await Promise.all((await ctx.llm.listModels(provider.id)).map(async (model) => {
          const info = await ctx.llm.resolveModelInfo(provider.id, model.id).catch(() => undefined)
          return {
            id: `${provider.id}/${model.id}`,
            name: model.name,
            ...model.description === undefined ? {} : { description: model.description },
            efforts: (info?.reasoning?.efforts ?? []).map((e) => ({ id: String(e.id), name: e.name })),
            ...info?.reasoning?.defaultEffort === undefined
              ? {} : { defaultEffort: String(info.reasoning.defaultEffort) },
          }
        }))
      } catch {
        return []
      }
    }))
    return groups.flat()
  }

  /** Whether plan mode is on, counting a selection that takes effect at the next step. */
  const planWanted = (agent) => {
    const state = ctx.get('planMode')?.get(agent)
    return state !== undefined && (state.pending === true ? !state.active : state.active)
  }

  const currentConfig = () => {
    const current = selection.current
    return {
      model: current === undefined ? null : `${current.provider}/${current.model}`,
      effort: current?.reasoningEffort === undefined ? null : String(current.reasoningEffort),
      preset: handle === null ? null : ctx.permissionPresets.current(handle.agent.session),
      plan: handle !== null && planWanted(handle.agent),
    }
  }

  /** User message content for TEXT and image file PATHS. */
  const promptContent = async (text, paths = []) => {
    const content = []
    if (paths.length > 0) {
      const attachments = ctx.get('attachments')
      if (attachments === undefined) throw new Error('no attachment store for images')
      const images = await Promise.all(paths.map(async (path) => {
        const mediaType = IMAGE_TYPES[extname(path).toLowerCase()]
        if (mediaType === undefined) throw new Error(`unsupported image type: ${path}`)
        return { data: await readFile(path), mediaType }
      }))
      for (const ref of await attachments.saveImages(images)) content.push({ type: 'image', attachment: ref })
    }
    if (text) content.push({ type: 'text', text })
    if (content.length === 0) throw new Error('empty message')
    return content
  }

  /**
   * Title of session ID: a generated or user-given title, else the first typed
   * message in EVENTS (dsh's own fallback cuts it short); null for a session
   * without messages.
   */
  const sessionTitle = async (id, events) => {
    const first = events.find((event) => event.type === 'user/message' && isTypedMessage(event.data))
    if (first === undefined) return null
    const stored = await ctx.get('sessionQuery')?.readTitle(id).catch(() => undefined)
    return stored?.title && stored.source?.kind !== 'fallback' ? stored.title : contentText(first.data.content)
  }

  /** The transcript of a resumed session, in notification form. */
  const historyOf = (session) => {
    const items = []
    const toolNamesById = new Map()
    for (const event of session.snapshotEvents()) {
      const data = event.data
      switch (event.type) {
        case 'user/message':
          if (isTypedMessage(data)) {
            items.push({ method: 'user', params: {
              id: data.id,
              text: contentText(data.content),
              images: (data.content ?? []).filter((block) => block.type === 'image').length,
            } })
          }
          break
        case 'assistant/message':
          (data.message?.content ?? []).forEach((block, index) => {
            if ((block.type === 'text' || block.type === 'reasoning') && block.text) {
              items.push({ method: 'text/done', params: {
                id: `${event.seq}/${index}`,
                kind: block.type === 'text' ? 'assistant' : 'thinking',
                text: block.text,
              } })
            }
          })
          break
        case 'tool/call':
          toolNamesById.set(data.callId, data.name)
          items.push({ method: 'tool', params: { id: data.callId, name: data.name, arguments: data.arguments } })
          break
        case 'tool/result':
          items.push({ method: 'tool/done', params: toolResult(data, toolNamesById) })
          break
      }
    }
    return items
  }

  ctx.on('user-questions/request', (req, next) => {
    if (req.agent === undefined || !owns(req.agent)) return next()
    return request('question', { callId: req.wait?.callId, questions: req.questions })
  })

  const methods = {
    async initialize(params) {
      if (handle !== null) throw new Error('already initialized')
      const warnings = []
      const setup = async (agentCtx) => {
        installModelSelection(agentCtx, selection)
        for (const server of params.mcpServers ?? []) {
          try {
            await agentCtx.plugin(McpClient, McpClient.Config({
              transport: 'stdio',
              serverName: server.name,
              command: server.command,
              args: server.args ?? [],
              env: server.env ?? {},
              cwd: params.cwd,
              failOnStartupError: false,
              ...server.timeoutMs ? { toolCallTimeoutMs: server.timeoutMs } : {},
            }))
          } catch (error) {
            warnings.push(`MCP ${server.name}: ${errorMessage(error)}`)
          }
        }
      }
      const fallback = ctx.get('agentDefaultModel')?.currentSelection()
      const fallbackModel = fallback && `${fallback.provider}/${fallback.model}`
      if (params.resume) {
        handle = await ctx.agents.resume({
          resumeSessionId: params.resume,
          setup: async (agentCtx, agent) => {
            // Continue with the model the session last used.
            const logged = agent.session.requestHeader()
            if (logged !== undefined) {
              selection.current = {
                provider: logged.config.provider,
                model: logged.config.model,
                ...logged.config.reasoningEffort === undefined || logged.adapterDefaults?.reasoningEffort === true
                  ? {} : { reasoningEffort: logged.config.reasoningEffort },
              }
            }
            await setup(agentCtx)
          },
        })
        // A session that never reached the model has no logged route.
        selection.current ??= fallback && await resolveSelection(fallbackModel, fallback.reasoningEffort)
      } else {
        // Unspecified fields fall back to the profile's default selection.
        try {
          selection.current = await resolveSelection(params.model ?? fallbackModel,
                                                     params.effort ?? fallback?.reasoningEffort)
        } catch (error) {
          if (!params.model && !params.effort) throw error
          warnings.push(`${params.model ?? fallbackModel} ${params.effort ?? ''}: ${errorMessage(error)}`)
          selection.current = await resolveSelection(fallbackModel, fallback?.reasoningEffort)
        }
        handle = await ctx.agents.create({
          sessionId: randomUUID(),
          meta: { cwd: params.cwd },
          agentOptions: { ...selection.current },
          setup,
        })
      }
      if (params.preset) {
        try {
          ctx.permissionPresets.set(handle.agent.session, params.preset)
        } catch (error) {
          warnings.push(`${params.preset}: ${errorMessage(error)}`)
        }
      }
      if (params.plan !== undefined) ctx.get('planMode')?.set(handle.agent, params.plan)
      await ctx.sessions.flush(handle.agent.session)
      const agent = handle.agent
      return {
        sessionId: agent.session.id,
        title: params.resume ? await sessionTitle(agent.session.id, agent.session.snapshotEvents()) : null,
        config: currentConfig(),
        models: await listModels(),
        presets: [...ctx.permissionPresets.names],
        plan: ctx.get('planMode') !== undefined,
        commands: (ctx.get('commands')?.list(agent) ?? []).map((command) => ({
          name: command.name,
          description: command.description,
          ...command.input?.hint === undefined ? {} : { hint: command.input.hint },
        })),
        history: params.resume ? historyOf(agent.session) : [],
        warnings,
      }
    },
    configure(params) {
      const run = async () => {
        if (handle === null) throw new Error('not initialized')
        if (params.model != null || params.effort !== undefined) {
          const current = selection.current
          const currentModel = current && `${current.provider}/${current.model}`
          const model = params.model ?? currentModel
          if (!model) throw new Error('no model selected')
          const effort = params.effort !== undefined ? params.effort
            : model === currentModel ? current?.reasoningEffort : undefined
          selection.current = await resolveSelection(model, effort ?? undefined)
        }
        if (params.preset) ctx.permissionPresets.set(handle.agent.session, params.preset)
        if (params.plan !== undefined) ctx.get('planMode')?.set(handle.agent, params.plan)
        return { config: currentConfig() }
      }
      const result = configuring.then(run)
      configuring = result.catch(() => {})
      return result
    },
    async prompt(params) {
      if (handle === null) throw new Error('not initialized')
      const commands = ctx.get('commands')
      const name = /^\/([a-z0-9_-]+)(?:\s|$)/.exec(params.text ?? '')?.[1]
      if (commands !== undefined && name !== undefined && commands.find(handle.agent, name) !== undefined) {
        const execution = await commands.execute(handle.agent, params.text, [], new AbortController().signal)
        if (execution !== undefined) return { command: execution.result, status: handle.agent.status }
      }
      const message = createUserMessage({
        content: await promptContent(params.text, params.images),
        source: { kind: 'user' },
      })
      handle.agent.followup(message)
      return { messageId: message.id }
    },
    async steer(params) {
      if (handle === null) throw new Error('not initialized')
      const message = createUserMessage({
        content: await promptContent(params.text, params.images),
        source: { kind: 'user' },
      })
      handle.agent.steer(message)
      return { messageId: message.id }
    },
    async 'sessions/list'(params) {
      const query = ctx.get('sessionQuery')
      if (query === undefined) return { sessions: [] }
      // Compare physical directories; report each session under the given name.
      const wanted = new Map()
      for (const cwd of params.cwds ?? []) wanted.set(await realpath(cwd).catch(() => cwd), cwd)
      const roots = []
      for (const { header } of await query.listSessions()) {
        if (header.origin === 'subagent' || header.parentSession !== undefined || !header.cwd) continue
        const cwd = wanted.get(await realpath(header.cwd).catch(() => header.cwd))
        if (cwd !== undefined) roots.push({ ...header, cwd })
      }
      roots.sort((a, b) => b.createdAt - a.createdAt)
      const recent = roots.slice(0, 50)
      const sessions = await Promise.all(recent.map(async (header) => {
        const events = (await query.readSession(header.id).catch(() => undefined))?.events ?? []
        return {
          id: header.id,
          cwd: header.cwd,
          title: await sessionTitle(header.id, events),
          time: (events.at(-1)?.time ?? header.createdAt) / 1000,
        }
      }))
      return { sessions: sessions.filter((session) => session.title !== null).sort((a, b) => b.time - a.time) }
    },
    cancel() {
      handle?.agent.cancel({ kind: 'user' })
      return {}
    },
  }

  const onLine = async (line) => {
    if (line.trim() === '') return
    let message
    try {
      message = JSON.parse(line)
    } catch {
      return
    }
    // Response to one of our requests.
    if (message.method === undefined) {
      const waiter = pending.get(message.id)
      if (waiter === undefined) return
      pending.delete(message.id)
      if (message.error) waiter.reject(new Error(message.error.message))
      else waiter.resolve(message.result)
      return
    }
    const method = methods[message.method]
    if (method === undefined) {
      if (message.id !== undefined) {
        write({ id: message.id, error: { code: -32601, message: `unknown method ${message.method}` } })
      }
      return
    }
    try {
      const result = await method(message.params ?? {})
      if (message.id !== undefined) write({ id: message.id, result })
    } catch (error) {
      logger.warn?.(`emacs-bridge: ${message.method} failed: ${errorMessage(error)}`)
      if (message.id !== undefined) {
        write({ id: message.id, error: { code: -32603, message: errorMessage(error) } })
      }
    }
  }

  const lines = createInterface({ input: process.stdin })
  lines.on('line', (line) => { void onLine(line) })

  ctx.on('dispose', async () => {
    lines.close()
    for (const waiter of pending.values()) waiter.reject(new Error('bridge disposed'))
    pending.clear()
    const current = handle
    handle = null
    await current?.dispose()
  })
}
