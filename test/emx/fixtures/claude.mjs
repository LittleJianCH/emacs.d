#!/usr/bin/env node
// Fake stream-json CLI. Never contacts Claude or reads account credentials.
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { join } from 'node:path'
const argv = process.argv.slice(2)
if (!argv.includes('--input-format')) { console.log('fixture-handle'); process.exit(0) }
const value = (flag) => argv[argv.indexOf(flag) + 1]
const id = argv.includes('--fork-session') ? 'fixture-child-' + process.pid
  : argv.includes('--resume') ? value('--resume') : 'fixture-native'
const model = argv.includes('--model') ? value('--model') : 'fixture-model'
const emit = (m) => process.stdout.write(JSON.stringify(m) + '\n')
const log = (m) => appendFileSync(process.env.EMX_CLAUDE_LOG, JSON.stringify({ pid: process.pid, ...m }) + '\n')
const dir = join(process.env.EMX_CLAUDE_PROJECTS_DIR, process.cwd().replace(/[^\p{L}\p{N}]/gu, '-'))
mkdirSync(dir, { recursive: true })
log({ type: 'spawn', argv })
if (argv.includes('--fixture-delay-exit')) process.once('SIGTERM', () => {
  log({ type: 'terminating' })
  setTimeout(() => process.exit(0), 250)
})
let count = argv.includes('--resume') ? 50 : 0
let serial = 0
let held = false
let active
const finish = (error = false) => {
  held = false
  count++
  emit({ type: 'result', is_error: error, result: error ? 'fixture error' : 'hi',
    usage: { input_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4, output_tokens: 5 },
    modelUsage: { [model]: { inputTokens: 2 * count, cacheReadInputTokens: 3 * count, cacheCreationInputTokens: 4 * count, outputTokens: 5 * count } } })
}
const stream = (text) => {
  const mid = 'message-' + (++serial)
  const e = (event) => emit({ type: 'stream_event', event })
  e({ type: 'message_start', message: { id: mid, usage: { input_tokens: 8 } } })
  e({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'consider' } })
  e({ type: 'content_block_stop', index: 0 })
  e({ type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text } })
  e({ type: 'content_block_stop', index: 1 })
  e({ type: 'content_block_start', index: 2, content_block: { type: 'tool_use', id: mid + '-tool', name: 'Bash', input: {} } })
  emit({ type: 'assistant', message: { content: [{ type: 'tool_use', id: mid + '-tool', name: 'Bash', input: { command: 'echo hi\necho bye' } }] } })
  emit({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: mid + '-tool', content: [{ type: 'text', text: 'hi' }, { type: 'image' } ] }] } })
  emit({ type: 'stream_event', parent_tool_use_id: 'subagent', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'hidden' } } })
}
createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line)
  log(m)
  if (m.type === 'control_response') log({ type: 'raw-response', line })
  if (m.type === 'control_request') {
    if (m.request.subtype === 'set_permission_mode' && argv.includes('--fixture-reject-mode')) {
      emit({ type: 'control_response', response: { subtype: 'error', request_id: m.request_id, error: 'fixture mode rejected' } })
      return
    }
    let response = {}
    if (m.request.subtype === 'initialize') response = { models: [{ value: model, displayName: 'Fixture', supportedEffortLevels: ['low', 'high'] }], commands: [{ name: 'status', argumentHint: 'hint' }] }
    emit({ type: 'control_response', response: { subtype: 'success', request_id: m.request_id, response } })
    if (m.request.subtype === 'initialize') emit({ type: 'system', subtype: 'init', session_id: id, model })
    if (m.request.subtype === 'interrupt' && held) finish()
  } else if (m.type === 'user') {
    const text = m.message.content
    if (text === 'exit') process.exit(7)
    if (text === 'hold') { held = true; return }
    if (text === 'raw-approval' || text === 'raw-question') {
      active = text
      const input = readFileSync(new URL('./claude-input.json', import.meta.url), 'utf8').trim()
      const suggestions = readFileSync(new URL('./claude-permissions.json', import.meta.url), 'utf8').trim()
      process.stdout.write(`{"type":"control_request","request_id":"raw-permission","request":{"subtype":"can_use_tool","tool_use_id":"raw-tool","tool_name":"${text === 'raw-question' ? 'AskUserQuestion' : 'Bash'}","input":${input},"permission_suggestions":${suggestions}}}\n`)
      return
    }
    if (text === 'approval' || text === 'question') {
      active = text
      emit({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'ask-tool', name: text === 'question' ? 'AskUserQuestion' : 'Bash', input: {} }] } })
      emit({ type: 'control_request', request_id: 'permission', request: { subtype: 'can_use_tool', tool_use_id: 'ask-tool',
        tool_name: text === 'question' ? 'AskUserQuestion' : 'Bash',
        input: text === 'question' ? { questions: [{ question: 'Pick', options: [{ label: 'one', description: 'first' }], multiSelect: true }], untouched: { false: false, empty: [], nil: null } }
          : { command: 'echo hi', preserve: { f: false, t: true, n: null, a: [], o: {}, unicode: '你好' } },
        permission_suggestions: [{ type: 'addRules', rules: [], value: false, destination: 'session' }],
      } })
      return
    }
    if (text === 'rate') emit({ type: 'rate_limit_event', rate_limit_info: { unifiedWindows: { five_hour: { utilization: 0.3, resetsAt: 1234 }, seven_day_opus: { utilization: 0.7, resetsAt: 5678 } } } })
    stream(typeof text === 'string' ? text : JSON.stringify(text))
    finish(text === 'error')
  } else if (m.type === 'control_response' && active) {
    emit({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'ask-tool', is_error: m.response.response.behavior === 'deny', content: 'permission result' }] } })
    stream(JSON.stringify(m.response.response))
    active = undefined
    finish()
  }
})
