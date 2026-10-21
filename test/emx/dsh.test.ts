// dsh.test.ts --- local bridge adapter, exercised through a real daemon socket.
import * as assert from 'node:assert/strict'
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { diff, toolView } from '../../emx/backends/dsh.ts'
import { SocketClient } from './client.ts'
import type { OpenParams } from '../../emx/daemon/protocol.ts'

async function setup(t: TestContext, options: Partial<OpenParams> = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'emx-dsh-'))
  const executable = process.env.EMX_DSH_EXECUTABLE
  const log = process.env.EMX_DSH_LOG
  process.env.EMX_DSH_EXECUTABLE = fileURLToPath(new URL('./fixtures/dsh.mjs', import.meta.url))
  process.env.EMX_DSH_LOG = join(dir, 'bridge.jsonl')
  const daemon = new DaemonServer({ varDir: dir })
  let client: Awaited<ReturnType<typeof SocketClient.connect>>
  t.after(async () => {
    await daemon.stop()
    await client?.close()
    if (executable === undefined) delete process.env.EMX_DSH_EXECUTABLE
    else process.env.EMX_DSH_EXECUTABLE = executable
    if (log === undefined) delete process.env.EMX_DSH_LOG
    else process.env.EMX_DSH_LOG = log
    await rm(dir, { recursive: true, force: true })
  })
  await daemon.start()
  client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'dsh-test', version: daemon.version, tools: {
    tools: [{ name: 'context', description: 'Context', inputSchema: { type: 'object' } }], readOnly: ['context'] } })
  const { id } = await client.request('session/open', { agent: 'dsh', root: dir, ...options })
  const attached = await client.request('session/attach', { id })
  await client.waitFor((n) => n.method === 'history/done')
  const session = daemon.sessions.get(id)!
  const send = async (text: string) => {
    const from = client.notifications.length
    await client.request('session/send', { id, text, images: ['/tmp/image.png'], block: 'user-' + text })
    const running = await client.waitFor((n) => n.method === 'status' && n.params.status === 'running', 5000, 'running', from)
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle',
      5000, 'idle', client.notifications.indexOf(running) + 1)
    return client.notifications.slice(from)
  }
  const requests = async () => (await readFile(join(dir, 'bridge.jsonl'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line))
  return { dir, daemon, client, id, attached, session, send, requests }
}

test('initialize passes local launch, settings, parent and MCP; advertises choices', async (t) => {
  const { dir, daemon, id, attached, session, requests } = await setup(t, {
    settings: { model: 'fake/chat', effort: 'high', mode: 'auto' }, parent: 'parent' })
  const init = (await requests()).find((r) => r.method === 'initialize')
  assert.equal(init.cwd, await realpath(dir))
  assert.deepEqual(init.argv.slice(0, 3), ['--profile', 'sdk', '--patch'])
  assert.match(init.argv[3], /\/lisp\/agent\/backend\/dsh\/emacs.yml$/)
  assert.equal(init.argv[4], '--patch')
  assert.match(init.argv[5], /no-subagents.yml$/)
  const mcpServers = [{ name: 'emacs', command: process.execPath,
    args: [fileURLToPath(new URL('../../bin/emx', import.meta.url)), 'mcp'],
    env: { EMX_DAEMON_SOCKET: daemon.socket, EMX_SESSION: id }, timeoutMs: 1800000, readOnly: ['context'] }]
  assert.deepEqual(init.params, { cwd: dir, preset: 'auto', plan: false, mcpServers,
    parent: 'parent', model: 'fake/chat', effort: 'high' })
  assert.equal(session.resumeId(), 'fake-session')
  assert.deepEqual(attached.capabilities.modes, ['ask', 'edits', 'auto', 'full', 'plan'])
  assert.deepEqual(attached.capabilities.models[0].efforts, ['high'])
  assert.equal(attached.capabilities.commands[0].name, 'status')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'dsh-version'))
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'dsh-warning'))
})

