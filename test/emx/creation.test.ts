import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs'
import promises from 'node:fs/promises'
import { syncBuiltinESMExports } from 'node:module'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { DaemonClient } from './client.ts'

function directory() {
  const dir = mkdtempSync('/tmp/emx-creation-')
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
  return dir
}
function barrier() {
  let release!: () => void
  const promise = new Promise<void>((resolve) => { release = resolve })
  return { promise, release }
}
async function connect(daemon: DaemonServer) {
  const client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'creation', version: daemon.version })
  return client
}

for (const outcome of ['failed', 'closed'] as const) test(`creation retries preserve ${outcome} tombstones across restart`, async () => {
  const dir = directory(), gate = barrier(), entered = barrier()
  let daemon = new DaemonServer({ varDir: dir, remote: true }), client: DaemonClient | undefined
  daemon.environments!.get = async () => { entered.release(); await gate.promise; throw new Error('fixture initialization failed') }
  const params = { creationId: 'same-key', agent: 'echo', root: dir }
  try {
    await daemon.start(); client = await connect(daemon)
    if (outcome === 'failed') {
      const first = client.request('session/open', params)
      const failures = [assert.rejects(first, /fixture initialization failed/)]
      await entered.promise
      failures.push(assert.rejects(client.request('session/open', params), /fixture initialization failed/))
      await delay(20)
      gate.release()
      await Promise.all(failures)
    } else {
      daemon.environments!.get = async () => ({ ...process.env })
      const opened = await client.request('session/open', params)
      await client.request('session/stop', { id: opened.id })
    }
    assert.equal(daemon.sessions.size, 0)
    await assert.rejects(client.request('session/open', params), new RegExp(`is ${outcome}`))
    await client.close(); client = undefined; await daemon.stop()
    daemon = new DaemonServer({ varDir: dir }); await daemon.start(); client = await connect(daemon)
    await assert.rejects(client.request('session/open', params), new RegExp(`is ${outcome}`))
    assert.equal(daemon.sessions.size, 0)
    const fresh = await client.request('session/open', { ...params, creationId: 'intentional-new-key' })
    assert.ok(daemon.sessions.get(fresh.id)?.backend.alive())
  } finally { gate.release(); await client?.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
})

test('both open replies wait for the successful outcome to be persisted', async (t) => {
  const dir = directory(), gate = barrier(), entered = barrier()
  const daemon = new DaemonServer({ varDir: dir })
  let client: DaemonClient | undefined, replied = 0
  const original = promises.rename
  t.mock.method(promises, 'rename', async (from: Parameters<typeof original>[0], to: Parameters<typeof original>[1]) => {
    if (String(to) === join(dir, 'emx/sessions.json')
      && JSON.parse(readFileSync(from, 'utf8')).creations.some(([, r]: any) => r.state === 'open')) {
      entered.release(); await gate.promise
    }
    return original(from, to)
  })
  syncBuiltinESMExports()
  try {
    await daemon.start(); client = await connect(daemon)
    const params = { creationId: 'persistence', agent: 'echo', root: dir }
    const first = client.request('session/open', params).then((r) => { replied++; return r })
    await entered.promise
    const retry = client.request('session/open', params).then((r) => { replied++; return r })
    await delay(20); assert.equal(replied, 0)
    assert.equal(JSON.parse(readFileSync(join(dir, 'emx/sessions.json'), 'utf8')).creations[0][1].state, 'opening')
    gate.release()
    assert.deepEqual(await first, await retry)
  } finally {
    gate.release(); t.mock.restoreAll(); syncBuiltinESMExports()
    await client?.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true })
  }
})

