// claude.test.ts --- stream-json protocol, history and lifecycle without API calls.
import './fixtures/environment.ts'
import * as assert from 'node:assert/strict'
import { appendFile, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import type { TestContext } from 'node:test'
import { ClaudeTotals, encodePath, entries, historyPage, rawJsonField, resultText, toolView } from '../../emx/backends/claude.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { OpenParams, Usage } from '../../emx/daemon/protocol.ts'

const editorTools = {
  tools: [{ name: 'context', description: 'Context', inputSchema: { type: 'object' } },
    { name: 'eval', description: 'Evaluate', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } }],
  readOnly: ['context', 'context', 'session_start', 'removed'],
}

async function setup(t: TestContext, options: Partial<OpenParams> = {}, history?: string, config?: Record<string, unknown>) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-claude-')))
  const saved = { ...process.env }
  delete process.env.EMX_CLAUDE_CONFIG
  if (config) process.env.EMX_CLAUDE_CONFIG = JSON.stringify(config)
  process.env.EMX_CLAUDE_EXECUTABLE = fileURLToPath(new URL('./fixtures/claude.mjs', import.meta.url))
  process.env.EMX_CLAUDE_LOG = join(dir, 'calls.jsonl')
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  const file = join(dir, 'projects', encodePath(dir), `${options.resume ?? 'fixture-native'}.jsonl`)
  if (history) { await mkdir(join(dir, 'projects', encodePath(dir)), { recursive: true }); await writeFile(file, history) }
  await mkdir(join(dir, 'emx'), { recursive: true })
  await writeFile(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  const daemon = new DaemonServer({ varDir: dir })
  let client: Awaited<ReturnType<typeof SocketClient.connect>> | undefined
  t.after(async () => {
    await daemon.stop(); await client?.close()
    for (const key of Object.keys(process.env)) if (key.startsWith('EMX_CLAUDE_')) delete process.env[key]
    Object.assign(process.env, saved)
    await rm(dir, { recursive: true, force: true })
  })
  await daemon.start()
  client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'claude-test', version: daemon.version,
    tools: editorTools })
  const { id } = await client.request('session/open', { agent: 'claude', root: dir, ...options })
  const attached = await client.request('session/attach', { id })
  await client.waitFor((n) => n.method === 'history/done')
  const session = daemon.sessions.get(id)!
  const calls = async () => (await readFile(join(dir, 'calls.jsonl'), 'utf8')).trim().split('\n').map((s) => JSON.parse(s))
  const send = async (text: string) => {
    const from = client.notifications.length
    await client.request('session/send', { id, text })
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'turn end', from)
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
    return client.notifications.slice(from)
  }
  return { dir, file, daemon, client, id, attached, session, calls, send }
}

async function until(predicate: () => boolean | Promise<boolean>) {
  const deadline = Date.now() + 5000
  while (!await predicate()) {
    assert.ok(Date.now() < deadline, 'condition completes within five seconds')
    await delay(10)
  }
}

for (const trigger of ['background', 'background-assistant']) test(`background completion starts an accounted autonomous turn (${trigger})`, async (t) => {
  const { client, session, daemon, send } = await setup(t)
  assert.equal(session.status, 'idle', 'initialize/init does not start a turn')
  const emitted = t.mock.method(session, 'emit')
  const from = client.notifications.length
  await send(trigger)
  assert.equal(session.status, 'idle')
  assert.equal(session.busy(), false, 'background work does not block input or collaboration')
  assert.equal(session.pendingWork(), true)
  assert.deepEqual(session.info.backgroundTasks, [{ id: 'background-1', description: 'Fixture background command', type: 'local_bash' }])
  await client.waitFor((n) => n.method === 'info' && n.params.info.backgroundTasks?.length === 0, 5000, 'task list cleared', from)
  assert.equal(session.status, 'idle', 'wake init alone is not a running turn')
  assert.equal(session.pendingWork(), true, 'waking bridges the empty task list')
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED', 5000, 'autonomous reply', from)
  const wake = client.notifications.findIndex((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'autonomous turn end', wake)
  assert.equal(session.pendingWork(), false)
  assert.deepEqual(client.notifications.slice(from).filter((n) => n.method === 'status').map((n) => n.params.status),
    ['running', 'idle', 'running', 'idle'])
  assert.equal(emitted.mock.calls.filter((c) => c.arguments[0].type === 'usage/call').length, 2)
  assert.equal(emitted.mock.calls.filter((c) => c.arguments[0].type === 'usage/end').length, 2)
  assert.equal(daemon.usage.report({ range: 'all' }).total.turns, 2)
  assert.equal(daemon.usage.report({ range: 'all' }).total.tokens, 28)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'claude-task-done'
    && b.notice.args?.description === 'Fixture background command'
    && b.notice.args.status === 'completed' && b.notice.args.summary === 'Fixture finished'
    && b.notice.args.autonomous === true))
  assert.deepEqual(session.info.backgroundTasks, [])
})

