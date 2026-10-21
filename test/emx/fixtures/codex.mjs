#!/usr/bin/env node
// Deterministic app-server: no credentials, SDK, MCP child or network.
import { createInterface } from 'node:readline'
import { appendFileSync, existsSync } from 'node:fs'
if (process.argv[2] === 'exec') { console.log('fixture-handle'); process.exit(0) }
const write = (value) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n')
const notify = (method, params) => write({ method, params: { threadId: 'fake-thread', ...params } })
const result = (id, value = {}) => write({ id, result: value })
const log = (value) => process.env.EMX_CODEX_LOG && appendFileSync(process.env.EMX_CODEX_LOG, JSON.stringify({ ...value, pid: process.pid, argv: process.argv.slice(2) }) + '\n')
if (process.env.EMX_CODEX_RESTART_GATE) process.on('SIGTERM', () => {
  // Hold the old process until the test has interrupted its pending send.
  const timer = setInterval(() => {
    if (existsSync(process.env.EMX_CODEX_RESTART_GATE)) { clearInterval(timer); process.exit(0) }
  }, 5)
})
let turn = 0, waiting, total = 0, multiUsage = false
const usage = () => ({ last: { totalTokens: 20, inputTokens: 15, cachedInputTokens: 3, cacheWriteInputTokens: 2, outputTokens: 5 }, total: { totalTokens: total } })
const quota = { planType: 'plus', primary: { windowDurationMins: 300, usedPercent: 25, resetsAt: 2000000000 },
  secondary: { windowDurationMins: 10080, usedPercent: 10, resetsAt: 2000000500 }, credits: { balance: '12.5', unlimited: false } }