test('cancelling an uncertain open closes its creation before startup finishes', async () => {
  const dir = directory(), gate = barrier(), entered = barrier()
  const daemon = new DaemonServer({ varDir: dir, remote: true })
  daemon.environments!.get = async () => { entered.release(); await gate.promise; return { ...process.env } }
  let client: DaemonClient | undefined
  try {
    await daemon.start(); client = await connect(daemon)
    const params = { creationId: 'lost-reply', agent: 'echo', root: dir }
    const failed = assert.rejects(client.request('session/open', params), /closed/)
    await entered.promise
    const cancel = client.request('session/cancel', { creationId: params.creationId })
    for (let i = 0; JSON.parse(readFileSync(join(dir, 'emx/sessions.json'), 'utf8')).creations[0][1].state !== 'closed'; i++) {
      assert.ok(i < 200); await delay(5)
    }
    await assert.rejects(client.request('session/open', params), /closed/)
    gate.release(); await Promise.all([cancel, failed])
    assert.equal(daemon.sessions.size, 0)
    await client.request('session/cancel', { creationId: 'cancel-before-open' })
    await assert.rejects(client.request('session/open', { ...params, creationId: 'cancel-before-open' }), /closed/)
  } finally { gate.release(); await client?.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
})

test('a crash during initialization leaves a failed durable creation, never a second backend', async () => {
  const dir = directory()
  const child = spawn(process.execPath, ['--input-type=module', '-e', `
    import { DaemonServer } from ${JSON.stringify(new URL('../../emx/daemon/server.ts', import.meta.url).href)};
    const server = new DaemonServer({ varDir: ${JSON.stringify(dir)}, remote: true });
    server.environments.get = () => new Promise(() => {});
    await server.start();
  `], { env: { ...process.env, HOME: dir }, stdio: ['ignore', 'ignore', 'pipe'] })
  let client: DaemonClient | undefined, restored: DaemonServer | undefined
  try {
    for (let i = 0; !existsSync(join(dir, 'emx/daemon.sock')); i++) { assert.ok(i < 500); await delay(5) }
    client = await SocketClient.connect(join(dir, 'emx/daemon.sock'))
    await client.request('hello', { client: 'crash-test', version: '' })
    const params = { creationId: 'crash-key', agent: 'echo', root: dir }
    const lost = client.request('session/open', params).catch(() => {})
    for (let i = 0; !existsSync(join(dir, 'emx/sessions.json')); i++) { assert.ok(i < 500); await delay(5) }
    assert.equal(JSON.parse(readFileSync(join(dir, 'emx/sessions.json'), 'utf8')).creations[0][1].state, 'opening')
    const exited = once(child, 'exit'); child.kill('SIGKILL'); await exited; await lost
    await client.close(); restored = new DaemonServer({ varDir: dir }); await restored.start(); client = await connect(restored)
    await assert.rejects(client.request('session/open', params), /failed.*Daemon stopped during session creation/)
    assert.equal(restored.sessions.size, 0)
  } finally {
    child.kill('SIGKILL'); await client?.close(); await restored?.stop(); rmSync(dir, { recursive: true, force: true })
  }
})

for (const fails of [false, true]) test(`a second creation resuming a pending session waits for its outcome (${fails})`, async () => {
  const dir = directory(), entered = barrier(), gate = barrier()
  const daemon = new DaemonServer({ varDir: dir, remote: true })
  let client: DaemonClient | undefined
  daemon.environments!.get = async () => {
    entered.release(); await gate.promise
    if (fails) throw new Error('fixture resume initialization failed')
    return { ...process.env }
  }
  try {
    await daemon.start(); client = await connect(daemon)
    const params = { creationId: 'resume-original', agent: 'echo', root: dir, resume: 'native-resume' }
    const first = client.request('session/open', params)
    const result = first.then((r) => r, (e) => e)
    await entered.promise
    let replied = false
    const second = client.request('session/open', { ...params, creationId: 'resume-alias' })
      .then((r) => { replied = true; return r }, (e) => { replied = true; return e })
    await delay(20); assert.equal(replied, false)
    gate.release()
    const [a, b] = await Promise.all([result, second])
    if (fails) {
      assert.match(a.message, /fixture resume initialization failed/)
      assert.match(b.message, /fixture resume initialization failed/)
      await assert.rejects(client.request('session/open', { ...params, creationId: 'resume-alias' }), /failed/)
    } else {
      assert.deepEqual(a, b)
      assert.equal(daemon.sessions.size, 1)
      await client.request('session/stop', { id: a.id })
      await assert.rejects(client.request('session/open', { ...params, creationId: 'resume-alias' }), /closed/)
    }
  } finally { gate.release(); await client?.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
})
