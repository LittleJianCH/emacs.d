// codex.test.ts --- app-server protocol, exercised through isolated daemon sockets.
import * as assert from 'node:assert/strict'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { developerInstructions, itemView, modes } from '../../emx/backends/codex.ts'
import type { OpenParams } from '../../emx/daemon/protocol.ts'
import { SocketClient } from './client.ts'

const editorTools = {
  tools: [{ name: 'context', description: 'Context', inputSchema: { type: 'object' } },
    { name: 'eval', description: 'Evaluate', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } }],
  readOnly: ['context', 'context', 'session_start', 'removed'],
}

async function setup(t: TestContext, options: Partial<OpenParams> = {}, badConfig = false, restartGate = false) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-codex-')))
  const keys = ['EMX_CODEX_EXECUTABLE', 'EMX_CODEX_LOG', 'EMX_CODEX_BAD_CONFIG', 'EMX_CODEX_CONFIG', 'EMX_CODEX_RESTART_GATE']
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]))
  process.env.EMX_CODEX_EXECUTABLE = fileURLToPath(new URL('./fixtures/codex.mjs', import.meta.url))
  process.env.EMX_CODEX_LOG = join(dir, 'rpc.jsonl')
  process.env.EMX_CODEX_CONFIG = '{}'
  if (restartGate) process.env.EMX_CODEX_RESTART_GATE = join(dir, 'restart-gate')
  else delete process.env.EMX_CODEX_RESTART_GATE
  if (badConfig) process.env.EMX_CODEX_BAD_CONFIG = '1'
  else delete process.env.EMX_CODEX_BAD_CONFIG
  await mkdir(join(dir, 'emx'), { recursive: true })
  await writeFile(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  const daemon = new DaemonServer({ varDir: dir })
  await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  t.after(async () => {
    await daemon.stop(); await client.close()
    for (const key of keys) { if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key] }
    await rm(dir, { recursive: true, force: true })
  })
  await client.request('hello', { client: 'codex-test', version: daemon.version,
    tools: editorTools })
  const { id } = await client.request('session/open', { agent: 'codex', root: dir, ...options })
  const attached = await client.request('session/attach', { id, turns: 1 })
  await client.waitFor((n) => n.method === 'history/done')
  const session = daemon.sessions.get(id)!
  const send = async (text: string) => {
    const from = client.notifications.length
    await client.request('session/send', { id, text, images: ['/tmp/image.png'], block: 'user-' + text })
    const running = await client.waitFor((n) => n.method === 'status' && n.params.status === 'running', 5000, 'running', from)
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', client.notifications.indexOf(running) + 1)
    return client.notifications.slice(from)
  }
  const requests = async () => (await readFile(join(dir, 'rpc.jsonl'), 'utf8')).trim().split('\n').map((s) => JSON.parse(s))
  return { dir, daemon, client, id, attached, session, send, requests }
}