const finish = (text = 'hi', status = 'completed') => {
  notify('item/agentMessage/delta', { itemId: `text-${turn}`, delta: text.slice(0, 1) })
  notify('item/agentMessage/delta', { itemId: `text-${turn}`, delta: text.slice(1) })
  notify('item/completed', { item: { id: `text-${turn}`, type: 'agentMessage', text } })
  total += 20
  notify('thread/tokenUsage/updated', { tokenUsage: usage() })
  notify('thread/tokenUsage/updated', { tokenUsage: usage() }) // Duplicate must not count.
  if (multiUsage) {
    total += 20
    notify('thread/tokenUsage/updated', { tokenUsage: usage() })
  }
  notify('account/rateLimits/updated', { rateLimits: { credits: { unlimited: true } } })
  notify('turn/completed', { turn: { id: `turn-${turn}`, status, ...(status === 'failed' ? { error: { message: 'turn failed' } } : {}) } })
  notify('thread/tokenUsage/updated', { tokenUsage: usage() }) // Repeated outside turn.
}
const history = (n) => ({ id: `old-turn-${n}`, items: [
  { id: `old-user-${n}`, type: 'userMessage', content: [{ type: 'text', text: `past ${n}` }, { type: 'image' }] },
  { id: `old-thought-${n}`, type: 'reasoning', summary: ['thought'] },
  { id: `old-tool-${n}`, type: 'commandExecution', command: 'echo old', status: 'completed', aggregatedOutput: 'old' },
  { id: `old-text-${n}`, type: 'agentMessage', text: `reply ${n}` },
] })
const echoUser = (id, content) => {
  const item = { id, type: 'userMessage', content }
  notify('item/started', { item })
  notify('item/completed', { item })
}
createInterface({ input: process.stdin }).on('line', (line) => {
  const msg = JSON.parse(line), p = msg.params ?? {}
  log(msg)
  if (!msg.method) {
    if (waiting === 'file') notify('item/completed', { item: { id: `edit-${turn}`, type: 'fileChange',
      status: msg.result.decision === 'decline' ? 'declined' : 'completed',
      changes: [{ path: process.cwd() + '/a', kind: { type: 'add' }, diff: 'new\n' }] } })
    waiting = undefined; finish(JSON.stringify(msg.result)); return
  }
  switch (msg.method) {
    case 'initialize': result(msg.id, { userAgent: 'fixture' }); break
    case 'initialized': break
    case 'model/list': result(msg.id, { data: [{ model: 'fake-cheap', displayName: 'Cheap',
      supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'high' }], defaultReasoningEffort: 'low' },
      { model: 'hidden', hidden: true }] }); break
    case 'config/read':
      if (process.env.EMX_CODEX_BAD_CONFIG) result(msg.id, { config: { developer_instructions: 42 } })
      else result(msg.id, { config: { developer_instructions: '  User rules.\n' } }); break
    case 'skills/extraRoots/set': result(msg.id); break
    case 'thread/start': case 'thread/resume': case 'thread/fork':
      result(msg.id, { thread: { id: 'fake-thread' }, model: p.model ?? 'fake-cheap' })
      notify('thread/tokenUsage/updated', { tokenUsage: usage() }); break
    case 'thread/list': result(msg.id, { data: [{ id: 'past-codex', name: 'Past Codex', updatedAt: 12, cwd: process.cwd() }] }); break
    case 'thread/turns/list':
      result(msg.id, { data: p.cursor ? [history(3)] : [history(1), history(2)], nextCursor: p.cursor ? null : 'page-2' }); break
    case 'account/rateLimits/read': result(msg.id, { rateLimits: quota }); break
    case 'turn/start': {
      turn++
      // Restarted fixture ids differ from historical blocks and previous process ids.
      turn = process.pid * 100 + turn
      const text = p.input.find((v) => v.type === 'text')?.text
      multiUsage = text === 'multi-usage'
      if (text === 'crash') { result(msg.id, { turn: { id: `turn-${turn}`, status: 'inProgress' } }); process.exit(7) }
      const begin = () => {
        if (text !== 'response-only') notify('turn/started', { turn: { id: `turn-${turn}`, status: 'inProgress' } })
        result(msg.id, { turn: { id: `turn-${turn}`, status: 'inProgress' } })
        echoUser(`user-${turn}`, p.input)
        if (text === 'external-user') {
          notify('item/started', { item: { id: `external-${turn}`, type: 'userMessage', content: [{ type: 'text', text: 'external' }] } })
          notify('item/completed', { item: { id: `external-${turn}`, type: 'userMessage', content: [{ type: 'text', text: 'external message' }] } })
        }
        if (text === 'hold' || text === 'delayed' || text === 'response-only') {
          notify('item/reasoning/summaryTextDelta', { itemId: `hold-${turn}`, delta: 'holding' })
          return
        }
        notify('item/reasoning/summaryTextDelta', { itemId: `thought-${turn}`, delta: 'thinking' })
        notify('item/completed', { item: { id: `thought-${turn}`, type: 'reasoning' } })
        notify('item/started', { item: { id: `cmd-${turn}`, type: 'commandExecution', command: "/bin/bash -lc 'echo hi'", status: 'inProgress' } })
        notify('item/commandExecution/outputDelta', { itemId: `cmd-${turn}`, delta: 'h' })
        notify('item/commandExecution/outputDelta', { itemId: `cmd-${turn}`, delta: 'i' })
        notify('item/completed', { item: { id: `cmd-${turn}`, type: 'commandExecution', command: 'echo hi', status: 'completed', aggregatedOutput: 'hi', exitCode: 0 } })
        notify('item/started', { item: { id: `mcp-${turn}`, type: 'mcpToolCall', server: 'emacs', tool: 'context' } })
        notify('item/completed', { item: { id: `mcp-${turn}`, type: 'mcpToolCall', server: 'emacs', tool: 'context', result: { content: [{ type: 'text', text: 'context result' }] } } })
        notify('turn/plan/updated', { turnId: `turn-${turn}`, explanation: 'Plan', plan: [{ step: 'Do it', status: 'inProgress' }] })
        notify('item/completed', { item: { id: `web-${turn}`, type: 'webSearch', query: 'query' } })
        // Ignore child-thread events even when native subagents are enabled.
        notify('item/agentMessage/delta', { threadId: 'foreign', itemId: 'foreign', delta: 'WRONG' })
        notify('turn/completed', { threadId: 'foreign', turn: { id: 'foreign' } })
        if (text === 'file-approval') {
          notify('item/started', { item: { id: `edit-${turn}`, type: 'fileChange', changes: [{ path: process.cwd() + '/a', kind: { type: 'add' }, diff: 'new\n' }] } })
          waiting = 'file'
          write({ id: 'approval', method: 'item/fileChange/requestApproval', params: { itemId: `edit-${turn}`, reason: 'Write a' } }); return
        }
        if (text === 'command-approval') {
          waiting = true
          write({ id: 'approval', method: 'item/commandExecution/requestApproval', params: { itemId: `cmd-${turn}`, command: 'echo hi', reason: 'Run' } }); return
        }
        if (text === 'question') {
          waiting = true
          write({ id: 'q', method: 'item/tool/requestUserInput', params: { itemId: `mcp-${turn}`, questions: [
            { id: 'q1', header: 'Pick', question: 'Choose', isOther: true, options: [{ label: 'yes', description: 'Yes' }] },
            { id: 'q2', question: 'Skip?' },
          ] } }); return
        }
        if (text === 'error') notify('error', { willRetry: false, error: { message: 'fixture error' } })
        if (text === 'retry') notify('error', { willRetry: true, error: { message: 'retrying' } })
        if (text === 'reroute') notify('model/rerouted', { toModel: 'rerouted' })
        finish('hi', text === 'error' ? 'failed' : 'completed')
      }
      if (text === 'delayed') setTimeout(begin, 80)
      else begin()
      break
    }
    case 'turn/steer': result(msg.id); echoUser(`steer-${turn}`, p.input); finish(p.input.find((v) => v.type === 'text')?.text); break
    case 'turn/interrupt': waiting = undefined; result(msg.id); finish('interrupted', 'interrupted'); break
    default: write({ id: msg.id, error: { code: -32601, message: 'unsupported fixture request' } })
  }
})