test('streamed blocks, tool results, usage, balance, discard, errors and slash commands', async (t) => {
  const { send, session, client, requests, daemon } = await setup(t)
  const events = await send('hello')
  assert.equal(events.filter((n) => n.method === 'status' && n.params.status === 'running').length, 1)
  assert.deepEqual(events.filter((n) => n.method === 'block/append').map((n) => n.params.text), ['你', '好'])
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.kind === 'command' && b.status === 'done' && b.output === 'hi'))
  assert.equal(session.blocks.filter((b) => b.id === 'user-hello').length, 1)
  assert.equal(daemon.usage.report({range: 'all'}).total.tokens, 14)
  assert.equal(daemon.usage.report({range: 'all'}).total.turns, 1)
  const quota = await client.waitFor((n) => n.method === 'usage/quotas' && n.params.quotas.length)
  assert.deepEqual(quota.params.quotas[0].balance, [{ amount: 12.34, currency: 'CNY' }])
  await send('discard')
  assert.equal(session.index.has('discarded'), false)
  await send('error')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.args?.message === 'fixture failure'))
  assert.equal(session.blocks.filter((b) => b.type === 'notice' && b.notice.args?.message === 'fixture failure').length, 1)
  await send('end-error')
  assert.equal(session.blocks.filter((b) => b.type === 'notice' && b.notice.args?.message === 'fixture failure').length, 2)
  await send('max')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'max-tokens'))
  for (const cmd of ['/status', '/fail', '/empty']) await send(cmd)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'command-error'))
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'command-result' && !b.notice.args))
  assert.deepEqual((await requests()).find((r) => r.method === 'prompt').params.images, ['/tmp/image.png'])
})

test('approval/question answers preserve bridge ids, plan intent, feedback and settings', async (t) => {
  const { client, id, session, requests } = await setup(t, { settings: { mode: 'full' } })
  await client.request('session/configure', { id, mode: 'plan' })
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'approval' })
  let event = await client.waitFor((n) => n.method === 'ask/add', 5000, 'approval', from)
  assert.deepEqual(event.params.ask.choices, ['allow', 'deny'])
  await client.request('session/answer', { id, ask: event.params.ask.id, choice: 'allow' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
  for (const text of ['question', 'plan']) {
    const from = client.notifications.length
    await client.request('session/send', { id, text })
    event = await client.waitFor((n) => n.method === 'ask/add', 5000, text, from)
    assert.equal(event.params.ask.type, 'question')
    if (text === 'plan') assert.equal(event.params.ask.questions[0].intent.kind, 'plan-review')
    const answer = { selected: ['yes'], custom: 'feedback' }
    await client.request('session/answer', { id, ask: event.params.ask.id, answers: [answer] })
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
    assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === JSON.stringify({ answers: [{ id: 'q1', ...answer }] })))
  }
  assert.equal(session.settings.mode, 'full')
  const before = (await requests()).filter((r) => r.method === 'configure').length
  await client.request('session/configure', { id, mode: 'plan' })
  const configs = (await requests()).filter((r) => r.method === 'configure')
  assert.equal(configs.length, before + 1, 'plan mode can be entered again after its review')
  assert.equal(configs.at(-1).params.plan, true)
})

test('configure maps presets, keeps plan permissions, and changes model and effort', async (t) => {
  const { client, id, requests } = await setup(t)
  for (const mode of ['ask', 'edits', 'auto', 'full', 'plan']) {
    await client.request('session/configure', { id, mode, model: 'fake/chat', effort: 'low' })
  }
  const configs = (await requests()).filter((r) => r.method === 'configure')
  assert.deepEqual(configs.slice(-5).map((r) => r.params.preset),
    ['read-only', 'workspace-write', 'auto', 'danger-full-access', 'danger-full-access'])
  assert.equal(configs.at(-1).params.plan, true)
})

