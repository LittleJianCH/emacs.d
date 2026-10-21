import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { Collaboration, definitions, profiles, profileCost, startSummary, cleanHandle, turns } from '../../emx/daemon/collab.ts'
import { Session } from '../../emx/daemon/session.ts'
import { checkoutRoot, emxRoot } from '../../emx/daemon/paths.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { Config } from '../../emx/config.ts'

const defaults = (): Config => JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
const signal = () => new AbortController().signal
async function until(predicate: () => boolean, description = 'condition'): Promise<void> {
  for (let i = 0; i < 300; i++) { if (predicate()) return; await delay(10) }
  throw new Error('Timed out: ' + description)
}
function setup() {
  const dir = mkdtempSync(join(tmpdir(), 'emx-collab-'))
  const config = defaults()
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}
  config.agents.echo = { title: 'Echo', executable: process.execPath }
  config.profiles.echo = { agent: 'echo', mode: 'full', cost: 'minimal', description: 'Tests' }
  const sessions = new Map<string, Session>()
  let visible = false, opened = 0
  const closed: string[] = []
  let collab: Collaboration
  const create = (agent = 'echo', root = dir, settings: any = { mode: 'auto' }, info: any = { handle: 'parent' }) => {
    const s = new Session({ id: `session-${sessions.size}-${Math.random()}`, agent, root, settings, info,
      onEvent: (s, e) => collab.event(s, e) })
    sessions.set(s.id, s)
    return s
  }
  collab = new Collaboration({ sessions, varDir: dir, config: () => config, create,
    close: async (s) => { await s.stop(); sessions.delete(s.id); closed.push(s.id) },
    view: async () => { opened++ }, visible: async () => visible, changed: () => {} })
  const cleanup = async () => { collab.stop(); for (const s of sessions.values()) await s.stop(); rmSync(dir, { recursive: true, force: true }) }
  return { dir, config, sessions, create, collab, cleanup, closed, setVisible: (value: boolean) => { visible = value }, opened: () => opened }
}
test('daemon config owns five caller-independent collaboration definitions', () => {
  const c = defaults()
  const tools = definitions(c)
  assert.deepEqual(tools.map((tool) => tool.name).sort(),
    ['session_ask', 'session_read', 'session_start', 'session_stop', 'sessions'])
  assert.ok(tools.every((tool) => tool.inputSchema.type === 'object'))
  const start = tools.find((tool) => tool.name === 'session_start')!.description
  assert.ok(start.indexOf('Delegate independent work early') < start.indexOf('Choose how it gets context:'))
  assert.match(start, /cannot start further sessions/)
  assert.deepEqual(definitions(c), definitions(c))
  assert.equal(cleanHandle('Reply\n`Cache Test`'), 'cache-test')
  assert.equal(cleanHandle('123'), undefined)
  c.agents.dsh.executable = '/does/not/exist'
  assert.ok(!profiles(c).some(([, p]) => p.agent === 'dsh'))
  assert.ok(profiles(c, ['claude']).every(([, p]) => p.agent === 'claude'))
})
test('delegation guidance names no profiles and profile descriptions name no other profile', () => {
  const c = defaults()
  for (const name of Object.keys(c.profiles)) {
    assert.ok(!c.collab.startGuidance.includes(name), `startGuidance names ${name}`)
    for (const [other, p] of Object.entries(c.profiles)) {
      if (other !== name) assert.ok(!p.description?.includes(name), `${other} names ${name}`)
    }
  }
})
test('descriptions and summary include only enabled and available profiles and fork agents', () => {
  const c = defaults()
  for (const a of Object.values(c.agents)) a.executable = process.execPath
  const env = { PATH: '' }
  const description = (enabled?: string[]) => definitions(c, enabled, env).find((t) => t.name === 'session_start')!.description
  assert.match(description(), /\n  Claude, Codex and DeepSeek sessions can fork\.\n/)
  c.agents.dsh.executable = '/does/not/exist'
  const start = description(), summary = startSummary(c, undefined, env)
  for (const text of [start, summary]) assert.doesNotMatch(text, /coder-flash|explorer-flash|DeepSeek|\{forkAgents\}/)
  assert.match(start, /\n  Claude and Codex sessions can fork\.\n/)
  assert.equal(summary, '- Subagent profiles here, cheapest first: explorer (low); coder (medium); reviewer, generalist (high); expert (premium).  session_start describes each.')
  assert.match(description(['codex']), /\n  Codex sessions can fork\.\n/)
  assert.doesNotMatch(description(['dsh']), /sessions can fork|\{forkAgents\}/)
  c.agents.claude.executable = c.agents.codex.executable = '/does/not/exist'
  assert.doesNotMatch(description(), /sessions can fork|\{forkAgents\}/)
  assert.equal(startSummary(c, undefined, env), '')
  assert.equal(startSummary(defaults(), [], env), '')
  assert.deepEqual(definitions(c, undefined, env), definitions(c, undefined, env))
})
test('profiles, rendered lines and summary share stable cost order including unknown costs', () => {
  const c = defaults()
  for (const a of Object.values(c.agents)) a.executable = process.execPath
  const env = { PATH: '' }
  c.profiles.unpriced = { agent: 'codex' }
  const expected = ['coder-flash', 'explorer-flash', 'explorer', 'coder', 'reviewer', 'generalist', 'expert', 'unpriced']
  const renderedNames = () => definitions(c, undefined, env).find((t) => t.name === 'session_start')!.description
    .split(c.collab.prompts.profileHeader)[1].split('\n').map((line) => line.slice(2, line.indexOf(':')))
  assert.deepEqual(profiles(c, undefined, env).map(([name]) => name), expected)
  assert.deepEqual(renderedNames(), expected)
  assert.equal(profileCost('unpriced', c.profiles.unpriced), 'unknown')
  assert.equal(startSummary(c, undefined, env), '- Subagent profiles here, cheapest first: coder-flash, explorer-flash (minimal); explorer (low); coder (medium); reviewer, generalist (high); expert (premium); unpriced (unknown).  session_start describes each.')
  c.profiles.explorer.cost = 'premium'
  assert.deepEqual(renderedNames(), ['coder-flash', 'explorer-flash', 'coder', 'reviewer', 'generalist', 'explorer', 'expert', 'unpriced'])
  assert.match(startSummary(c, undefined, env), /explorer, expert \(premium\)/)
  assert.match(definitions(c, undefined, env).find((t) => t.name === 'session_start')!.description, /- explorer: Claude haiku, premium cost\./)
})
test('every daemon collaboration tool works; origin and hidden notes survive separately; child closes after mailbox', async () => {
  const t = setup()
  try {
    const parent = t.create(); await parent.start()
    const peer = t.create('echo', t.dir, {}, { handle: 'peer' }); await peer.start()
    const listed: any = await t.collab.call(parent, 'sessions', {}, signal())
    assert.equal(listed.sessions.find((s: any) => s.id === '@parent').yours, true)
    assert.match(await t.collab.call(parent, 'session_read', { session: '@peer' }, signal()) as string, /No turns yet/)
    parent.setStatus('running')
    assert.match(await t.collab.call(parent, 'session_ask', { session: '@peer', prompt: 'read this' }, signal()) as string, /Sent to @peer/)
    await until(() => !!t.collab.mailbox.get(parent.id)?.length)
    assert.equal((peer.blocks[0] as any).origin, '@parent')
    assert.equal((peer.blocks[0] as any).text, 'read this')
    assert.match((peer.blocks[1] as any).text, /through session_ask/)
    assert.match(await t.collab.call(parent, 'session_read', { session: '@peer', tools: 'full' }, signal()) as string, /Message from @parent/)
    assert.match(await t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'done', handle: 'bounded' }, signal()) as string, /Started @bounded/)
    await until(() => t.closed.length === 1)
    assert.equal(t.opened(), 1)
    assert.equal(t.collab.mailbox.get(parent.id)?.length, 2)
    parent.setStatus('idle')
    await until(() => turns(parent).length === 1)
    const user: any = parent.blocks.find((b) => b.type === 'user')
    assert.equal(user.origin, '会话回复')
    assert.match(user.text, /Reply from "@peer"/)
    assert.match(user.text, /Reply from "@bounded"/)
    assert.match(user.text, /\n\n---\n\n/)
    assert.ok(!user.text.includes('delivered by Emacs'))
    assert.match((parent.blocks.at(-1) as any).text, /delivered by Emacs; not from the user/)
  } finally { await t.cleanup() }
})
test('child restrictions, mode cap, naming collisions, stop ownership, visibility and maxActive', async () => {
  const t = setup()
  try {
    t.setVisible(true)
    const parent = t.create(); await parent.start(); parent.setStatus('running')
    for (let i = 0; i < 2; i++) await t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'task', handle: 'work' }, signal())
    const children = [...t.sessions.values()].filter((s) => s.info.parent)
    assert.deepEqual(children.map((s) => s.info.handle), ['work', 'work-2'])
    assert.ok(children.every((s) => s.settings.mode === 'auto'))
    const child = children[0]
    await assert.rejects(t.collab.call(child, 'session_start', { profile: 'echo', prompt: 'nested' }, signal()), /can't start/)
    await assert.rejects(t.collab.call(child, 'session_ask', { session: '@parent', prompt: 'ask' }, signal()), /doesn't ask/)
    await assert.rejects(t.collab.call(parent, 'session_ask', { session: '@work', prompt: 'more' }, signal()), /takes no messages/)
    await assert.rejects(t.collab.call(child, 'session_stop', { session: '@work-2' }, signal()), /isn't a session you started/)
    children.forEach((s) => s.setStatus('running')); t.config.collab.maxActive = 2
    await assert.rejects(t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'extra' }, signal()), /most at once/)
    assert.match(await t.collab.call(parent, 'session_stop', { session: '@work' }, signal()) as string, /Stopped and closed @work/)
    assert.ok(!t.collab.pending.some((p) => p.target === child.id))
    await assert.rejects(t.collab.call(parent, 'session_start', { context: 'fork', profile: 'echo', prompt: 'fork' }, signal()), /omit profile/)
    await assert.rejects(t.collab.call(parent, 'session_read', { session: '@parent', tools: 'bad' }, signal()), /tools must/)
    await assert.rejects(t.collab.call(parent, 'session_ask', { session: '@parent', prompt: 'self' }, signal()), /own session/)
  } finally { await t.cleanup() }
})
test('confirmation denial, cancellation and races reserve a concurrency slot and recheck targets', async () => {
  const t = setup()
  try {
    const parent = t.create(); await parent.start(); parent.setStatus('running')
    t.config.profiles.echo.confirm = true; t.config.collab.maxActive = 1
    const denied = t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'confirm' }, signal())
    const id = [...parent.asks.keys()][0]
    await assert.rejects(t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'race' }, signal()), /most at once/)
    parent.answer(id, { choice: 'deny' })
    await assert.rejects(denied, /user declined/)
    const controller = new AbortController()
    const cancelled = t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'cancel' }, controller.signal)
    controller.abort(new Error('Cancelled'))
    await assert.rejects(cancelled, /Cancelled/)
    assert.equal(parent.asks.size, 0)
    const peer = t.create('echo', t.dir, {}, { handle: 'peer' }); await peer.start()
    t.config.collab.confirm = true
    const asked = t.collab.call(parent, 'session_ask', { session: '@peer', prompt: 'approve' }, signal())
    peer.setStatus('running'); parent.answer([...parent.asks.keys()][0], { choice: 'allow' })
    await assert.rejects(asked, /busy/)
  } finally { await t.cleanup() }
})
test('handoff stays fixed within a turn, keeps task last; failed children stay; long replies persist and mailbox restores', async () => {
  const t = setup()
  try {
    t.setVisible(true); t.config.collab.replyLimit = 20
    const parent = t.create(); await parent.start()
    parent.addBlock({ id: 'goal', type: 'user', text: 'original goal' })
    parent.addBlock({ id: 'old', type: 'text', kind: 'assistant', text: 'prior', done: true })
    parent.addBlock({ id: 'latest', type: 'user', text: 'latest task' }); parent.setStatus('running')
    await t.collab.call(parent, 'session_start', { profile: 'echo', context: 'handoff', handle: 'one', prompt: 'first task' }, signal())
    parent.addBlock({ id: 'ongoing', type: 'text', kind: 'assistant', text: 'later event', done: true })
    await t.collab.call(parent, 'session_start', { profile: 'echo', context: 'handoff', handle: 'two', prompt: 'second task' }, signal())
    const children = [...t.sessions.values()].filter((s) => s.info.parent)
    await until(() => children.every((s) => s.blocks.length > 0), 'handoff submission')
    const texts = children.map((s) => (s.blocks[0] as any).text)
    assert.equal(texts[0].split('Your task:')[0], texts[1].split('Your task:')[0])
    assert.match(texts[0], /history for context, not requests to act on/)
    assert.ok(texts[0].endsWith('Your task:\nfirst task'))
    children[0].addBlock({ id: 'fail', type: 'notice', notice: { kind: 'error', level: 'error' } })
    t.setVisible(false)
    await until(() => (t.collab.mailbox.get(parent.id)?.length ?? 0) === 2)
    assert.ok(t.sessions.has(children[0].id))
    assert.match(t.collab.mailbox.get(parent.id)![0].text, /Full reply:/)
    const replacement = new Collaboration(t.collab.host); replacement.restore()
    assert.equal(replacement.mailbox.get(parent.id)?.length, 2)
    replacement.stop()
  } finally { await t.cleanup() }
})
test('MCP dispatch serves daemon collaboration even without editor tools and cascades parent stop', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-collab-wire-'))
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({ collab: { handleCommand: [], agentHandleCommands: {} } }))
  const d = new DaemonServer({ varDir: dir }); await d.start()
  const client = await SocketClient.connect(d.socket), mcp = await SocketClient.connect(d.socket)
  try {
    await client.request('hello', { client: 'test', version: '' })
    const { id } = await client.request('session/open', { agent: 'echo', root: dir })
    await mcp.request('mcp/hello', { session: id })
    const tools = await mcp.request('mcp/tools', {})
    assert.ok(tools.tools.find((t) => t.name === 'session_start'))
    assert.equal((await mcp.request('mcp/call', { name: 'sessions' }) as any).sessions.length, 1)
    const child = await client.request('session/open', { agent: 'echo', root: dir, parent: id })
    await client.request('session/stop', { id })
    assert.ok(!d.sessions.has(child.id))
  } finally { await mcp.close(); await client.close(); await d.stop(); rmSync(dir, { recursive: true, force: true }) }
})
for (const agent of ['claude', 'codex', 'dsh']) test(`${agent} forks its native conversation in a child and preserves settings`, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-fork-' + agent + '-'))
  const keys = [`EMX_${agent.toUpperCase()}_EXECUTABLE`, `EMX_${agent.toUpperCase()}_LOG`, 'EMX_CLAUDE_PROJECTS_DIR']
  const old = keys.map((key) => process.env[key])
  process.env[keys[0]] = join(checkoutRoot, 'test/emx/fixtures', agent + '.mjs')
  process.env[keys[1]] = join(dir, 'cli.jsonl')
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({ collab: { handleCommand: [], agentHandleCommands: {}, closeFinished: false }, usage: { pollInterval: 0 } }))
  const d = new DaemonServer({ varDir: dir }); await d.start()
  const client = await SocketClient.connect(d.socket)
  try {
    await client.request('hello', { client: 'test', version: '', tools: {
      tools: [{ name: 'context', description: 'Context', inputSchema: { type: 'object' } }], readOnly: ['context'] } })
    const { id } = await client.request('session/open', { agent, root: dir, settings: { model: 'fake-model', effort: 'high', mode: 'auto' } })
    const parent = d.sessions.get(id)!
    await until(() => !!parent.resumeId())
    await client.close()
    parent.setStatus('running')
    const result = await d.collab.call(parent, 'session_start', { context: 'fork', handle: 'native-fork', prompt: 'fork task' }, signal())
    assert.match(String(result), /Started @native-fork/)
    const child = [...d.sessions.values()].find((s) => s.info.parent === id)!
    assert.equal(child.info.forkFrom, parent.resumeId())
    assert.equal(child.settings.mode, 'auto')
    await until(() => child.status === 'idle' && child.blocks.some((b) => b.type === 'text'))
    const user: any = child.blocks.find((b) => b.type === 'user')
    assert.equal(user.text, 'Your task:\nfork task')
    assert.equal(user.origin, '@' + parent.info.handle)
    assert.ok(!user.text.includes('You are a fork'))
    const calls = readFileSync(join(dir, 'cli.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
    if (agent === 'claude') {
      const spawns = calls.filter((c) => c.type === 'spawn')
      const argv = spawns[1].argv
      const allowed = (args: string[]) => args[args.indexOf('--allowedTools') + 1]
      assert.equal(allowed(argv), allowed(spawns[0].argv))
      assert.equal(allowed(argv), 'mcp__emacs__context,mcp__emacs__session_read,mcp__emacs__sessions')
      assert.ok(argv.includes('--fork-session')); assert.ok(argv.includes('--no-session-persistence'))
      assert.equal(argv[argv.indexOf('--resume') + 1], parent.resumeId())
    } else if (agent === 'codex') {
      const starts = calls.filter((c) => c.method === 'initialize')
      const approvals = (args: string[]) => args.filter((s) => s.includes('.approval_mode='))
      assert.deepEqual(approvals(starts[1].argv), approvals(starts[0].argv))
      assert.equal(approvals(starts[0].argv).length, 3)
      assert.deepEqual(calls.find((c) => c.method === 'thread/fork').params,
        { threadId: parent.resumeId(), ephemeral: true, excludeTurns: true })
    } else {
      const fork = calls.findIndex((c) => c.method === 'initialize' && c.params.forkFrom)
      assert.ok(calls.findIndex((c) => c.method === 'flush') < fork)
      assert.equal(calls[fork].params.forkFrom, parent.resumeId())
      assert.equal(calls[fork].params.parent, parent.resumeId())
      assert.deepEqual(calls[fork].params.mcpServers[0].readOnly, ['context', 'session_read', 'sessions'])
      assert.deepEqual(calls[fork].params.mcpServers[0].readOnly,
        calls.find((c) => c.method === 'initialize').params.mcpServers[0].readOnly)
    }
  } finally {
    await client.close(); await d.stop()
    keys.forEach((key, i) => { if (old[i] === undefined) delete process.env[key]; else process.env[key] = old[i] })
    rmSync(dir, { recursive: true, force: true })
  }
})
test('cheap handle naming falls back after failure, preserves uniqueness and runs only once', async () => {
  const t = setup()
  try {
    const command = join(checkoutRoot, 'test/emx/fixtures/handle.mjs')
    t.config.collab.agentHandleCommands.echo = [process.execPath, command, 'fail']
    t.config.collab.handleCommand = [process.execPath, command]
    const parent = t.create(); await parent.start()
    const other = t.create('echo', t.dir, {}, { handle: 'topic-name' }); await other.start()
    t.collab.name(parent, 'a topic')
    await until(() => parent.info.handle === 'topic-name-2')
    t.collab.name(parent, 'different topic')
    assert.equal(parent.info.handle, 'topic-name-2')
  } finally { await t.cleanup() }
})
test('profile confirmation expires and frees its reservation', async () => {
  const t = setup()
  try {
    const parent = t.create(); await parent.start()
    t.config.profiles.echo.confirm = true
    t.config.collab.confirmTimeout = .02
    await assert.rejects(t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'timeout' }, signal()), /didn't confirm within/)
    assert.equal(parent.asks.size, 0)
    t.config.profiles.echo.confirm = false
    assert.match(String(await t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'next' }, signal())), /Started/)
  } finally { await t.cleanup() }
})
test('handoff budgets count Unicode characters like Lisp rather than UTF-16 units', async () => {
  const t = setup()
  try {
    t.setVisible(true); t.config.collab.handoffLimit = 20
    const parent = t.create(); await parent.start()
    parent.addBlock({ id: 'emoji-goal', type: 'user', text: '😀'.repeat(50) })
    parent.setStatus('running')
    await t.collab.call(parent, 'session_start', { profile: 'echo', context: 'handoff', prompt: 'task' }, signal())
    const child = [...t.sessions.values()].find((s) => s.info.parent)!
    await until(() => child.blocks.length > 0, 'handoff submission')
    const text = (child.blocks[0] as any).text
    assert.ok(text.includes('…' + '😀'.repeat(20)))
  } finally { await t.cleanup() }
})