test('hibernate waits for background work and the wake gap, then rearms after the autonomous turn', async (t) => {
  const { session, client, send, daemon } = await setup(t)
  // Production config uses whole seconds; use a shorter interval in this test.
  daemon.configuration.value.sessions.hibernateAfter = 0.04
  await send('background')
  await session.hibernate()
  assert.equal(session.backend.alive(), true, 'explicit hibernate is also guarded')
  await delay(120)
  assert.equal(session.backend.alive(), true, 'idle timer cannot kill a background task')
  await client.waitFor((n) => n.method === 'info' && n.params.info.backgroundTasks?.length === 0)
  await delay(100)
  assert.equal(session.backend.alive(), true, 'idle timer cannot kill a waking process')
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  await until(() => !session.backend.alive())
  assert.equal(session.status, 'idle')
  assert.equal(session.pendingWork(), false)
})

test('ambient tasks do not block hibernation', async (t) => {
  const { session, send } = await setup(t)
  await send('background-ambient')
  assert.equal(session.pendingWork(), false)
  assert.equal((session.info.backgroundTasks as unknown[]).length, 1)
  await session.hibernate()
  assert.equal(session.backend.alive(), false)
  assert.deepEqual(session.info.backgroundTasks, [])
})

for (const stop of [true, false]) test(`background state clears on ${stop ? 'stop' : 'process exit'}`, async (t) => {
  const { session, client, id, send } = await setup(t)
  await send('background')
  if (stop) await client.request('session/stop', { id })
  else {
    await client.request('session/send', { id, text: 'exit' })
    await until(() => session.status === 'exited')
  }
  assert.equal(session.pendingWork(), false)
  assert.deepEqual(session.info.backgroundTasks, [])
})

test('missing autonomous wake expires after fifteen seconds and rearms hibernation', async (t) => {
  const { session, send, client, daemon } = await setup(t)
  daemon.configuration.value.sessions.hibernateAfter = 0.04
  const hibernate = t.mock.method(session, 'hibernate')
  t.mock.timers.enable({ apis: ['setTimeout'] })
  try {
    await send('background-no-wake')
    await client.waitFor((n) => n.method === 'info' && n.params.info.backgroundTasks?.length === 0)
    assert.equal(session.pendingWork(), true)
    t.mock.timers.tick(14999)
    assert.equal(session.pendingWork(), true)
    t.mock.timers.tick(1)
    assert.equal(session.pendingWork(), false)
    t.mock.timers.tick(40)
    assert.equal(hibernate.mock.callCount(), 1, 'wake timeout rearms the idle timer')
    await hibernate.mock.calls[0].result
    assert.equal(session.backend.alive(), false)
  } finally { t.mock.timers.reset() }
})

test('prepare defers tool-set and external-source restarts once while background work is pending', async (t) => {
  const { session, client, file, calls, send } = await setup(t)
  await send('background')
  await appendFile(file, JSON.stringify({ type: 'user', uuid: 'external-background', entrypoint: 'cli', message: { content: 'external change' } }) + '\n')
  client.notify('editor/tools', { tools: editorTools.tools, readOnly: [] })
  await send('during background')
  await send('still during background')
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 1)
  assert.equal(session.blocks.filter((b) => b.type === 'notice' && b.notice.kind === 'claude-restart-deferred').length, 1)
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  await until(() => session.status === 'idle' && !session.pendingWork())
  await send('after background')
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 2)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'restart-for-external'))
})

for (const duringTurn of [false, true]) test(`effort restart waits for tasks and the wake turn (configured ${duringTurn ? 'during turn' : 'idle'})`, async (t) => {
  const { session, client, id, calls, send } = await setup(t)
  await send('background')
  if (duringTurn) {
    await client.request('session/send', { id, text: 'hold' })
    await until(() => session.status === 'running')
  }
  await client.request('session/configure', { id, effort: 'high' })
  if (duringTurn) {
    await client.request('session/interrupt', { id })
    await until(() => session.status === 'idle')
  }
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 1)
  await client.waitFor((n) => n.method === 'info' && n.params.info.backgroundTasks?.length === 0)
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 1, 'no restart in wake gap')
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  await until(async () => session.status === 'idle' && (await calls()).filter((c) => c.type === 'spawn').length === 2)
  const spawned = (await calls()).filter((c) => c.type === 'spawn').at(-1)
  assert.equal(spawned.argv[spawned.argv.indexOf('--effort') + 1], 'high')
})