test('resume replays transcript once and excludes its usage; daemon MCP is rebuilt after restart', async (t) => {
  const { session, attached, client, id, dir, daemon, requests } = await setup(t, {
    resume: 'resume-id' })
  assert.equal(attached.info.title, 'Resumed')
  assert.equal(session.resumeId(), 'resume-id')
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.kind === 'thinking' && b.text === 'thought'))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.output === 'old output'))
  assert.equal(session.log.some((e) => e.type === 'usage/call'), false)
  assert.equal(client.notifications.some((e) => e.method === 'usage/call'), false)
  await daemon.persist()
  const records = JSON.parse(await readFile(join(dir, 'emx/sessions.json'), 'utf8'))
  assert.equal(records[0].mcpServers, undefined)
  await daemon.stop()
  await client.close()
  const restored = new DaemonServer({ varDir: dir })
  let peer: Awaited<ReturnType<typeof SocketClient.connect>> | undefined
  try {
    await restored.start()
    peer = await SocketClient.connect(restored.socket)
    await peer.request('hello', { client: 'restored', version: restored.version })
    const snapshot = await peer.request('session/attach', { id })
    assert.deepEqual(snapshot.capabilities, attached.capabilities)
    await peer.waitFor((n) => n.method === 'history/done')
    await peer.request('session/configure', { id, model: 'fake/restored', effort: 'low' })
    const from = peer.notifications.length
    await peer.request('session/send', { id, text: 'hello' })
    await peer.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'resumed turn', from)
    const resumed = restored.sessions.get(id)!
    assert.equal(resumed.blocks.filter((b) => b.id === 'old-user').length, 1)
    assert.equal(resumed.daemonSocket, restored.socket)
    assert.equal(resumed.info.model, 'fake/restored')
    assert.equal(resumed.settings.effort, 'low')
    const calls = await requests()
    assert.equal(calls.filter((r) => r.method === 'initialize').at(-1).params.resume, 'resume-id')
    assert.ok(calls.findLastIndex((r) => r.method === 'configure')
      < calls.findLastIndex((r) => r.method === 'prompt'))
  } finally {
    await restored.stop()
    await peer?.close()
  }
})

test('steering, interruption, queued turns and unexpected process exit settle correctly', async (t) => {
  const { client, id, session, send } = await setup(t)
  await client.request('session/send', { id, text: 'hold' })
  const from = client.notifications.length
  assert.deepEqual(await client.request('session/steer', { id, text: 'steered', block: 'steer' }), { accepted: true })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
  await client.request('session/send', { id, text: 'hold' })
  assert.deepEqual(await client.request('session/send', { id, text: 'queued' }), { queued: true })
  const next = client.notifications.length
  await client.request('session/interrupt', { id })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'queued turn', next + 1)
  await send('hello')
  const end = client.notifications.length
  await client.request('session/send', { id, text: 'exit' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'exited', 5000, 'exited', end)
  assert.equal(session.backend.alive(), false)
  assert.equal(session.asks.size, 0)
})

test('tool views match Lisp diffs, quiet plan data, paths and search titles', () => {
  assert.equal(diff('f', 'old\n', 'new\n'), '--- f\n+++ f\n-old\n+new')
  assert.deepEqual(toolView('/root', 'read', { path: '/root/a' }), { kind: 'read', name: 'read', title: 'a', path: 'a' })
  assert.equal(toolView('/root', 'edit', { path: 'a', old_string: 'a', new_string: 'b' }).diff, '--- a\n+++ a\n-a\n+b')
  assert.deepEqual(toolView('/', 'todo_write', { todos: [{ content: 'a', status: 'in_progress' }] }).items,
    [{ text: 'a', status: 'active' }])
  assert.equal(toolView('/', 'mcp__emacs__open', {}).title, 'emacs · open')
  assert.equal(toolView('/', 'web_search', { queries: ['a', 'b'] }).title, 'a · b')
})