test('Codex launches private daemon MCP, skill replacements, modes and instructions', async (t) => {
  const { id, daemon, dir, requests, attached } = await setup(t, {
    settings: { model: 'fake-cheap', effort: 'high', mode: 'auto' },
    skills: { skillsDir: '/tmp/skills', supersededSkills: ['atomic-review'] }, parent: 'parent' })
  const log = await requests(), init = log.find((r) => r.method === 'initialize')
  assert.equal(init.argv[0], 'app-server')
  const overrides = init.argv.filter((_: string, i: number) => init.argv[i - 1] === '-c')
  assert.equal(new Set(overrides.map((s: string) => s.split('=')[0])).size, overrides.length)
  assert.deepEqual(overrides.filter((s: string) => s.includes('.approval_mode=')), [
    'mcp_servers.emacs.tools.context.approval_mode="approve"',
    'mcp_servers.emacs.tools.session_read.approval_mode="approve"',
    'mcp_servers.emacs.tools.sessions.approval_mode="approve"',
  ])
  assert.ok(overrides.includes('agents.enabled=false'))
  assert.ok(overrides.includes('skills.config=[{name="atomic-review",enabled=false}]'))
  assert.ok(overrides.includes(`mcp_servers.emacs.env={EMX_DAEMON_SOCKET=${JSON.stringify(daemon.socket)},EMX_SESSION=${JSON.stringify(id)}}`))
  assert.ok(overrides.includes(`mcp_servers.emacs.command=${JSON.stringify(process.execPath)}`))
  assert.ok(overrides.some((s: string) => s.includes('/bin/emx","mcp"]')))
  assert.deepEqual(log.find((r) => r.method === 'skills/extraRoots/set').params, { extraRoots: ['/tmp/skills/.claude/skills'] })
  const start = log.find((r) => r.method === 'thread/start').params
  assert.equal(start.cwd, dir)
  assert.equal(start.ephemeral, true)
  assert.equal(start.sandbox, 'workspace-write')
  assert.equal(start.approvalPolicy, 'on-request')
  assert.match(start.developerInstructions, /^  User rules\.\n\n\nThis session is hosted/)
  assert.deepEqual(attached.capabilities.models.map((m) => m.id), ['fake-cheap'])
  assert.deepEqual(attached.capabilities.models[0].efforts, ['low', 'high'])
  assert.deepEqual(attached.capabilities.modes, Object.keys(modes))
})

test('Codex streams reasoning, commands, edits, MCP, plans, web and live-only deduplicated usage', async (t) => {
  const { send, session, client, daemon } = await setup(t)
  const events = await send('hi')
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.kind === 'thinking' && b.text === 'thinking' && b.done))
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === 'hi' && b.done))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.kind === 'command' && b.output === 'hi' && b.status === 'done'))
  assert.ok(events.some((n) => n.method === 'block/append' && n.params.text === 'h'))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.kind === 'mcp' && b.output === 'context result'))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.items?.[0].status === 'active'))
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.kind === 'web' && b.view.title === 'query'))
  assert.ok(!session.index.has('foreign'))
  const report = await client.request('usage/report', {range: 'all'})
  assert.deepEqual(report.total, {input: 10, cache_read: 3, cache_write: 2, output: 5, turns: 1, child_turns: 0, tokens: 20})
  assert.equal(events.some((n) => ['usage/call', 'usage/end'].includes(n.method)), false)
  assert.deepEqual(await client.request('session/steer', { id: session.id, text: 'idle' }), { accepted: false })
  const quota = await client.waitFor((n) => n.method === 'usage/quotas' && n.params.quotas.some((q: any) => q.credits === 'unlimited'))
  assert.equal(quota.params.quotas[0].credits, 'unlimited')
  assert.equal(daemon.usage.quotas[0].windows[0].used, 0.25)
  const initial = client.notifications.find((n) => n.method === 'usage/quotas' && n.params.quotas.some((q: any) => q.credits === 12.5))
  assert.ok(initial)
  await send('multi-usage')
  assert.equal(daemon.usage.report({range: 'all'}).total.turns, 2)
  assert.equal(daemon.usage.report({range: 'all'}).total.tokens, 60)
  await send('reroute')
  assert.equal(session.info.model, 'rerouted')
})

test('Codex live user echoes reuse client blocks; repeated items update and history stays visible', async (t) => {
  const { send, session, client, id } = await setup(t, { resume: 'fake-thread' })
  assert.equal(session.blocks.filter((b) => b.type === 'user').length, 3)
  const userAdds: string[] = [], addBlock = session.addBlock.bind(session)
  session.addBlock = (block, before) => {
    if (block.type === 'user') userAdds.push(block.id)
    addBlock(block, before)
  }
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'smoke', block: 'u-smoke', images: ['/tmp/image.png'] })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'smoke idle', from)
  const users = session.blocks.filter((b) => b.type === 'user' && !b.id.startsWith('old-'))
  assert.deepEqual(users, [{ id: 'u-smoke', type: 'user', text: 'smoke', images: ['/tmp/image.png'] }])
  assert.deepEqual(client.notifications.slice(from).filter((n) => n.method === 'block/add' && n.params.block.type === 'user')
    .map((n) => n.params.block.id), ['u-smoke'])
  // Equal text on a later turn is a new message, with its own client id.
  await send('smoke')
  assert.equal(session.blocks.filter((b) => b.type === 'user' && b.text === 'smoke').length, 2)
  const events = await send('external-user')
  const external = events.filter((n) => n.method === 'block/add' && n.params.block.id.startsWith('external-'))
  assert.equal(external.length, 1)
  const externalId = external[0].params.block.id
  assert.deepEqual(userAdds, ['u-smoke', 'user-smoke', 'user-external-user', externalId])
  assert.ok(events.some((n) => n.method === 'block/update' && n.params.id === externalId && n.params.fields.text === 'external message'))
  assert.ok(session.blocks.some((b) => b.id === externalId && b.type === 'user' && b.text === 'external message'))
})