test('a send in the wake gap keeps the guard for a deferred effort restart', async (t) => {
  const { session, client, id, calls, send } = await setup(t)
  await send('background-slow-wake')
  await client.waitFor((n) => n.method === 'info' && n.params.info.backgroundTasks?.length === 0)
  await client.request('session/configure', { id, effort: 'high' })
  await send('in the wake gap')
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 1, 'user turn end does not restart before the wake')
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  await until(async () => session.status === 'idle' && (await calls()).filter((c) => c.type === 'spawn').length === 2)
})

test('prepare during an autonomous turn defers a pending restart', async (t) => {
  const { session, client, id, calls, send } = await setup(t)
  await send('background-slow-wake')
  await client.request('session/configure', { id, effort: 'high' })
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'FINISHED')
  assert.equal(session.status, 'running')
  assert.equal(session.pendingWork(), false, 'the wake guard ends when the autonomous turn starts')
  // A send prepared in the wake gap can see the autonomous turn begin meanwhile.
  await session.backend.prepare!()
  assert.equal((await calls()).filter((c) => c.type === 'spawn').length, 1)
  await until(async () => session.status === 'idle' && (await calls()).filter((c) => c.type === 'spawn').length === 2)
})

const transcript = (count: number) => Array.from({ length: count }, (_, i) => [
  { type: 'user', uuid: `u${i}`, message: { content: `prompt ${i}` } },
  { type: 'assistant', uuid: `a${i}`, message: { content: [{ type: 'thinking', thinking: 'not displayed' }, { type: 'text', text: `reply ${i}` }] } },
].map((e) => JSON.stringify(e)).join('\n')).join('\n') + '\n'

test('launch flags, daemon MCP, skills, choices and child lifetime', async (t) => {
  const { calls, daemon, id, attached } = await setup(t, { parent: 'parent', settings: { model: 'haiku', effort: 'low', mode: 'auto' },
    skills: { skillsDir: '/tmp/skills', supersededSkills: ['atomic-review'] } })
  const argv = (await calls()).find((m) => m.type === 'spawn').argv
  const value = (s: string) => argv[argv.indexOf(s) + 1]
  assert.equal(value('--permission-mode'), 'auto')
  assert.equal(value('--permission-prompt-tool'), 'stdio')
  assert.equal(value('--allowedTools'), 'mcp__emacs__context,mcp__emacs__session_read,mcp__emacs__sessions')
  assert.equal(argv.at(-2), '--allowedTools')
  assert.equal(value('--disallowedTools'), 'Agent,Workflow,SendMessage,ListAgents')
  assert.equal(value('--model'), 'haiku'); assert.equal(value('--effort'), 'low')
  assert.ok(argv.includes('--no-session-persistence'))
  assert.equal(value('--add-dir'), '/tmp/skills')
  assert.deepEqual(JSON.parse(value('--settings')), { skillOverrides: { 'atomic-review': 'off' } })
  const server = JSON.parse(value('--mcp-config')).mcpServers.emacs
  assert.equal(server.command, process.execPath)
  assert.match(server.args[0], /\/bin\/emx$/)
  assert.deepEqual(server.env, { EMX_DAEMON_SOCKET: daemon.socket, EMX_SESSION: id })
  assert.deepEqual(attached.capabilities.modes, ['ask', 'edits', 'auto', 'full', 'plan'])
  assert.deepEqual(attached.capabilities.models[0].efforts, ['low', 'high'])
})

test('stream thinking, text and complete tool arguments/results; exclude subagents; usage deltas', async (t) => {
  const { send, session, daemon } = await setup(t)
  for (let i = 0; i < 2; i++) {
    const events = await send('hello')
    assert.deepEqual(daemon.usage.report({range: 'all'}).total, { input: 2 * (i + 1), cache_read: 3 * (i + 1), cache_write: 4 * (i + 1), output: 5 * (i + 1), turns: i + 1, child_turns: 0, tokens: 14 * (i + 1) })
  }
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.kind === 'thinking' && b.text === 'consider' && b.done))
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === 'hello' && b.done))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.command === 'echo hi\necho bye' && b.output === 'hi\n' && b.status === 'done'))
  assert.ok(!session.blocks.some((b) => b.type === 'text' && b.text.includes('hidden')))
  await send('error')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.args?.message === 'fixture error'))
})

