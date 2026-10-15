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
//   initialize {cwd, resume?, provider?, model?, effort?} -> {sessionId, provider, model}
//   prompt     {text}                                      -> {messageId}
//   cancel     {}                                          -> {}
//
// Requests (dsh -> Emacs):
//   approval   {callId?, toolName, reason?}                -> {decision: allow|reject}
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
//   error      {message}

import { createRequire } from 'node:module'
import { realpathSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { createInterface } from 'node:readline'

export const name = 'emacs-bridge'
export const inject = ['agents', 'sessions', 'sessionPersistence']

// Plugin files outside the dsh installation cannot import its packages by
// name, so resolve them from the running dsh binary.
const dshRequire = createRequire(realpathSync(process.argv[1]))
const { createUserMessage } = await import(dshRequire.resolve('@deepseek-ai/dsh-llm'))

/** Plain text of a content block list. */
function contentText(content) {
  if (typeof content === 'string') return content
  return (content ?? []).map((block) => block.type === 'text' ? block.text : '').join('')
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
      case 'tool/result': {
        const id = data.message.toolCallId
        const output = data.error?.reason ?? contentText(data.message.content)
        // bash reports a failing command as a successful result ending in
        // "[exit code: N]".
        const exit = toolNames.get(id) === 'bash' ? /\[exit code: (\d+)\]\s*$/.exec(output) : null
        toolNames.delete(id)
        notify('tool/done', {
          id,
          isError: data.message.isError === true || data.error !== undefined
            || (exit !== null && exit[1] !== '0'),
          output,
        })
        break
      }
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

  const methods = {
    async initialize(params) {
      if (handle !== null) throw new Error('already initialized')
      // Unspecified fields fall back to the profile's default selection.
      const agentOptions = { ...ctx.get('agentDefaultModel')?.currentSelection() }
      if (params.provider) agentOptions.provider = params.provider
      if (params.model) agentOptions.model = params.model
      if (params.effort) agentOptions.reasoningEffort = params.effort
      handle = params.resume
        ? await ctx.agents.resume({ resumeSessionId: params.resume, agentOptions })
        : await ctx.agents.create({
          sessionId: randomUUID(),
          meta: { cwd: params.cwd },
          agentOptions,
        })
      await ctx.sessions.flush(handle.agent.session)
      const options = handle.agent.options
      return { sessionId: handle.agent.session.id, provider: options.provider, model: options.model }
    },
    prompt(params) {
      if (handle === null) throw new Error('not initialized')
      const message = createUserMessage({
        content: [{ type: 'text', text: params.text }],
        source: { kind: 'user' },
      })
      handle.agent.followup(message)
      return { messageId: message.id }
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
