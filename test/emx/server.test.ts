// server.test.ts --- persistence deadlines, coalescing and shutdown failures.

import * as assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import promises from 'node:fs/promises'
import { syncBuiltinESMExports } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { DaemonClient } from './client.ts'

async function open(t: TestContext) {
  const dir = fs.mkdtempSync(join(tmpdir(), 'emx-save-'))
  const daemon = new DaemonServer({ varDir: dir })
  t.after(async () => {
    await daemon.stop()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  t.after(() => client.close())
  await client.request('hello', { client: 'save-test', version: daemon.version })
  const { id } = await client.request('session/open', { agent: 'echo', root: '' })
  const session = daemon.sessions.get(id)!
  session.addBlock({ id: 'stream', type: 'text', kind: 'assistant', text: '', done: false })
  await daemon.persist()
  const file = join(dir, 'emx', 'sessions', `${id}.json`)
  const savedText = (): string => JSON.parse(fs.readFileSync(file, 'utf8')).blocks[0].text
  return { daemon, session, savedText, client }
}

test('events every 50 ms save several latest snapshots during a one-second stream', async (t) => {
  const { daemon, session, savedText } = await open(t)
  session.setStatus('running')
  const saved = new Set<string>()
  for (let i = 0; i < 20; i++) {
    session.append('stream', 'x')
    await delay(50)
    saved.add(savedText())
  }
  assert.equal(session.status, 'running')
  assert.ok([...saved].filter((text) => text.length > 0 && text.length < 20).length >= 3,
    `expected several intermediate saves, saw lengths ${[...saved].map((text) => text.length)}`)
  await daemon.persist()
  assert.equal(savedText(), 'x'.repeat(20))
})

test('slow saves have one writer and at most one pending snapshot of the latest state', async (t) => {
  const { daemon, session, savedText } = await open(t)
  const original = promises.writeFile
  let unblock!: () => void
  const blocked = new Promise<void>((resolve) => { unblock = resolve })
  let began!: () => void
  const started = new Promise<void>((resolve) => { began = resolve })
  let active = 0
  let maximum = 0
  let writes = 0
  t.mock.method(promises, 'writeFile', async (...args: Parameters<typeof original>) => {
    writes++
    maximum = Math.max(maximum, ++active)
    try {
      if (writes === 1) { began(); await blocked }
      await original(...args)
    } finally { active-- }
  })
  syncBuiltinESMExports()
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports() })
  try {
    session.append('stream', 'first')
    const first = daemon.persist()
    await started
    const pending = daemon.persist()
    for (let i = 0; i < 10; i++) {
      session.append('stream', 'x')
      assert.equal(daemon.persist(), pending, 'pending writes are coalesced')
    }
    assert.equal(writes, 1, 'no second writer starts while the first is blocked')
    unblock()
    await Promise.all([first, pending])
    assert.equal(maximum, 1)
    assert.equal(writes, 4, 'only two snapshots, each with a transcript and a table')
    assert.equal(savedText(), 'first' + 'x'.repeat(10))
  } finally { unblock() }
})