test('permissions echo raw nested JSON and always suggestions; question answers keep original input', async (t) => {
  const { client, id, calls } = await setup(t)
  for (const text of ['approval', 'question']) {
    const from = client.notifications.length
    await client.request('session/send', { id, text })
    const event = await client.waitFor((e) => e.method === 'ask/add', 5000, text, from)
    if (text === 'approval') {
      assert.deepEqual(event.params.ask.choices, ['allow', 'always', 'deny'])
      assert.equal(event.params.ask.view.command, 'echo hi')
      await client.request('session/answer', { id, ask: event.params.ask.id, choice: 'always' })
    } else {
      assert.equal(event.params.ask.questions[0].multi, true)
      await client.request('session/answer', { id, ask: event.params.ask.id, answers: [{ selected: ['one'], custom: 'custom' }] })
    }
    await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'answered', from)
  }
  const responses = (await calls()).filter((m) => m.type === 'control_response').map((m) => m.response.response)
  assert.deepEqual(responses[0], { behavior: 'allow', updatedInput: { command: 'echo hi', preserve: { f: false, t: true, n: null, a: [], o: {}, unicode: '你好' } },
    updatedPermissions: [{ type: 'addRules', rules: [], value: false, destination: 'session' }] })
  assert.deepEqual(responses[1].updatedInput.untouched, { false: false, empty: [], nil: null })
  assert.deepEqual(responses[1].updatedInput.answers, { Pick: ['one', 'custom'] })
})

test('live model and modes; idle effort restart and deferred effort restart before queued send', async (t) => {
  const { client, id, calls, send } = await setup(t)
  await send('hello')
  await client.request('session/configure', { id, model: 'haiku', mode: 'full' })
  const controls = (await calls()).filter((m) => m.type === 'control_request').map((m) => m.request)
  assert.ok(controls.some((m) => m.subtype === 'set_model' && m.model === 'haiku'))
  assert.ok(controls.some((m) => m.subtype === 'set_permission_mode' && m.mode === 'bypassPermissions'))
  await client.request('session/configure', { id, effort: 'high' })
  let spawns = (await calls()).filter((m) => m.type === 'spawn')
  assert.equal(spawns.length, 2)
  assert.ok(spawns[1].argv.includes('--resume'))
  assert.equal(spawns[1].argv[spawns[1].argv.indexOf('--effort') + 1], 'high')
  await client.request('session/send', { id, text: 'hold' })
  await client.request('session/configure', { id, effort: 'low' })
  assert.equal((await calls()).filter((m) => m.type === 'spawn').length, 2)
  await client.request('session/send', { id, text: 'queued' })
  const from = client.notifications.length
  await client.request('session/interrupt', { id })
  await client.waitFor((e) => e.method === 'block/append' && e.params.text === 'queued', 5000, 'queued after restart', from)
  spawns = (await calls()).filter((m) => m.type === 'spawn')
  assert.equal(spawns.length, 3)
  assert.equal(spawns[2].argv[spawns[2].argv.indexOf('--effort') + 1], 'low')
})

test('child effort changes report a notice without losing conversation; steering and cancellation', async (t) => {
  const { client, id, calls, session } = await setup(t, { parent: 'parent' })
  await client.request('session/configure', { id, effort: 'high' })
  assert.equal((await calls()).filter((m) => m.type === 'spawn').length, 1)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'claude-child-effort'))
  await client.request('session/send', { id, text: 'hold' })
  const from = client.notifications.length
  assert.deepEqual(await client.request('session/steer', { id, text: 'steer', block: 'steered' }), { accepted: true })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'steer', from)
  assert.ok(session.index.has('steered'))
  await client.request('session/send', { id, text: 'approval' })
  const ask = await client.waitFor((e) => e.method === 'ask/add')
  await client.request('session/interrupt', { id })
  await client.waitFor((e) => e.method === 'ask/remove' && e.params.id === ask.params.ask.id)
})

