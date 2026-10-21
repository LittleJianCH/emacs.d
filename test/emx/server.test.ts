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
  return { daemon, session, savedText }
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
