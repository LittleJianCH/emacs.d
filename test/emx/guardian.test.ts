// guardian.test.ts --- unified emx guardian reviewer and Session.ask integration tests.
import './fixtures/environment.ts'
import * as assert from 'node:assert/strict'
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { buildEvidence, checkConventionRules, GuardianReviewer, parsePermissionVerdict } from '../../emx/daemon/guardian.ts'
import { Session } from '../../emx/daemon/session.ts'
import type { Config } from '../../emx/config.ts'
import type { Block } from '../../emx/daemon/protocol.ts'

async function makeFakeReviewer(t: TestContext, kind: 'pi' | 'agy') {
  const dir = await realpath(await mkdtemp(join(tmpdir(), `emx-guardian-${kind}-`)))
  const log = join(dir, 'reviewer.jsonl')
  const script = join(dir, `fake-${kind}.mjs`)
  const code = kind === 'pi'
    ? `#!${process.execPath}
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
const log = ${JSON.stringify(log)}
const write = (v) => process.stdout.write(JSON.stringify(v) + '\\n')
createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return
  const msg = JSON.parse(line)
  appendFileSync(log, JSON.stringify({ argv: process.argv.slice(2), msg }) + '\\n')
  if (msg.type === 'set_model' || msg.type === 'set_thinking_level') {
    write({ type: 'response', id: msg.id, success: true, data: {} })
  } else if (msg.type === 'prompt') {
    write({ type: 'response', id: msg.id, success: true, data: {} })
    const text = String(msg.message || '')
    let out
    if (text.includes('BAD_JSON')) out = 'not json at all'
    else if (text.includes('mcp_emacs_eval') && text.includes('delete-file')) {
      out = JSON.stringify({ decision: 'ask_user', reason: 'Deleting files via eval requires confirmation.' })
    } else {
      out = JSON.stringify({ decision: 'approve', reason: 'Read-only inspection is low risk.' })
    }
    write({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: out } })
    write({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: out }] } })
    write({ type: 'agent_end' })
  }
})
`
    : `#!${process.execPath}
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
const log = ${JSON.stringify(log)}
const write = (v) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...v }) + '\\n')
createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return
  const msg = JSON.parse(line)
  appendFileSync(log, JSON.stringify({ argv: process.argv.slice(2), method: msg.method, params: msg.params }) + '\\n')
  if (msg.method === 'initialize') write({ id: msg.id, result: { protocolVersion: 1, agentCapabilities: {} } })
  else if (msg.method === 'session/new') write({ id: msg.id, result: { sessionId: 'rev-1' } })
  else if (msg.method === 'session/set_config_option') write({ id: msg.id, result: {} })
  else if (msg.method === 'session/prompt') {
    const text = (msg.params?.prompt ?? []).map((p) => p.text ?? '').join('\\n')
    const out = text.includes('git push --force')
      ? JSON.stringify({ decision: 'ask_user', reason: 'Force push is high risk.' })
      : JSON.stringify({ decision: 'approve', reason: 'Safe read-only command.' })
    write({ method: 'session/update', params: { sessionId: 'rev-1', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: out } } } })
    write({ id: msg.id, result: { stopReason: 'end_turn' } })
  }
})
`
  await writeFile(script, code, { mode: 0o755 })
  t.after(() => rm(dir, { recursive: true, force: true }))
  const entries = async () => (await readFile(log, 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  return { dir, script, entries }
}

test('checkConventionRules blocks dangerous commands and allows safe ones', () => {
  assert.ok(checkConventionRules('rm -rf /'))
  assert.ok(checkConventionRules('claude --dangerously-skip-permissions -p hi'))
  assert.equal(checkConventionRules('git status'), undefined)
})

test('buildEvidence excludes thinking blocks and supports incremental slicing', () => {
  const blocks: Block[] = [
    { id: 'u1', type: 'user', text: 'Inspect init.el' },
    { id: 't1', type: 'text', kind: 'thinking', text: 'Secret chain of thought', done: true },
    { id: 'a1', type: 'text', kind: 'assistant', text: 'Reading init.el', done: true },
    { id: 'c1', type: 'tool', view: { kind: 'read', name: 'read_file', title: 'init.el' }, status: 'done', output: 'ok' },
  ]
  const full = buildEvidence(blocks, 0)
  assert.equal(full.nextIndex, 4)
  assert.deepEqual(full.records.map((r) => r.source), ['user', 'assistant', 'tool'])
  assert.ok(full.records.every((r) => !r.text.includes('Secret chain of thought')))

  blocks.push({ id: 'u2', type: 'user', text: 'Now run tests' })
  const delta = buildEvidence(blocks, full.nextIndex)
  assert.equal(delta.nextIndex, 5)
  assert.deepEqual(delta.records, [{ source: 'user', text: 'Now run tests' }])
})

test('parsePermissionVerdict parses fenced JSON and rejects invalid output', () => {
  assert.deepEqual(parsePermissionVerdict('```json\n{"decision":"approve","reason":"ok"}\n```'),
    { decision: 'approve', reason: 'ok' })
  assert.throws(() => parsePermissionVerdict('not json'))
  assert.throws(() => parsePermissionVerdict('{"decision":"unknown","reason":"x"}'))
})

test('GuardianReviewer reuses warm Pi worker with full then delta turns and fails closed on bad JSON', async (t) => {
  const { dir, script, entries } = await makeFakeReviewer(t, 'pi')
  const config = {
    agents: { pi: { title: 'Pi', executable: script } },
    reviewer: { agent: 'pi', model: 'opencode-go/deepseek-v4.1-flash', effort: 'low', timeoutMs: 10000 },
  } as unknown as Config

  const guardian = new GuardianReviewer(() => config)
  t.after(() => guardian.closeAll())

  const blocks: Block[] = [{ id: 'u1', type: 'user', text: 'Check buffer state' }]
  const session = { id: 's1', root: dir, blocks, environment: async () => ({ ...process.env }) }

  // 1. First call -> full mode -> approve
  const v1 = await guardian.review(session, {
    view: { kind: 'mcp', name: 'mcp_emacs_eval', title: 'Run mcp_emacs_eval' },
    reviewInput: { tool: 'mcp_emacs_eval', input: { code: '(buffer-name)' } },
  })
  assert.equal(v1.decision, 'approve')

  // 2. Second call -> delta mode on same warm worker -> ask_user
  blocks.push({ id: 'a1', type: 'text', kind: 'assistant', text: 'Checked buffer', done: true })
  const v2 = await guardian.review(session, {
    view: { kind: 'mcp', name: 'mcp_emacs_eval', title: 'Run mcp_emacs_eval' },
    reviewInput: { tool: 'mcp_emacs_eval', input: { code: '(delete-file "a")' } },
  })
  assert.equal(v2.decision, 'ask_user')
  assert.match(v2.reason, /Deleting files/)

  // Verify only one set_model (warm worker reused) and full -> delta transition.
  const log = await entries()
  assert.equal(log.filter((e) => e.msg.type === 'set_model').length, 1)
  const prompts = log.filter((e) => e.msg.type === 'prompt').map((e) => String(e.msg.message))
  assert.equal(prompts.length, 2)
  assert.match(prompts[0], /"mode": "full"/)
  assert.match(prompts[1], /"mode": "delta"/)

  // 3. Hard convention block does not even hit worker
  const v3 = await guardian.review(session, {
    view: { kind: 'command', name: 'run_command', title: 'rm -rf /', command: 'rm -rf /' },
  })
  assert.equal(v3.decision, 'ask_user')
  assert.equal((await entries()).filter((e) => e.msg.type === 'prompt').length, 2)

  // 4. Malformed JSON fails closed
  const v4 = await guardian.review(session, {
    view: { kind: 'command', name: 'run_command', title: 'BAD_JSON', command: 'echo BAD_JSON' },
  })
  assert.equal(v4.decision, 'ask_user')
  assert.match(v4.reason, /Automatic review failed/)
})

test('GuardianReviewer supports agy ACP worker and Session.ask integrates guardian mode', async (t) => {
  const { dir, script } = await makeFakeReviewer(t, 'agy')
  const config = {
    agents: { agy: { title: 'Antigravity', executable: script } },
    reviewer: { agent: 'agy', model: 'fake-flash', effort: 'low', timeoutMs: 10000 },
  } as unknown as Config

  const guardian = new GuardianReviewer(() => config)
  t.after(() => guardian.closeAll())

  const emitted: any[] = []
  const session = new Session({
    id: 's-guardian',
    agent: 'echo',
    root: dir,
    settings: { mode: 'guardian' },
    review: (s, ask, signal) => guardian.review(s, ask, signal),
    onClose: (s) => guardian.closeSession(s.id),
    onEvent: (_s, ev) => emitted.push(ev),
  })
  t.after(() => session.stop())
  session.addBlock({ id: 'u1', type: 'user', text: 'Check git status' })

  // Approved call returns allow without emitting ask/add
  const ans1 = await session.ask({
    type: 'approval',
    view: { kind: 'command', name: 'run_command', title: 'git status', command: 'git status' },
    choices: ['allow', 'deny'],
    reviewInput: { tool: 'run_command', input: { CommandLine: 'git status' } },
  })
  assert.deepEqual(ans1, { choice: 'allow' })
  assert.equal(emitted.filter((e) => e.type === 'ask/add').length, 0)

  // Escalated call emits ask/add with reason and stripped reviewInput
  const pending = session.ask({
    type: 'approval',
    view: { kind: 'command', name: 'run_command', title: 'git push --force', command: 'git push --force' },
    choices: ['allow', 'deny'],
    reviewInput: { tool: 'run_command', input: { CommandLine: 'git push --force' } },
  })
  for (let i = 0; i < 200 && !emitted.some((e) => e.type === 'ask/add'); i++) {
    await new Promise((r) => setTimeout(r, 10))
  }
  const added = emitted.find((e) => e.type === 'ask/add')
  assert.ok(added)
  assert.equal('reviewInput' in added.ask, false)
  assert.match(added.ask.description, /统一审查：Force push is high risk/)
  session.answer(added.ask.id, { choice: 'deny' })
  assert.deepEqual(await pending, { choice: 'deny' })
})