test('a child waiting for its view occupies only one maxActive slot', async () => {
  const t = setup()
  const view = Promise.withResolvers<void>()
  let first: Promise<unknown> | undefined
  try {
    t.config.collab.maxActive = 2
    t.setVisible(true)
    const parent = t.create(); await parent.start(); parent.setStatus('running')
    t.collab.host.view = async () => view.promise
    first = t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'first', handle: 'one' }, signal())
    assert.equal([...t.sessions.values()].filter((s) => s.info.parent).length, 1)
    t.collab.host.view = async () => {}
    assert.match(String(await t.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'second', handle: 'two' }, signal())), /Started @two/)
    view.resolve()
    await first
  } finally { view.resolve(); await first?.catch(() => {}); await t.cleanup() }
})

test('stopping a child revokes mail in an already captured delivery snapshot', async () => {
  const t = setup()
  const visibility = Promise.withResolvers<boolean>()
  const queried = Promise.withResolvers<void>()
  let settling: Promise<void> | undefined
  try {
    const parent = t.create(); await parent.start(); parent.setStatus('running')
    for (const handle of ['one', 'two']) {
      const child = t.create('echo', t.dir, {}, { handle, parent: parent.id }); await child.start()
      child.addBlock({ id: handle, type: 'user', text: 'task' })
      child.addBlock({ id: handle + '-reply', type: 'text', kind: 'assistant', text: handle + ' reply', done: true })
      t.collab.pending.push({ target: child.id, asker: parent.id, block: handle, handle })
    }
    t.collab.host.visible = async () => { queried.resolve(); return visibility.promise }
    settling = t.collab.settle()
    await queried.promise
    assert.equal(await t.collab.call(parent, 'session_stop', { session: '@two' }, signal()), 'Stopped and closed @two.')
    visibility.resolve(true)
    await settling
    assert.deepEqual(t.collab.mailbox.get(parent.id)?.map((m) => m.handle), ['one'])
    parent.setStatus('idle')
    await t.collab.settle()
    assert.ok(!parent.blocks.some((b) => b.type === 'user' && b.text.includes('@two')))
  } finally { visibility.resolve(true); await settling; await t.cleanup() }
})

