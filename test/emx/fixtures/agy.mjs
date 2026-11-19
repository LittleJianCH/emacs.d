#!/usr/bin/env node
// Fake Antigravity CLI (agy acp) ACP JSON-RPC 2.0 server for tests.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const logFile = process.env.EMX_AGY_LOG
const record = (entry) => {
  if (logFile) try { appendFileSync(logFile, JSON.stringify(entry) + '\n') } catch {}
}
const write = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n')

let nextReq = 0
const pending = new Map()
const askClient = (method, params) => new Promise((resolve) => {
  const id = `srv-${++nextReq}`
  pending.set(id, resolve)
  write({ id, method, params })
})

let currentModel = 'fake-pro'
let currentEffort = 'high'
let currentMode = 'default'
let activeTurn = null

const configOptions = () => [
  {
    id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: currentModel,
    options: [
      { value: 'fake-pro', name: 'Fake Pro' },
      { value: 'fake-flash', name: 'Fake Flash' },
      { value: 'fake-oss-medium', name: 'Fake OSS (Medium)' },
    ],
  },
  {
    id: 'thought_level', name: 'Thinking Level', category: 'thought_level', type: 'select', currentValue: currentEffort,
    options: [
      { value: 'low', name: 'Low' },
      { value: 'medium', name: 'Medium' },
      { value: 'high', name: 'High' },
      ...(currentModel === 'fake-pro' ? [{ value: 'xhigh', name: 'Extra' }] : []),
    ],
  },
  {
    id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: currentMode,
    options: [
      { value: 'default', name: 'Default' },
      { value: 'accept-edits', name: 'Accept edits' },
      { value: 'auto', name: 'Auto' },
      { value: 'plan', name: 'Plan' },
    ],
  },
]

const modelsPayload = {
  currentModelId: 'fake-pro-high',
  availableModels: [
    { modelId: 'fake-pro-low', name: 'Fake Pro (Low)' },
    { modelId: 'fake-pro-medium', name: 'Fake Pro (Medium)' },
    { modelId: 'fake-pro-high', name: 'Fake Pro (High)' },
    { modelId: 'fake-pro-xhigh', name: 'Fake Pro (XHigh)' },
    { modelId: 'fake-flash-low', name: 'Fake Flash (Low)' },
    { modelId: 'fake-flash-medium', name: 'Fake Flash (Medium)' },
    { modelId: 'fake-flash-high', name: 'Fake Flash (High)' },
    { modelId: 'fake-oss-medium', name: 'Fake OSS (Medium)' },
  ],
}

const sessionPayload = (sessionId) => ({
  sessionId,
  models: modelsPayload,
  modes: {
    currentModeId: currentMode,
    availableModes: [
      { id: 'default', name: 'Default' },
      { id: 'accept-edits', name: 'Accept edits' },
      { id: 'auto', name: 'Auto' },
      { id: 'plan', name: 'Plan' },
    ],
  },
  configOptions: configOptions(),
})

const notify = (sessionId, update) => write({ method: 'session/update', params: { sessionId, update } })

