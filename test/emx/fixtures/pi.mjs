#!/usr/bin/env node
// Deterministic Pi RPC peer: no Pi import, real history, credentials or network.
import { appendFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
const argv = process.argv.slice(2)
const arg = (name) => argv[argv.indexOf(name) + 1]
const log = (direction, value) => {
  if (process.env.EMX_PI_LOG) appendFileSync(process.env.EMX_PI_LOG, JSON.stringify({
    direction, ...value, argv, cwd: process.cwd(), socket: process.env.EMX_DAEMON_SOCKET,
    session: process.env.EMX_SESSION, emx: process.env.EMX_PI_EMX,
  }) + '\n')
}
const write = (value) => { log('out', value); process.stdout.write(JSON.stringify(value) + '\n') }
const response = (m, data) => write({ id: m.id, type: 'response', command: m.type, success: true, data })
const models = ['kimi-k3', 'glm-5.3-flash', 'model-free', 'preview-model', 'contributor-model'].map((id) => ({
  id, provider: 'opencode-go', name: id, reasoning: true,
  thinkingLevelMap: { off: null, minimal: null, medium: null, ...(id === 'kimi-k3' ? { low: null } : {}), max: 'max' },
})).concat([
  { id: 'thinking-no-map', provider: 'opencode-go', reasoning: true },
  { id: 'thinking-partial-map', provider: 'opencode-go', reasoning: true,
    thinkingLevelMap: { low: null, high: 'high', xhigh: null, max: null } },
  { id: 'thinking-extended-map', provider: 'opencode-go', reasoning: true,
    thinkingLevelMap: { max: 0, xhigh: 'xhigh', low: null, unknown: 'ignored' } },
  { id: 'thinking-high-excluded', provider: 'opencode-go', reasoning: true,
    thinkingLevelMap: { high: null, max: 'max' } },
  { id: 'nonreasoning-no-map', provider: 'opencode-go', reasoning: false },
  { id: 'nonreasoning-map', provider: 'opencode-go', reasoning: false,
    thinkingLevelMap: { off: null, high: 'high', xhigh: 'xhigh', max: 'max' } },
  { id: 'other', provider: 'other-provider', name: 'Other', reasoning: false },
])
// Pi 1.3 getSupportedThinkingLevels / clampThinkingLevel: base levels are
// opt-out, extended levels opt-in, and unsupported requests clamp upward first.
const levels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
const supportedThinkingLevels = (model) => !model.reasoning ? ['off'] : levels.filter((level) => {
  const mapped = model.thinkingLevelMap?.[level]
  if (mapped === null) return false
  return level !== 'xhigh' && level !== 'max' || mapped !== undefined
})
const clampThinkingLevel = (model, level) => {
  const supported = supportedThinkingLevels(model)
  if (supported.includes(level)) return level
  const index = levels.indexOf(level)
  if (index === -1) return supported[0] ?? 'off'
  for (const candidate of [...levels.slice(index), ...levels.slice(0, index).reverse()]) {
    if (supported.includes(candidate)) return candidate
  }
  return supported[0] ?? 'off'
}
// Isolated fixture settings: Kimi prefers high, no global override. Pi's
// built-in default is medium; model switches otherwise retain the current level.
const modelThinkingLevels = { 'opencode-go/kimi-k3': 'high' }
const globalThinkingLevel = undefined
const modelThinkingLevel = (model) => modelThinkingLevels[`${model.provider}/${model.id}`]
let model = models.find((m) => `${m.provider}/${m.id}` === arg('--model')) ?? models[0]
let thinkingLevel = clampThinkingLevel(model, argv.includes('--thinking') ? arg('--thinking')
  : modelThinkingLevel(model) ?? globalThinkingLevel ?? 'medium')
let isStreaming = false
// Pi resolves --no-session before either --session or --fork. Fail tests that
// combine them instead of silently pretending inheritance worked.
if (argv.includes('--no-session') && (argv.includes('--session') || argv.includes('--fork'))) {
  throw new Error('--no-session discards Pi resume/fork history')
}
let sessionId = argv.includes('--session') ? arg('--session') : randomUUID()
let turn = 0
let waiting
const finish = (text = '最终回复\u2028保留\u2029字符', aborted = false) => {
  write({ type: 'message_start', message: { role: 'assistant', content: [] } })
  for (const [index, kind, content] of [[0, 'thinking', '思考'], [1, 'text', 'partial']]) {
    write({ type: 'message_update', assistantMessageEvent: { type: `${kind}_start`, contentIndex: index } })
    write({ type: 'message_update', assistantMessageEvent: { type: `${kind}_delta`, contentIndex: index, delta: content } })
    write({ type: 'message_update', assistantMessageEvent: { type: `${kind}_end`, contentIndex: index, content } })
  }
  write({ type: 'message_end', message: { role: 'assistant', provider: model.provider, model: model.id,
    content: [{ type: 'thinking', thinking: '最终思考' }, { type: 'text', text }],
    usage: { input: 2, output: 5, cacheRead: 3, cacheWrite: 4, totalTokens: 14 } } })
  write({ type: 'turn_end', message: {}, toolResults: [] })
  write({ type: 'agent_end', messages: [], willRetry: false })
  // agent_end alone must not unlock the session's queue.
  setTimeout(() => { isStreaming = false; write({ type: 'agent_settled', aborted }) }, 30)
}
function receive(m) {
  log('in', m)
  if (m.type === 'extension_ui_response') {
    const call = waiting
    waiting = undefined
    if (!call) return
    write({ type: 'tool_execution_update', toolCallId: call.id, toolName: call.tool,
      partialResult: { content: [{ type: 'text', text: 'partial output' }] } })
    write({ type: 'tool_execution_end', toolCallId: call.id, toolName: call.tool,
      isError: !['allow', 'always'].includes(m.value), result: { content: [{ type: 'text', text: m.value ?? 'cancelled' }] } })
    finish(m.value ?? 'cancelled'); return
  }
  switch (m.type) {
    case 'get_state': response(m, { sessionId, model, thinkingLevel, isStreaming, pendingMessageCount: 0 }); break
    case 'get_available_models': response(m, { models }); break
    case 'get_commands': response(m, { commands: [{ name: 'fixture', description: 'Fixture command', source: 'extension' }] }); break
    case 'set_model':
      model = models.find((v) => v.provider === m.provider && v.id === m.modelId)
      if (!model) throw new Error('Invalid fixture model')
      response(m, model); break
    case 'set_thinking_level': thinkingLevel = m.level; response(m); break
    case 'get_session_stats': response(m, { sessionId, tokens: { total: turn * 14 } }); break
    case 'prompt': {
      if (m.message === '/handled') { response(m, { disposition: 'handled' }); break }
      turn++; isStreaming = true
      response(m, { disposition: 'started' }); write({ type: 'agent_start' }); write({ type: 'turn_start' })
      if (m.message === 'hold' || m.message.endsWith('\nhold')) break
      if (m.message === 'exit') { process.exit(7); break }
      if (m.message === 'retry' || m.message === 'retry-fail') {
        const failed = { role: 'assistant', content: [], stopReason: 'error', errorMessage: 'fixture retry' }
        write({ type: 'message_end', message: failed })
        write({ type: 'auto_retry_start', attempt: 1, maxAttempts: 3, delayMs: 0, errorMessage: 'fixture retry' })
        if (m.message === 'retry-fail') {
          write({ type: 'message_end', message: failed })
          write({ type: 'auto_retry_end', success: false, attempt: 1, finalError: 'fixture retry' })
        }
      }
      if (m.message === 'bad-model') model = models[2]
      let call
      try { call = JSON.parse(m.message) } catch { /* Normal text prompt. */ }
      if (call?.tool) {
        waiting = { ...call, id: `call-${turn}` }
        const toolCall = { type: 'toolCall', id: waiting.id, name: call.tool, arguments: call.input ?? {} }
        write({ type: 'message_start', message: { role: 'assistant', content: [] } })
        write({ type: 'message_update', assistantMessageEvent: { type: 'toolcall_start', contentIndex: 0, id: waiting.id, toolName: call.tool } })
        write({ type: 'message_update', assistantMessageEvent: { type: 'toolcall_delta', contentIndex: 0, delta: JSON.stringify(toolCall.arguments) } })
        write({ type: 'message_update', assistantMessageEvent: { type: 'toolcall_end', contentIndex: 0, toolCall } })
        write({ type: 'message_end', message: { role: 'assistant', content: [toolCall] } })
        write({ type: 'tool_execution_start', toolCallId: waiting.id, toolName: call.tool, args: call.input ?? {} })
        write({ type: 'extension_ui_request', id: `approval-${turn}`, method: 'select',
          title: 'emx-approval ' + JSON.stringify(waiting), options: ['allow', 'always', 'deny', 'deny-plan'] })
      } else finish()
      break
    }
    case 'steer': response(m, { disposition: 'queued' }); finish(m.message); break
    case 'clear_queue': response(m, { steering: [], followUp: [] }); break
    case 'abort': waiting = undefined; response(m); finish('aborted', true); break
    default: write({ id: m.id, type: 'response', command: m.type, success: false, error: 'unsupported fixture command' })
  }
}
let buffer = ''
process.stdin.setEncoding('utf8').on('data', (data) => {
  buffer += data
  let end
  while ((end = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, end); buffer = buffer.slice(end + 1)
    if (line) receive(JSON.parse(line))
  }
})