test('usage totals prove fresh, continued, stale and forgotten baselines', () => {
  const u = (input: number, output = 0): Usage => ({ input, output, cacheRead: 0, cacheWrite: 0 })
  const tracker = new ClaudeTotals()
  assert.deepEqual(tracker.deltas({ opus: u(100, 20), helper: u(10, 2) }, u(110, 22)), { opus: u(100, 20), helper: u(10, 2) })
  assert.deepEqual(tracker.deltas({ opus: u(120, 22), helper: u(10, 2) }, u(20, 2)), { opus: u(20, 2) })
  tracker.newProcess()
  assert.deepEqual(tracker.deltas({ opus: u(130, 23), helper: u(10, 2) }, u(10, 1)), { opus: u(10, 1) })
  tracker.newProcess()
  assert.equal(tracker.deltas({ opus: u(120, 25) }, u(10, 1)), undefined)
  assert.deepEqual(tracker.deltas({ opus: u(130, 26) }, u(10, 1)), { opus: u(10, 1) })
  tracker.forget()
  assert.equal(tracker.deltas({ opus: u(900, 90) }, u(10, 1)), undefined)
  tracker.newProcess()
  assert.deepEqual(tracker.deltas({ opus: u(10, 1) }, u(10, 1)), { opus: u(10, 1) })
})

test('resumed file pages into earlier turns beyond daemon transcript, without usage replay', async (t) => {
  const { client, id, session, attached } = await setup(t, { resume: 'saved' }, transcript(25))
  assert.equal(attached.earlier, true)
  assert.equal(session.blocks[0].id, 'u5')
  assert.equal(session.log.some((e) => e.type === 'usage/call'), false)
  assert.deepEqual(await client.request('session/earlier', { id, before: 'u5', turns: 3 }), { earlier: true })
  assert.equal(session.blocks[0].id, 'u2')
  assert.deepEqual(await client.request('session/earlier', { id, before: 'u2', turns: 3 }), { earlier: false })
  assert.equal(session.blocks[0].id, 'u0')
  assert.ok(session.blocks.some((b) => b.id === 'a0-1' && b.type === 'text' && b.text === 'reply 0'))
})

test('large transcript streaming excludes bookkeeping and leaves a partial last line', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'claude-large-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const file = join(dir, 'large.jsonl')
  await writeFile(file, transcript(1))
  const junk = JSON.stringify({ type: 'progress', data: 'x'.repeat(256 * 1024) }) + '\n'
  for (let i = 0; i < 100; i++) await appendFile(file, junk)
  await appendFile(file, transcript(2))
  await appendFile(file, '{"type":"user"')
  const page = await historyPage(file, dir, 1)
  assert.deepEqual(page.blocks.map((b) => b.id), ['u1', 'a1-1'])
  let count = 0
  for await (const _ of entries(file)) count++
  assert.equal(count, 106)
})

test('external client follow debounces and restarts with resume before next send', async (t) => {
  const { client, session, file, calls, send, daemon } = await setup(t)
  await send('hello')
  await appendFile(file, JSON.stringify({ type: 'user', uuid: 'external', entrypoint: 'claude-desktop', message: { content: 'outside' } }) + '\n')
  await client.waitFor((e) => e.method === 'block/add' && e.params.block.id === 'external', 5000, 'external follow')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'claude-external-source'))
  const events = await send('after-external')
  assert.deepEqual(daemon.usage.report({range: 'all'}).total.tokens,
    28, 'external totals must be forgotten before resuming')
  const messages = await calls()
  const spawn = messages.findLastIndex((m) => m.type === 'spawn')
  const prompt = messages.findIndex((m) => m.type === 'user' && m.message.content === 'after-external')
  assert.ok(spawn < prompt)
  assert.ok(messages[spawn].argv.includes('--resume'))
  assert.equal(messages.filter((m) => m.type === 'spawn').length, 2)
})

test('rate limit readings, crash, restart and resume', async (t) => {
  const { client, id, session, send, calls, daemon } = await setup(t)
  const events = await send('rate')
  assert.deepEqual(daemon.usage.quotas[0].windows.map(({id, minutes, used, resets}) => ({id, minutes, used, resets})),
    [{ id: 'five_hour', minutes: 300, used: 0.3, resets: 1234 }, { id: 'seven_day_opus', minutes: 10080, used: 0.7, resets: 5678 }])
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'exit' })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'exited', 5000, 'crash', from)
  assert.equal(session.backend.alive(), false)
  await send('after-crash')
  const argv = (await calls()).findLast((m) => m.type === 'spawn').argv
  assert.equal(argv[argv.indexOf('--resume') + 1], 'fixture-native')
  await assert.rejects(client.request('session/open', { agent: 'claude', root: '/rpc:host:/tmp' }), /local absolute root/)
  await assert.rejects(client.request('session/open', { agent: 'claude', root: '/tmp', fork: id }), /forks are not supported/)
})