test('remote roots fail before launching a process', async (t) => {
  const { client } = await setup(t)
  await assert.rejects(client.request('session/open', { agent: 'dsh', root: '/rpc:host:/tmp' }), /local absolute root/)

})

test('opening directly in plan mode retains the previous permission preset', async (t) => {
  const { requests, attached } = await setup(t, { settings: { mode: 'plan', beforePlan: 'full' } })
  const init = (await requests()).find((r) => r.method === 'initialize')
  assert.equal(init.params.preset, 'danger-full-access')
  assert.equal(init.params.plan, true)
  assert.equal(attached.settings.beforePlan, 'full')
})

test('successful edit results stay quiet, failed edits keep their output', async (t) => {
  const { session, send } = await setup(t)
  await send('edits')
  const edit = session.index.get('edit-1')
  const failed = session.index.get('failed-edit-1')
  assert.ok(edit?.type === 'tool' && edit.output === undefined && edit.view.diff?.includes('+new'))
  assert.ok(failed?.type === 'tool' && failed.output === 'edit failure' && failed.status === 'error')
})


test('restart after a crash resumes the latest native conversation', async (t) => {
  const { client, id, session, send, requests, dir, daemon } = await setup(t)
  const native = session.resumeId()
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'exit' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'exited', 5000, 'crash', from)
  await send('after-crash')
  const initializations = (await requests()).filter((r) => r.method === 'initialize')
  assert.equal(initializations.length, 2)
  assert.equal(initializations[1].params.resume, native)
  assert.ok(session.blocks.some((b) => b.type === 'user' && b.text === 'after-crash'))
  await daemon.persist()
  const saved = JSON.parse(await readFile(join(dir, 'emx/sessions.json'), 'utf8'))
  assert.equal(saved[0].resume, native, 'persistence uses the same latest native id')
  // stop/start is the same backend lifecycle as hibernation.
  await session.stop()
  await send('after-stop')
  assert.equal((await requests()).filter((r) => r.method === 'initialize').at(-1).params.resume, native)
})


test('resume reconciles model and effort chosen before the restored backend starts', async (t) => {
  const { session, client, id, requests, send } = await setup(t, {
    resume: 'saved-id', settings: { model: 'fake/new', effort: 'low' } })
  assert.equal(session.settings.model, 'fake/new')
  assert.equal(session.settings.effort, 'low')
  await session.stop()
  await client.request('session/configure', { id, model: 'fake/newer', effort: 'medium' })
  await send('pending-choices')
  const calls = await requests()
  const prompt = calls.findIndex((r) => r.method === 'prompt')
  const configure = calls.findLastIndex((r) => r.method === 'configure')
  assert.ok(configure < prompt, 'reconcile before sending the prompt')
  assert.deepEqual(calls[configure].params, { model: 'fake/newer', effort: 'medium' })
  assert.equal(session.info.model, 'fake/newer')
  assert.equal(session.settings.effort, 'medium')
})

test('failed configure restores confirmed settings, reports an error and permits retry', async (t) => {
  const { session, client, id, requests } = await setup(t)
  const confirmed = { ...session.settings }
  const from = client.notifications.length
  await assert.rejects(client.request('session/configure', {
    id, model: 'fake/retry', effort: 'low', mode: 'full' }), /fixture configure failure/)
  assert.deepEqual(session.settings, confirmed)
  assert.equal(session.info.model, confirmed.model)
  await client.waitFor((n) => n.method === 'settings' && n.params.settings.model === confirmed.model,
    5000, 'rollback', from)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.level === 'error'
    && b.notice.args?.message === 'fixture configure failure'))
  await client.request('session/configure', { id, model: 'fake/retry', effort: 'low', mode: 'full' })
  assert.equal((await requests()).filter((r) => r.method === 'configure').length, 2)
  assert.equal(session.settings.model, 'fake/retry')
  assert.equal(session.settings.effort, 'low')
  assert.equal(session.settings.mode, 'full')
})