createInterface({ input: process.stdin }).on('line', async (line) => {
  if (!line.trim()) return
  const msg = JSON.parse(line)
  if (!msg.method) {
    const resolve = pending.get(msg.id)
    if (resolve) { pending.delete(msg.id); resolve(msg.result) }
    return
  }
  record({ argv: process.argv.slice(2), cwd: process.cwd(), method: msg.method, params: msg.params })
  const p = msg.params ?? {}
  switch (msg.method) {
    case 'initialize':
      write({
        id: msg.id,
        result: {
          protocolVersion: 1,
          agentCapabilities: {
            loadSession: true,
            promptCapabilities: { image: true, audio: false, embeddedContext: true },
            sessionCapabilities: { resume: {}, close: {}, load: {}, list: {} },
            _meta: { antigravity: { systemPrompt: { append: true } } },
          },
          agentInfo: { name: 'Fake Antigravity ACP', version: '1.5.10' },
        },
      })
      break
    case 'session/new': {
      const sid = 'agy-sess-1'
      write({ id: msg.id, result: sessionPayload(sid) })
      notify(sid, {
        sessionUpdate: 'available_commands_update',
        availableCommands: [
          { name: 'plan', description: 'Plan carefully' },
          { name: 'compact', description: 'Compact history', input: { hint: 'optional note' } },
        ],
      })
      break
    }
    case 'session/load': {
      const sid = p.sessionId
      notify(sid, { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'Past question' } })
      notify(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Past answer' } })
      notify(sid, { sessionUpdate: 'usage_update', used: 500, size: 1048576 })
      write({ id: msg.id, result: sessionPayload(sid) })
      break
    }
    case 'session/resume': {
      write({ id: msg.id, result: sessionPayload(p.sessionId) })
      break
    }
    case 'session/list': {
      const fixture = process.env.EMX_AGY_HISTORY ? JSON.parse(process.env.EMX_AGY_HISTORY) : []
      write({ id: msg.id, result: { sessions: fixture.filter((s) => !p.cwd || s.cwd === p.cwd) } })
      break
    }
    case 'session/set_config_option': {
      if (p.configId === 'model') currentModel = p.value
      if (p.configId === 'thought_level') currentEffort = p.value
      if (p.configId === 'mode') currentMode = p.value
      write({ id: msg.id, result: { configOptions: configOptions() } })
      break
    }
    case 'session/prompt': {
      const sid = p.sessionId
      const text = (p.prompt ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('\n')
      if (text === 'cancel-me') {
        activeTurn = { id: msg.id, sid }
        notify(sid, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Working...' } })
        return
      }
      notify(sid, { sessionUpdate: 'session_info_update', title: 'Auto Title' })
      notify(sid, { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Thinking step' } })
      if (text.includes('readonly-mcp')) {
        const call = {
          toolCallId: 'call-ro', name: 'mcp__emacs__context', kind: 'other',
          title: 'emacs context', status: 'pending', rawInput: {},
        }
        notify(sid, { sessionUpdate: 'tool_call', ...call })
        const perm = await askClient('session/request_permission', {
          sessionId: sid, toolCall: call,
          options: [
            { optionId: 'allow', name: 'Allow', kind: 'allow_once' },
            { optionId: 'deny', name: 'Deny', kind: 'reject_once' },
          ],
        })
        record({ permissionOutcome: perm })
        notify(sid, {
          sessionUpdate: 'tool_call_update', ...call, status: 'completed',
          content: [{ type: 'content', content: { type: 'text', text: 'buffer: init.el' } }],
        })
      }
      if (text.includes('run-cmd')) {
        const call = {
          toolCallId: 'call-cmd', name: 'run_command', kind: 'execute',
          title: 'echo hi', status: 'pending', rawInput: { CommandLine: 'echo hi' },
        }
        notify(sid, { sessionUpdate: 'tool_call', ...call })
        const perm = await askClient('session/request_permission', {
          sessionId: sid, toolCall: call,
          options: [
            { optionId: 'allow', name: 'Allow', kind: 'allow_once' },
            { optionId: 'always', name: 'Always', kind: 'allow_always' },
            { optionId: 'deny', name: 'Deny', kind: 'reject_once' },
          ],
        })
        record({ permissionOutcome: perm })
        const denied = perm?.outcome?.optionId === 'deny' || perm?.outcome?.outcome === 'cancelled'
        notify(sid, {
          sessionUpdate: 'tool_call_update', ...call,
          status: denied ? 'declined' : 'completed',
          rawOutput: denied ? { error: 'declined' } : { output: 'hi\n' },
        })
      }
      if (text.includes('show-plan')) {
        notify(sid, {
          sessionUpdate: 'plan',
          entries: [
            { content: 'Read code', status: 'completed' },
            { content: 'Write tests', status: 'in_progress' },
          ],
        })
      }
      notify(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Done: ' } })
      notify(sid, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: text } })
      notify(sid, { sessionUpdate: 'usage_update', used: 1234, size: 1048576 })
      write({
        id: msg.id,
        result: {
          stopReason: 'end_turn',
          usage: { inputTokens: 100, outputTokens: 20, cachedReadTokens: 50, cachedWriteTokens: 10, thoughtTokens: 5, totalTokens: 185 },
        },
      })
      break
    }
    case 'session/cancel': {
      if (activeTurn && activeTurn.sid === p.sessionId) {
        const turn = activeTurn
        activeTurn = null
        write({ id: turn.id, result: { stopReason: 'cancelled' } })
      }
      break
    }
    case 'session/close':
      write({ id: msg.id, result: {} })
      break
    default:
      write({ id: msg.id, error: { code: -32601, message: `Unknown method: ${msg.method}` } })
  }
})