test('tool views preserve diffs, plan items and result text', () => {
  assert.equal(toolView('/root', 'Read', { file_path: '/root/f' }).path, 'f')
  assert.equal(toolView('/root', 'MultiEdit', { file_path: '/root/f', edits: [{ old_string: 'a\n', new_string: 'b\n' }, { old_string: 'c', new_string: 'd' }] }).diff,
    '--- f\n+++ f\n-a\n+b\n--- f\n+++ f\n-c\n+d')
  assert.deepEqual(toolView('/', 'TodoWrite', { todos: [{ content: 'step', status: 'completed' }] }).items, [{ text: 'step', status: 'done' }])
  assert.equal(toolView('/', 'mcp__emacs__context', {}).title, 'emacs · context')
  assert.equal(resultText([{ text: 'one' }, { text: 'two' }]), 'one\ntwo')
  assert.equal(encodePath('/a b_c/汉字/'), '-a-b-c-汉字')
})

test('historical fixtures preserve tool diffs/results, queued prompts, image counts and indices', async () => {
  const file = fileURLToPath(new URL('./fixtures/claude-history.jsonl', import.meta.url))
  const page = await historyPage(file, '/root', 20)
  assert.equal(page.start, 0)
  assert.deepEqual(page.blocks.map((b) => b.id), ['first', 'answer-1', 'edit-old', 'queued', 'image', 'last-0'])
  const tool = page.blocks.find((b) => b.id === 'edit-old')!
  assert.ok(tool.type === 'tool' && tool.view.diff?.includes('+new') && tool.output === 'updated')
  const image = page.blocks.find((b) => b.id === 'image')!
  assert.ok(image.type === 'user' && image.imageCount === 1 && image.text === 'image prompt')
})

test('a resumed process reports its own usage when restored model totals are unknown', async (t) => {
  const { send, daemon } = await setup(t, { resume: 'saved' })
  let turns = 0
  for (const text of ['first resumed turn', 'next turn']) {
    const events = await send(text)
    assert.equal(daemon.usage.report({range: 'all'}).total.tokens, 14 * ++turns)
  }
})

test('denied approvals retain declined tool status; image content is sent as base64', async (t) => {
  const { client, id, session, dir, calls } = await setup(t)
  await client.request('session/send', { id, text: 'approval' })
  const ask = await client.waitFor((e) => e.method === 'ask/add')
  await client.request('session/answer', { id, ask: ask.params.ask.id, choice: 'deny' })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle')
  assert.equal(session.index.get('ask-tool')?.type, 'tool')
  assert.equal((session.index.get('ask-tool') as any).status, 'declined')
  const image = join(dir, 'image.png')
  await writeFile(image, 'fixture-image-bytes')
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'image', images: [image] })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'image turn', from)
  const message = (await calls()).filter((m) => m.type === 'user').at(-1).message
  assert.deepEqual(message.content, [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: Buffer.from('fixture-image-bytes').toString('base64') } }, { type: 'text', text: 'image' }])
})

test('cached quota is republished on fresh attach without replaying usage', async (t) => {
  const { send, client, id } = await setup(t)
  await send('rate')
  const from = client.notifications.length
  await client.request('session/attach', { id })
  await client.waitFor((e) => e.method === 'usage/quotas', 5000, 'cached quota', from)
  assert.equal(client.notifications.slice(from).some((e) => e.method === 'usage/call'), false)
})

test('daemon configuration overrides disallowed tools, extra arguments and initial history turns', async (t) => {
  const { calls, session } = await setup(t, { resume: 'configured' }, transcript(25), {
    disallowedTools: ['Agent', 'Task'], extraArgs: ['--fixture-extra'], historyTurns: 2,
  })
  const argv = (await calls()).find((m) => m.type === 'spawn').argv
  assert.equal(argv[argv.indexOf('--disallowedTools') + 1], 'Agent,Task')
  assert.ok(argv.includes('--fixture-extra'))
  assert.equal(session.blocks[0].id, 'u23')
})

test('cancelled AskUserQuestion is denied, not allowed with empty answers', async (t) => {
  const { client, id, calls } = await setup(t)
  await client.request('session/send', { id, text: 'question' })
  const ask = await client.waitFor((e) => e.method === 'ask/add')
  await client.request('session/answer', { id, ask: ask.params.ask.id })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle')
  const response = (await calls()).find((m) => m.type === 'control_response').response.response
  assert.deepEqual(response, { behavior: 'deny', message: 'The user declined to answer these questions.' })
})