test('a failed shutdown save and a failed backend stop still stop other backends and exit', (t) => {
  const dir = fs.mkdtempSync(join(tmpdir(), 'emx-shutdown-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const serverModule = new URL('../../emx/daemon/server.ts', import.meta.url).href
  const sessionModule = new URL('../../emx/daemon/session.ts', import.meta.url).href
  const script = `
    import { DaemonServer } from ${JSON.stringify(serverModule)}
    import { Session } from ${JSON.stringify(sessionModule)}
    import { writeFileSync, existsSync } from 'node:fs'
    import { join } from 'node:path'
    import assert from 'node:assert/strict'
    const dir = process.argv[1]
    const logs = []
    const daemon = new DaemonServer({ varDir: dir, log: message => logs.push(message) })
    await daemon.start()
    for (const id of ['session-first', 'session-second']) {
      const session = new Session({ id, agent: 'echo', root: '' })
      await session.start()
      daemon.sessions.set(id, session)
    }
    const first = daemon.sessions.get('session-first').backend
    const stop = first.stop.bind(first)
    first.stop = async () => { await stop(); throw new Error('injected stop failure') }
    // A file in place of the transcripts directory makes the writer fail,
    // including when the test runs as a user who bypasses permission bits.
    writeFileSync(join(dir, 'emx', 'sessions'), 'blocked')
    await daemon.stop()
    await daemon.finished
    for (const session of daemon.sessions.values()) assert.equal(session.backend.alive(), false)
    assert.ok(logs.some(line => /Cannot save sessions on shutdown/.test(line)))
    assert.ok(logs.some(line => /Cannot stop backend for session-first/.test(line)))
    assert.equal(existsSync(daemon.socket), false)
    assert.equal(existsSync(join(dir, 'emx', 'daemon.lock')), false)
    console.log('backends stopped; shutdown completed')
  `
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', script, dir],
    { timeout: 5000, encoding: 'utf8' })
  assert.equal(child.error, undefined)
  assert.equal(child.status, 0, child.stderr)
  assert.match(child.stdout, /backends stopped; shutdown completed/)
})


test('streamed appends persist without flooding session summaries', async (t) => {
  const { daemon, session, client, savedText } = await open(t)
  await client.waitFor((n) => n.method === 'sessions')
  const from = client.notifications.length
  session.setStatus('running')
  for (let i = 0; i < 40; i++) {
    for (let j = 0; j < 10; j++) session.append('stream', 'x')
    await delay(10)
  }
  session.setStatus('idle')
  await client.waitFor((n) => n.method === 'sessions'
    && n.params.sessions[0].status === 'idle', 5000, 'latest idle summary', from)
  await delay(150)
  const lists = client.notifications.slice(from).filter((n) => n.method === 'sessions')
  assert.ok(lists.length <= 2, `expected at most two summary broadcasts, got ${lists.length}`)
  await daemon.persist()
  assert.equal(savedText(), 'x'.repeat(400))
})

test('summary changes coalesce to the latest info and identical info does not broadcast', async (t) => {
  const { session, client } = await open(t)
  await client.waitFor((n) => n.method === 'sessions')
  const from = client.notifications.length
  for (let i = 0; i < 100; i++) session.setInfo({ title: 'title-' + i })
  await client.waitFor((n) => n.method === 'sessions'
    && n.params.sessions[0].info.title === 'title-99', 5000, 'latest title', from)
  assert.equal(client.notifications.slice(from).filter((n) => n.method === 'sessions').length, 1)
  const unchanged = client.notifications.length
  session.setInfo({ title: 'title-99' })
  await delay(150)
  assert.equal(client.notifications.slice(unchanged).filter((n) => n.method === 'sessions').length, 0)
})

test('session/open retries share a creation id across pending startup, reconnect and restart', async (t) => {
  const dir = fs.mkdtempSync(join(tmpdir(), 'emx-open-once-'))
  fs.mkdirSync(join(dir, 'emx'))
  fs.writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
  let daemon = new DaemonServer({ varDir: dir, remote: true })
  let client: DaemonClient | undefined
  let release!: (env: NodeJS.ProcessEnv) => void
  const gate = new Promise<NodeJS.ProcessEnv>((resolve) => { release = resolve })
  daemon.environments!.get = () => gate
  try {
    await daemon.start()
    client = await SocketClient.connect(daemon.socket)
    await client.request('hello', { client: 'open-test', version: daemon.version })
    const params = { creationId: 'client-open-1', agent: 'echo', root: dir }
    const first = client.request('session/open', params)
    while (!daemon.sessions.size) await delay(1)
    const session = [...daemon.sessions.values()][0]
    const start = t.mock.method(session.backend, 'start')
    const retry = await client.request('session/open', params)
    release({ ...process.env })
    const opened = await first
    assert.equal(retry.id, opened.id)
    assert.equal(start.mock.callCount(), 1)
    await client.close()
    client = await SocketClient.connect(daemon.socket)
    const hello = await client.request('hello', { client: 'open-test', version: daemon.version })
    assert.equal(hello.sessions?.[0].creationId, params.creationId)
    assert.deepEqual(await client.request('session/open', params), opened)
    assert.equal(daemon.sessions.size, 1)
    await client.close(); client = undefined
    await daemon.stop()
    daemon = new DaemonServer({ varDir: dir })
    await daemon.start()
    client = await SocketClient.connect(daemon.socket)
    await client.request('hello', { client: 'open-test', version: daemon.version })
    assert.deepEqual(await client.request('session/open', params), opened)
    assert.equal(daemon.sessions.size, 1)
    assert.equal(daemon.sessions.get(opened.id)?.summary().creationId, params.creationId)
  } finally {
    release({ ...process.env }); await client?.close(); await daemon.stop()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