test('Codex approvals show file diffs and commands, all decisions and question ids survive', async (t) => {
  const { client, id, session } = await setup(t)
  for (const choice of ['allow', 'always', 'deny'] as const) {
    const from = client.notifications.length
    await client.request('session/send', { id, text: 'file-approval' })
    const event = await client.waitFor((n) => n.method === 'ask/add', 5000, 'file ask', from)
    assert.equal(event.params.ask.view.diff, '--- /dev/null\n+++ a\n+new')
    await client.request('session/answer', { id, ask: event.params.ask.id, choice })
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
    const decision = choice === 'allow' ? 'accept' : choice === 'always' ? 'acceptForSession' : 'decline'
    assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === JSON.stringify({ decision })))
    const edits = session.blocks.filter((b) => b.type === 'tool' && b.view.kind === 'edit')
    assert.equal((edits.at(-1) as { status: string }).status, choice === 'deny' ? 'declined' : 'done')
  }
  for (const text of ['command-approval', 'question']) {
    const from = client.notifications.length
    await client.request('session/send', { id, text })
    const event = await client.waitFor((n) => n.method === 'ask/add', 5000, text, from)
    if (text === 'question') {
      assert.equal(event.params.ask.questions[0].other, true)
      await client.request('session/answer', { id, ask: event.params.ask.id,
        answers: [{ selected: ['yes'], custom: 'detail' }, { selected: [] }] })
    } else {
      assert.equal(event.params.ask.view.command, 'echo hi')
      await client.request('session/answer', { id, ask: event.params.ask.id, choice: 'allow' })
    }
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'idle', from)
  }
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === '{"answers":{"q1":{"answers":["yes","detail"]}}}'))
})

test('Codex steer, interrupt before turn id, cancellation and next-turn settings', async (t) => {
  const { client, id, requests, send, session } = await setup(t)
  assert.deepEqual(await client.request('session/steer', { id, text: 'idle' }), { accepted: false })
  let from = client.notifications.length
  await client.request('session/send', { id, text: 'hold' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'running', 5000, 'running', from)
  await client.waitFor((n) => n.method === 'block/append' && n.params.text === 'holding', 5000, 'turn ready', from)
  await client.request('session/configure', { id, model: 'new-model', effort: 'high', mode: 'auto' })
  assert.deepEqual(await client.request('session/steer', { id, text: 'steered', block: 'u-steer' }), { accepted: true })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'steered', from)
  assert.deepEqual(session.blocks.filter((b) => b.type === 'user' && b.text === 'steered'),
    [{ id: 'u-steer', type: 'user', text: 'steered', images: undefined }])
  from = client.notifications.length
  await client.request('session/send', { id, text: 'delayed' })
  await client.request('session/interrupt', { id })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'interrupt', from)
  assert.ok((await requests()).some((r) => r.method === 'turn/interrupt'))
  for (const mode of Object.keys(modes)) {
    await client.request('session/configure', { id, mode })
    await send(mode)
    const params = (await requests()).filter((r) => r.method === 'turn/start').at(-1).params
    assert.equal(params.approvalPolicy, modes[mode][0])
    assert.equal(params.approvalsReviewer, modes[mode][3])
    assert.deepEqual(params.sandboxPolicy, { type: modes[mode][1] })
    assert.equal(params.model, 'new-model'); assert.equal(params.effort, 'high')
    assert.deepEqual(params.input[1], { type: 'localImage', path: '/tmp/image.png' })
  }
  from = client.notifications.length
  await client.request('session/send', { id, text: 'file-approval' })
  await client.waitFor((n) => n.method === 'ask/add', 5000, 'ask', from)
  await client.request('session/interrupt', { id })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'cancel', from)
  assert.equal(session.asks.size, 0)
})