test('pipelined configure, steer and interrupt reserve and follow a preparing send', async (t) => {
  const { client, id, calls } = await setup(t)
  // Send and configure in one socket burst, before async preflight can finish.
  const sending = client.request('session/send', { id, text: 'hold' })
  const configuring = client.request('session/configure', { id, effort: 'high' })
  await Promise.all([sending, configuring])
  assert.equal((await calls()).filter((m) => m.type === 'spawn').length, 1,
    'effort must wait for the turn even while preparing its first message')
  const from = client.notifications.length
  await client.request('session/interrupt', { id })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'deferred restart', from)
  const prompts = (await calls()).filter((m) => m.type === 'user' || m.type === 'control_request' && m.request.subtype === 'interrupt')
  assert.equal(prompts[0].type, 'user')
  assert.equal(prompts[1].request.subtype, 'interrupt')
  const next = client.notifications.length
  const held = client.request('session/send', { id, text: 'hold' })
  const steered = client.request('session/steer', { id, text: 'after-hold' })
  assert.deepEqual(await steered, { accepted: true })
  await held
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'ordered steer', next)
  assert.deepEqual((await calls()).filter((m) => m.type === 'user').slice(-2).map((m) => m.message.content), ['hold', 'after-hold'])
})


test('send during an idle effort restart waits for the single replacement process', async (t) => {
  // Run this cleanup before setup removes the fixture log.
  let fixtureCalls = async (): Promise<any[]> => []
  t.after(async () => {
    for (const { pid } of (await fixtureCalls()).filter((m) => m.type === 'spawn')) {
      try { process.kill(pid, 'SIGKILL') } catch { /* Already reaped. */ }
    }
  })
  const { client, id, calls, session } = await setup(t, {}, undefined, { extraArgs: ['--fixture-delay-exit'] })
  fixtureCalls = calls
  await client.request('session/send', { id, text: 'hello' })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle')
  const configuring = client.request('session/configure', { id, effort: 'high' })
  for (let i = 0; !(await calls()).some((m) => m.type === 'terminating'); i++) {
    assert.ok(i < 200, 'old process must enter delayed termination')
    await delay(5)
  }
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'hold', block: 'racing-send' })
  await configuring
  for (let i = 0; !(await calls()).some((m) => m.type === 'user' && m.message.content === 'hold'); i++) {
    assert.ok(i < 200, 'message must reach the replacement')
    await delay(5)
  }
  const messages = await calls()
  const spawns = messages.filter((m) => m.type === 'spawn')
  assert.equal(spawns.length, 2, 'one original and exactly one replacement')
  const live = spawns.filter(({ pid }) => { try { process.kill(pid, 0); return true } catch { return false } })
  assert.equal(live.length, 1, 'no unmanaged live process')
  const delivered = messages.filter((m) => m.type === 'user' && m.message.content === 'hold')
  assert.equal(delivered.length, 1)
  assert.equal(delivered[0].pid, live[0].pid)
  assert.equal(session.blocks.filter((b) => b.id === 'racing-send').length, 1)
  await client.request('session/interrupt', { id })
  await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'managed replacement interrupt', from)
})


test('partial configure failure keeps the acknowledged model and rolls back the rejected mode', async (t) => {
  const { client, id, calls, session } = await setup(t,
    { settings: { model: 'sonnet', mode: 'ask', effort: 'low' } }, undefined,
    { extraArgs: ['--fixture-reject-mode'] })
  await assert.rejects(client.request('session/configure', { id, model: 'haiku', mode: 'full' }), /fixture mode rejected/)
  assert.deepEqual(session.settings, { model: 'haiku', mode: 'ask', effort: 'low' })
  assert.equal(session.info.model, 'haiku')
  const rollback = session.log.findLast((e) => e.type === 'settings')!
  assert.equal(rollback.type === 'settings' && rollback.settings.model, 'haiku')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.level === 'error'
    && b.notice.args?.message?.toString().includes('fixture mode rejected')))
  const attached = await client.request('session/attach', { id })
  assert.equal(attached.settings.model, attached.info.model)
  await client.request('session/configure', { id, model: 'sonnet' })
  const models = (await calls()).filter((m) => m.type === 'control_request' && m.request.subtype === 'set_model')
  assert.deepEqual(models.map((m) => m.request.model), ['haiku', 'sonnet'], 'choosing the old model must reach the CLI')
  assert.equal(session.info.model, 'sonnet')
})


