#!/usr/bin/env node
// Deterministic bridge peer: no dsh imports, credentials, MCP or network.
import { createInterface } from 'node:readline'
import { appendFileSync } from 'node:fs'
const write = (value) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n')
const notify = (method, params) => write({ method, params })
const result = (id, value = {}) => write({ id, result: value })
let config = { model: 'fake/chat', effort: 'high', preset: 'workspace-write', plan: false }
let turn = 0
let rejectedConfiguration = false
let waiting
const finish = (text = '你好', reason = 'done') => {
  notify('text', { id: `text-${turn}`, delta: text.slice(0, 1) })
  notify('text', { id: `text-${turn}`, delta: text.slice(1) })
  notify('text/done', { id: `text-${turn}`, text })
  notify('usage', { model: config.model, usage: { inputTokens: 2, cacheReadTokens: 3,
    cacheWriteTokens: 4, outputTokens: 5, totalTokens: 14 } })
  notify('turn/end', { reason, ...(reason === 'error' ? { error: 'fixture failure' } : {}) })
  notify('status', { status: 'idle' })
}
const lines = createInterface({ input: process.stdin })
lines.on('line', (line) => {
  const msg = JSON.parse(line)
  if (process.env.EMX_DSH_LOG) appendFileSync(process.env.EMX_DSH_LOG,
    JSON.stringify({ ...msg, argv: process.argv.slice(2), cwd: process.cwd() }) + '\n')
  const p = msg.params ?? {}
  if (!msg.method) {
    if (waiting === 'approval') finish(msg.result.decision)
    else if (waiting === 'plan') {
      config.plan = false
      notify('config', { config })
      finish(JSON.stringify(msg.result))
    } else finish(JSON.stringify(msg.result))
    waiting = undefined
    return
  }
  switch (msg.method) {
    case 'sessions/list': result(msg.id, { sessions: [{ id: 'past-dsh', title: 'Past dsh', time: 13, cwd: process.cwd() }] }); break
    case 'initialize':
      // Resume restores the logged route, ignoring initialize's model/effort.
      config = { model: p.resume ? 'fake/chat' : p.model ?? 'fake/chat',
        effort: p.resume ? 'high' : p.effort ?? 'high',
        preset: p.preset, plan: p.plan }
      result(msg.id, { sessionId: p.resume ?? 'fake-session', title: p.resume ? 'Resumed' : null,
        config, version: 'test-version', warnings: ['fixture warning'], presets: ['read-only',
          'workspace-write', 'auto', 'danger-full-access'], plan: true,
        models: [{ id: 'fake/chat', name: 'Chat', efforts: [{ id: 'high' }], defaultEffort: 'high' }],
        commands: [{ name: 'status', description: 'Show status', hint: '' }],
        history: p.resume ? [
          { method: 'user', params: { id: 'old-user', text: 'past', images: 1 } },
          { method: 'text/done', params: { id: 'old-thinking', kind: 'thinking', text: 'thought' } },
          { method: 'tool', params: { id: 'old-tool', name: 'read', arguments: '{"path":"old"}' } },
          { method: 'tool/done', params: { id: 'old-tool', output: 'old output' } },
          { method: 'text/done', params: { id: 'old-text', text: 'past reply' } },
          { method: 'usage', params: { model: 'fake/chat', usage: { inputTokens: 100 } } },
        ] : [] })
      break
    case 'configure':
      if (p.model === 'fake/retry' && !rejectedConfiguration) {
        rejectedConfiguration = true
        write({ id: msg.id, error: { code: -32603, message: 'fixture configure failure' } })
        break
      }
      config = { ...config, ...p, model: p.model ?? config.model, effort: p.effort ?? 'high' }
      result(msg.id, { config }); break
    case 'flush': result(msg.id); break
    case 'balance': result(msg.id, { balances: [{ total: '12.34', currency: 'CNY' }] }); break
    case 'prompt':
      if (p.text.startsWith('/')) {
        result(msg.id, { command: { kind: p.text === '/fail' ? 'error' : 'text',
          ...(p.text === '/empty' ? {} : { text: 'slash result' }) }, status: 'idle' }); break
      }
      turn++
      result(msg.id, { messageId: `message-${turn}` })
      notify('status', { status: 'running' })
      notify('tool', { id: `tool-${turn}`, name: 'bash', arguments: '{"command":"echo hi"}' })
      notify('tool/done', { id: `tool-${turn}`, output: 'hi' })
      if (p.text === 'edits') {
        for (const prefix of ['edit', 'failed-edit']) {
          notify('tool', { id: `${prefix}-${turn}`, name: 'edit',
            arguments: '{"path":"a","old_string":"old","new_string":"new"}' })
          notify('tool/done', { id: `${prefix}-${turn}`, isError: prefix === 'failed-edit',
            output: prefix === 'failed-edit' ? 'edit failure' : 'redundant success' })
        }
      }
      if (p.text === 'hold') break
      if (p.text === 'approval') {
        waiting = 'approval'
        write({ id: 'approve', method: 'approval', params: { callId: `tool-${turn}`,
          toolName: 'bash', reason: 'fixture approval' } }); break
      }
      if (p.text === 'question' || p.text === 'plan') {
        waiting = p.text
        write({ id: 'question', method: 'question', params: { callId: `tool-${turn}`, questions: [{
          id: 'q1', question: 'Pick', options: [{ label: 'yes' }, { label: 'no' }],
          multiSelect: false, ...(p.text === 'plan' ? { intent: { kind: 'plan-review', approve: 'yes' } } : {}),
        }] } }); break
      }
      if (p.text === 'discard') {
        notify('text', { id: 'discarded', kind: 'thinking', delta: 'abandoned' })
        notify('discard', { ids: ['discarded'] })
      }
      if (p.text === 'error') notify('error', { message: 'fixture failure' })
      if (p.text === 'exit') { process.exit(7); break }
      finish('你好', p.text === 'max' ? 'max-tokens' : ['error', 'end-error'].includes(p.text) ? 'error' : 'done')
      break
    case 'steer': result(msg.id, { messageId: 'steering' }); finish(p.text); break
    case 'cancel': result(msg.id); waiting = undefined; finish('cancelled'); break
    default: write({ id: msg.id, error: { code: -32601, message: 'unsupported' } })
  }
})