test('Codex changes tools by resuming in a fresh process once, children retain their process', async (t) => {
  const { client, id, send, requests, session, dir } = await setup(t)
  const pid = (await requests())[0].pid
  client.notify('editor/tools', { tools: [], readOnly: [] })
  await send('new-tools')
  const starts = (await requests()).filter((r) => r.method === 'initialize')
  assert.equal(starts.length, 2); assert.notEqual(starts[1].pid, pid)
  assert.equal((await requests()).filter((r) => r.method === 'thread/resume').length, 1)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'codex-tools-changed'))
  await send('same-tools')
  assert.equal((await requests()).filter((r) => r.method === 'initialize').length, 2)
  const child = (await client.request('session/open', { agent: 'codex', root: dir, parent: id })).id
  const count = (await requests()).filter((r) => r.method === 'initialize').length
  client.notify('editor/tools', { tools: [{ name: 'new', description: '', inputSchema: {} }], readOnly: [] })
  await client.request('session/attach', { id: child })
  const from = client.notifications.length
  await client.request('session/send', { id: child, text: 'child' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle' && n.params.session === child, 5000, 'child', from)
  assert.equal((await requests()).filter((r) => r.method === 'initialize').length, count)
})

for (const text of ['delayed', 'response-only']) {
  test(`Codex preserves an interrupt across a tools restart (${text})`, async (t) => {
    const { client, id, dir, requests, send, session } = await setup(t, {}, false, true)
    client.notify('editor/tools', { tools: [], readOnly: [] })
    const from = client.notifications.length
    await client.request('session/send', { id, text, block: 'u-restart' })
    await client.waitFor((n) => n.method === 'block/add' && n.params.block.notice?.kind === 'codex-tools-changed',
      5000, 'restart begins', from)
    await client.request('session/interrupt', { id })
    // The fixture cannot exit before this release, so cancellation precedes start().
    assert.equal((await requests()).filter((r) => r.method === 'initialize').length, 1)
    await writeFile(join(dir, 'restart-gate'), '')
    const running = await client.waitFor((n) => n.method === 'status' && n.params.status === 'running', 5000, 'new turn', from)
    await client.waitFor((n) => n.method === 'status' && n.params.status === 'idle', 5000, 'interrupted turn ends',
      client.notifications.indexOf(running) + 1)
    const log = await requests(), starts = log.filter((r) => r.method === 'initialize')
    const interrupts = log.filter((r) => r.method === 'turn/interrupt')
    assert.equal(starts.length, 2)
    assert.equal(interrupts.length, 1)
    assert.equal(interrupts[0].pid, starts[1].pid)
    assert.equal(interrupts[0].params.threadId, 'fake-thread')
    assert.equal(session.status, 'idle')
    assert.deepEqual(session.blocks.filter((b) => b.id === 'u-restart'),
      [{ id: 'u-restart', type: 'user', text, images: undefined }])
    await client.request('session/interrupt', { id }) // Idle cancellation cannot leak to another message.
    await send('after-interrupt')
    assert.equal((await requests()).filter((r) => r.method === 'turn/interrupt').length, 1)
  })
}

