import './fixtures/environment.ts'
import { spawnSync } from 'node:child_process'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, copyFileSync, appendFileSync } from 'node:fs'
import { createConnection } from 'node:net'
import { dirname, join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Connection } from '../../emx/daemon/rpc.ts'
import { Session } from '../../emx/daemon/session.ts'

async function wait(predicate: () => boolean) {
  const deadline = Date.now() + 5000
  while (!predicate() && Date.now() < deadline) await delay(10)
  assert.ok(predicate(), 'restart completes within five seconds')
}

async function fixture(stopCollab = true) {
  const dir = mkdtempSync('/tmp/emx-restart-')
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  const launches: string[] = []
  const daemon = new DaemonServer({ varDir: dir, restart: (runtime) => launches.push(runtime) })
  await daemon.start()
  const peer = new Connection(createConnection(daemon.socket))
  await peer.request('hello', { client: 'test', version: 'test' })
  const opened = await peer.request('session/open', { agent: 'echo', root: dir }) as { id: string }
  const session = daemon.sessions.get(opened.id)!
  await wait(() => !session.operating)
  if (stopCollab) daemon.collab.stop() // Synthetic collaboration blockers below are cleared explicitly.
  return { dir, daemon, peer, session, launches, cleanup: async () => {
    peer.socket.destroy(); await daemon.stop(); rmSync(dir, { recursive: true, force: true })
  } }
}

test('idle live CLI hibernates after the restart reply; current code is left alone', async () => {
  const f = await fixture()
  try {
    assert.deepEqual(await f.peer.request('daemon/restart', { version: f.daemon.version, runtime: '/new/bin/emx' }),
      { status: 'up_to_date', version: f.daemon.version })
    assert.equal(f.session.backend.alive(), true)
    f.session.send('kept transcript')
    await wait(() => !f.session.busy() && !f.session.operating)
    const reply = await f.peer.request('daemon/restart', { version: 'new', runtime: '/new/bin/emx' }) as any
    assert.equal(reply.status, 'restarted')
    await wait(() => f.launches.length === 1)
    assert.equal(f.session.backend.alive(), false)
    const saved = JSON.parse(readFileSync(join(f.dir, 'emx/sessions.json'), 'utf8'))
    assert.equal(saved.sessions[0].id, f.session.id)
    assert.deepEqual(f.launches, ['/new/bin/emx'])
  } finally { await f.cleanup() }
})

for (const blocker of ['starting', 'running', 'disconnected', 'approval', 'question', 'child',
  'session_ask', 'mailbox', 'outgoing', 'operation'] as const) {
  test(`restart waits for ${blocker}, serves requests, then fires when the last blocker clears`, async () => {
    const f = await fixture()
    let clear = async () => {}
    try {
      if (['starting', 'running', 'disconnected'].includes(blocker)) {
        f.session.setStatus(blocker as 'running')
        clear = async () => f.session.setStatus('idle')
      } else if (blocker === 'approval' || blocker === 'question') {
        void f.session.ask(blocker === 'approval' ? { type: 'approval', choices: ['allow'] }
          : { type: 'question', questions: [] })
        clear = async () => { f.session.answer([...f.session.asks.keys()][0], {}) }
      } else if (blocker === 'child') {
        const child = new Session({ id: 'child', agent: 'echo', root: f.dir, info: { parent: f.session.id } })
        f.daemon.sessions.set(child.id, child)
        await child.start()
        clear = async () => { await f.peer.request('session/stop', { id: child.id }) }
      } else if (blocker === 'session_ask') {
        f.daemon.collab.pending.push({ target: f.session.id, asker: f.session.id, block: 'reply' })
        clear = async () => { f.daemon.collab.pending = [] }
      } else if (blocker === 'mailbox') {
        f.daemon.collab.mailbox.set(f.session.id, [{ handle: 'test', text: 'reply' }])
        clear = async () => { f.daemon.collab.mailbox.clear() }
      } else if (blocker === 'outgoing') {
        f.daemon.collab.outgoing.push({ id: 'mail', route: { session: f.session.id, daemon: 'test' }, mail: { handle: 'test', text: 'reply' } })
        clear = async () => { f.daemon.collab.outgoing = [] }
      } else {
        let release!: () => void
        f.session.backend.configure = () => new Promise<void>((resolve) => { release = resolve })
        const configuring = f.session.configure({})
        await wait(() => !!release)
        clear = async () => { release(); await configuring }
      }
      // A second independent blocker verifies that clearing one is insufficient.
      void f.session.ask({ type: 'approval', choices: ['allow'] })
      const lastAsk = [...f.session.asks.keys()].at(-1)!
      const reply = await f.peer.request('daemon/restart', { version: 'new', runtime: '/new/bin/emx' }) as any
      assert.equal(reply.status, 'restart_scheduled')
      assert.ok(reply.waiting.some((w: any) => w.session === f.session.id || blocker === 'outgoing'))
      await clear()
      clear = async () => {}
      await delay(100)
      assert.equal(f.launches.length, 0)
      assert.equal((await f.peer.request('ping', {}) as any).version, f.daemon.version)
      f.session.answer(lastAsk, {})
      await wait(() => f.launches.length === 1)
    } finally { await clear(); await f.cleanup() }
  })
}