async function closingSetup() {
  const dir = mkdtempSync(join(tmpdir(), 'emx-closing-'))
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} },
    agents: { echo: { title: 'Echo', executable: process.execPath } },
    profiles: { echo: { agent: 'echo' } },
  }))
  const daemon = new DaemonServer({ varDir: dir }); await daemon.start()
  const client = await SocketClient.connect(daemon.socket), mcp = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'test', version: '' })
  const { id } = await client.request('session/open', { agent: 'echo', root: dir })
  await mcp.request('mcp/hello', { session: id })
  const parent = daemon.sessions.get(id)!
  const cleanup = async () => { await mcp.close(); await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
  return { daemon, client, mcp, parent, dir, cleanup }
}
test('parent close rejects new collaboration calls and cancels confirmations before stopping children', async () => {
  const t = await closingSetup()
  const stopping = Promise.withResolvers<void>(), release = Promise.withResolvers<void>()
  let closing: Promise<unknown> | undefined, confirmation: Promise<unknown> | undefined
  try {
    const { id } = await t.client.request('session/open', { agent: 'echo', root: t.dir, parent: t.parent.id })
    const child = t.daemon.sessions.get(id)!, stop = child.backend.stop.bind(child.backend)
    child.backend.stop = async () => { stopping.resolve(); await release.promise; await stop() }
    t.daemon.configuration.value.profiles.echo.confirm = true
    confirmation = t.mcp.request('mcp/call', { name: 'session_start', arguments: { profile: 'echo', prompt: 'confirm' } })
    const rejected = assert.rejects(confirmation, /Session stopped|closing/)
    await until(() => t.parent.asks.size === 1)
    closing = t.client.request('session/stop', { id: t.parent.id })
    await stopping.promise
    assert.equal(t.parent.asks.size, 0, 'pending calls are cancelled before waiting on a child stop')
    await rejected
    for (const name of ['session_start', 'session_ask']) {
      await assert.rejects(t.mcp.request('mcp/call', { name, arguments: { profile: 'echo', prompt: 'late', session: '@echo' } }), /session is closing/)
    }
    release.resolve(); await closing
    assert.equal(t.daemon.sessions.size, 0)
  } finally { release.resolve(); await closing; await confirmation?.catch(() => {}); await t.cleanup() }
})
for (const stage of ['view', 'backend']) test(`parent close waits for a child starting in ${stage} and stops it`, async () => {
  const t = await closingSetup()
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>()
  let starting: Promise<unknown> | undefined, closing: Promise<unknown> | undefined
  let child: Session | undefined, closed = false
  try {
    t.daemon.collab.host.view = async (s) => {
      child = s
      if (stage === 'view') { entered.resolve(); await release.promise }
      else {
        const start = s.backend.start.bind(s.backend)
        s.backend.start = async (...args) => { entered.resolve(); await release.promise; await start(...args) }
      }
    }
    starting = t.mcp.request('mcp/call', { name: 'session_start', arguments: { profile: 'echo', prompt: 'task' } })
    const rejected = assert.rejects(starting, /Session stopped|closing/)
    await entered.promise
    closing = t.client.request('session/stop', { id: t.parent.id }).then(() => { closed = true })
    // A ping on the same socket proves the stop request has entered its wait.
    await t.client.request('ping', {})
    assert.equal(closed, false, 'parent close must wait for the in-flight child start')
    assert.ok(t.daemon.sessions.has(t.parent.id))
    release.resolve(); await rejected; await closing
    assert.equal(t.daemon.sessions.size, 0)
    assert.equal(child!.backend.alive(), false)
    assert.ok(!child!.blocks.some((b) => b.type === 'user'))
  } finally { release.resolve(); await starting?.catch(() => {}); await closing; await t.cleanup() }
})