test('Codex resumes paged thread history, attach earlier turns excludes usage; crash resumes saved id', async (t) => {
  const { client, id, attached, requests, session, send } = await setup(t, { resume: 'fake-thread' })
  assert.equal(attached.earlier, true)
  assert.equal(session.blocks.filter((b) => b.type === 'user').length, 3)
  assert.equal(session.blocks.find((b) => b.id === 'old-user-1')?.type, 'user')
  assert.equal(client.notifications.filter((n) => n.method === 'usage/call').length, 0)
  const before = client.notifications.length
  await client.request('session/earlier', { id, before: 'old-user-3', turns: 1 })
  const early = await client.waitFor((n) => n.method === 'block/add' && n.params.block.id === 'old-user-2', 5000, 'earlier', before)
  assert.equal(early.params.history, true); assert.equal(early.params.before, 'old-user-3')
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'crash' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'exited', 5000, 'crash', from)
  await send('recovered')
  assert.equal((await requests()).filter((r) => r.method === 'thread/resume').length, 2)
  assert.equal(session.blocks.filter((b) => b.id === 'old-user-1').length, 1)
})

test('Codex config failures preserve configured instructions and turn errors finish cleanly', async (t) => {
  const { requests, session, send, client, dir } = await setup(t, {}, true)
  assert.equal(Object.hasOwn((await requests()).find((r) => r.method === 'thread/start').params, 'developerInstructions'), false)
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'codex-config-read-failed'))
  await send('error'); await send('retry')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.args?.message === 'turn failed'))
  assert.ok(!session.blocks.some((b) => b.type === 'notice' && b.notice.args?.message === 'retrying'))
  await assert.rejects(client.request('session/open', { agent: 'codex', root: '/rpc:host:/tmp/' }), /local absolute root/)
  await assert.rejects(client.request('session/open', { agent: 'codex', root: dir, fork: session.id }), /forks are not supported/)
})

test('Codex item views and effective instructions match Lisp behavior', () => {
  const original = '  Rules.\n\n'
  assert.ok(developerInstructions({ config: { developer_instructions: original } }).startsWith(original + '\n\n'))
  for (const value of [null, {}, { config: null }, { config: 'bad' }, { config: [] }, { config: { developer_instructions: 42 } }]) {
    assert.throws(() => developerInstructions(value), /Invalid config/)
  }
  assert.equal(itemView('/p', { type: 'commandExecution', command: "/bin/bash -lc 'a\nb'" })?.title, 'a …')
  assert.equal(itemView('/p', { type: 'fileChange', changes: [{ path: '/p/a', kind: { type: 'delete' } }] })?.diff, '--- a\n+++ /dev/null')
  assert.equal(itemView('/p', { type: 'fileChange', changes: [{ path: '/p/a', kind: { type: 'update' }, diff: '@@\n-a\n+b\n' }] })?.diff,
    '--- a\n+++ a\n@@\n-a\n+b')
})

for (const child of [false, true]) test('codex snapshots read-only approvals; removal restarts only persistent sessions (' + child + ')', async (t) => {
  const { client, id, session, send, requests } = await setup(t, child ? { parent: 'parent' } : {})
  const before = (await requests()).filter((r) => r.method === 'initialize')
  const allowed = (argv: string[]) => argv.filter((s) => s.includes('.approval_mode='))
  assert.ok(allowed(before[0].argv).includes('mcp_servers.emacs.tools.context.approval_mode="approve"'))
  client.notify('editor/tools', { ...editorTools, readOnly: [...editorTools.readOnly].reverse() })
  await send('same-set')
  assert.equal((await requests()).filter((r) => r.method === 'initialize').length, 1)
  // Change classification alone, leaving every tool definition byte-for-byte intact.
  client.notify('editor/tools', { tools: editorTools.tools, readOnly: [] })
  await send('after-removal')
  const log = await requests(), starts = log.filter((r) => r.method === 'initialize')
  assert.equal(starts.length, child ? 1 : 2)
  const sent = log.find((r) => r.method === 'turn/start' && r.params.input[0].text === 'after-removal')
  assert.equal(sent.pid, starts.at(-1).pid)
  assert.equal(allowed(starts.at(-1).argv).includes('mcp_servers.emacs.tools.context.approval_mode="approve"'), child)
  if (!child) {
    assert.notEqual(starts[0].pid, starts[1].pid)
    assert.equal(log.filter((r) => r.method === 'thread/resume').length, 1)
    await send('same-classification')
    assert.equal((await requests()).filter((r) => r.method === 'initialize').length, 2)
  }
})