for (const remote of [false, true]) test(`${remote ? 'host' : 'local'} runtime restart restores transcripts and resumes fake Claude on next send`, async () => {
  const dir = mkdtempSync('/tmp/emx-code-restart-')
  const checkout = new URL('../../', import.meta.url).pathname
  const emx = join(checkout, 'bin/emx')
  const env = { ...process.env, HOME: dir, EMX_CLAUDE_LOG: join(dir, 'cli.jsonl'),
    EMX_CLAUDE_PROJECTS_DIR: join(dir, 'projects') }
  const run = (entry: string, args: string[]) => {
    const out = spawnSync(process.execPath, [entry, 'daemon', ...args], { env, encoding: 'utf8', timeout: 15000 })
    assert.equal(out.status, 0, out.stderr)
    return out.stdout.trim() ? JSON.parse(out.stdout) : undefined
  }
  const manifest = run(emx, ['--manifest'])
  const old = join(dir, 'old'), next = join(dir, 'next')
  for (const base of [old, next]) for (const file of manifest.files) {
    mkdirSync(dirname(join(base, file)), { recursive: true })
    copyFileSync(join(checkout, file), join(base, file))
  }
  appendFileSync(join(next, 'bin/emx'), '\n// replacement runtime\n')
  const entry = join(next, 'bin/emx'), version = run(entry, ['--manifest']).version
  const opts = remote ? ['--client', '1234567890abcdef'] : ['--var', join(dir, 'state')]
  const config = { collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
    agents: { claude: { executable: join(checkout, 'test/emx/fixtures/bin/claude') } } }
  const varDir = remote ? join(dir, '.cache/emacs-agent/emx/state/1234567890abcdef') : join(dir, 'state')
  mkdirSync(join(varDir, 'emx'), { recursive: true })
  writeFileSync(join(varDir, 'emx/config.json'), JSON.stringify(config))
  let peer: Connection | undefined
  try {
    const info = run(join(old, 'bin/emx'), [...opts, '--ensure'])
    peer = new Connection(createConnection(info.socket))
    await peer.request('hello', { client: 'test', version: info.version })
    const opened = await peer.request('session/open', { agent: 'claude', root: dir }) as any
    const get = () => peer!.request('sessions/list', {}) as Promise<any>
    await peer.request('session/send', { id: opened.id, text: 'before restart' })
    for (let i = 0; i < 100 && (await get()).sessions[0].status !== 'idle'; i++) await delay(20)
    await peer.request('session/send', { id: opened.id, text: 'hold' })
    for (let i = 0; i < 100 && (await get()).sessions[0].status !== 'running'; i++) await delay(20)
    const reply = await peer.request('daemon/restart', { version, runtime: entry }) as any
    assert.equal(reply.status, 'restart_scheduled')
    assert.equal((await peer.request('ping', {}) as any).version, info.version)
    await peer.request('session/interrupt', { id: opened.id })
    await wait(() => peer!.closed)
    // Probe only: ensure must not perform the replacement on behalf of the old daemon.
    let fresh: any
    const deadline = Date.now() + 10000
    while (Date.now() < deadline) {
      const probe = new Connection(createConnection(info.socket))
      try {
        const ping = await probe.request('ping', {}) as any
        if (ping.version === version) { peer = probe; fresh = ping; break }
      } catch { /* The socket is being replaced. */ }
      probe.socket.destroy(); await delay(20)
    }
    assert.equal(fresh?.version, version)
    assert.notEqual(fresh.daemon, info.pid)
    const hello = await peer.request('hello', { client: 'test', version }) as any
    assert.equal(hello.sessions[0].id, opened.id)
    assert.equal(hello.sessions[0].info.sessionId, 'fixture-native')
    const notifications: any[] = []
    peer.onNotification = (method, params) => notifications.push({ method, params })
    await peer.request('session/attach', { id: opened.id })
    await wait(() => notifications.some((n) => n.method === 'history/done'))
    assert.ok(notifications.some((n) => n.params.block?.text === 'before restart'))
    const before = readFileSync(env.EMX_CLAUDE_LOG, 'utf8').trim().split('\n').map((s) => JSON.parse(s))
    assert.equal(before.filter((m) => m.type === 'spawn').length, 1, 'recovery alone does not start a CLI')
    await peer.request('session/send', { id: opened.id, text: 'after restart' })
    await wait(() => readFileSync(env.EMX_CLAUDE_LOG, 'utf8').includes('after restart'))
    const calls = readFileSync(env.EMX_CLAUDE_LOG, 'utf8').trim().split('\n').map((s) => JSON.parse(s))
    const resumed = calls.filter((m) => m.type === 'spawn').at(-1)
    assert.ok(resumed.argv.includes('--resume'))
    assert.ok(resumed.argv.includes('fixture-native'))
  } finally {
    peer?.socket.destroy()
    run(entry, [...opts, '--stop'])
    rmSync(dir, { recursive: true, force: true })
  }
})