test('permission responses preserve input and suggestions byte for byte', async (t) => {
  const { client, id, calls } = await setup(t)
  const input = (await readFile(new URL('./fixtures/claude-input.json', import.meta.url), 'utf8')).trim()
  const suggestions = (await readFile(new URL('./fixtures/claude-permissions.json', import.meta.url), 'utf8')).trim()
  for (const text of ['raw-approval', 'raw-question']) {
    const from = client.notifications.length
    await client.request('session/send', { id, text })
    const event = await client.waitFor((e) => e.method === 'ask/add', 5000, text, from)
    if (text === 'raw-approval') {
      assert.equal(event.params.ask.view.command, 'echo hi', 'display still uses parsed input')
      await client.request('session/answer', { id, ask: event.params.ask.id, choice: 'always' })
    } else {
      await client.request('session/answer', { id, ask: event.params.ask.id, answers: [{ selected: ['one'] }] })
    }
    await client.waitFor((e) => e.method === 'status' && e.params.status === 'idle', 5000, 'raw permission reply', from)
  }
  const responses = (await calls()).filter((m) => m.type === 'raw-response').map((m) => m.line)
  assert.equal(responses[0], '{"type":"control_response","response":{"subtype":"success","request_id":"raw-permission","response":'
    + '{"behavior":"allow","updatedInput":' + input + ',"updatedPermissions":' + suggestions + '}}}')
  assert.ok(responses[1].includes('"updatedInput":' + input.slice(0, -1) + ',"answers":{"Pick":"one"}}'),
    'question answers must preserve every original input byte except the closing brace')
})


test('raw JSON spans handle escaped keys, duplicate fields and all value types', () => {
  const values = ['false', 'null', '-0', '9007199254740993', '[]', '{}',
    String.raw`"\u4f60\" } , : ["`, String.raw`[{"2":-0,"1":9007199254740993}, [null, false]]`]
  for (const value of values) {
    const json = String.raw` { "other": {"input": "decoy"}, "\u0069nput" : ${value} , "end": [1, 2] } `
    JSON.parse(json)
    assert.equal(rawJsonField(json, 'input'), value)
  }
  assert.equal(rawJsonField('{"input":false,"input": -0}', 'input'), '-0')
  assert.equal(rawJsonField('{}', 'input'), undefined)
  assert.equal(rawJsonField('[]', 'input'), undefined)
})

for (const child of [false, true]) test('claude snapshots read-only approvals; removal restarts only persistent sessions (' + child + ')', async (t) => {
  const { client, id, session, send, calls } = await setup(t, child ? { parent: 'parent' } : {})
  const before = (await calls()).filter((r) => r.type === 'spawn')
  const allowed = (argv: string[]) => argv[argv.indexOf('--allowedTools') + 1].split(',')
  assert.ok(allowed(before[0].argv).includes('mcp__emacs__context'))
  client.notify('editor/tools', { ...editorTools, readOnly: [...editorTools.readOnly].reverse() })
  await send('same-set')
  assert.equal((await calls()).filter((r) => r.type === 'spawn').length, 1)
  // Change classification alone, leaving every tool definition byte-for-byte intact.
  client.notify('editor/tools', { tools: editorTools.tools, readOnly: [] })
  await send('after-removal')
  const log = await calls(), starts = log.filter((r) => r.type === 'spawn')
  assert.equal(starts.length, child ? 1 : 2)
  const sent = log.find((r) => r.type === 'user' && r.message.content === 'after-removal')
  assert.equal(sent.pid, starts.at(-1).pid)
  assert.equal(allowed(starts.at(-1).argv).includes('mcp__emacs__context'), child)
  if (!child) {
    assert.notEqual(starts[0].pid, starts[1].pid)
    assert.ok(starts[1].argv.includes('--resume'))
    assert.equal(starts[1].argv[starts[1].argv.indexOf('--resume') + 1], session.resumeId())
    await send('same-classification')
    assert.equal((await calls()).filter((r) => r.type === 'spawn').length, 2)
  }
})

test('delegating Claude sessions auto-allow session_rate in plan mode', async (t) => {
  const { calls, session } = await setup(t, { settings: { mode: 'plan' } })
  const argv = (await calls()).find((m) => m.type === 'spawn').argv
  assert.ok(argv[argv.indexOf('--allowedTools') + 1].split(',').includes('mcp__emacs__session_rate'))
  assert.ok(session.editorTools().readOnly.includes('session_rate'))
})