test('restart waits for an asynchronous outgoing delivery even after pending entries disappear', async () => {
  const f = await fixture(false)
  let release!: () => void
  const gate = new Promise<void>((resolve) => { release = resolve })
  let delivering = false
  f.daemon.collab.host.hub = async () => { delivering = true; await gate; return {} }
  f.daemon.collab.outgoing.push({ id: 'mail', route: { session: 'other', daemon: 'other' },
    mail: { handle: 'test', text: 'reply' } })
  const settling = f.daemon.collab.settle()
  try {
    await wait(() => delivering)
    const reply = await f.peer.request('daemon/restart', { version: 'new', runtime: '/new/bin/emx' }) as any
    assert.equal(reply.status, 'restart_scheduled')
    assert.ok(reply.waiting.some((w: any) => w.reason === 'collaboration delivery in flight'))
    await delay(100)
    assert.equal(f.launches.length, 0)
    release(); await settling
    await wait(() => f.launches.length === 1)
  } finally { release(); await settling; await f.cleanup() }
})

test('an MCP reload caller receives its scheduled report before its daemon exits', async () => {
  const f = await fixture()
  const mcp = new Connection(createConnection(f.daemon.socket))
  try {
    await f.peer.request('hello', { client: 'test', version: 'test', tools: {
      tools: [{ name: 'reload', description: 'test reload', inputSchema: { type: 'object' } }], readOnly: [],
    } })
    f.peer.onRequest = async (method) => {
      assert.equal(method, 'editor/call')
      const report = await f.peer.request('daemon/restart', { version: 'new', runtime: '/new/bin/emx' }) as any
      assert.equal(report.status, 'restart_scheduled')
      assert.ok(report.waiting.some((w: any) => w.reason === 'MCP tool call in flight'))
      assert.equal(f.launches.length, 0)
      return { ok: true, result: { files: [], emx: [report] } }
    }
    await mcp.request('mcp/hello', { session: f.session.id })
    const result = await mcp.request('mcp/call', { name: 'reload', arguments: {} }) as any
    assert.equal(result.emx[0].status, 'restart_scheduled')
    await wait(() => f.launches.length === 1)
  } finally { mcp.socket.destroy(); await f.cleanup() }
})
