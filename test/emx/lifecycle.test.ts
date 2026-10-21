import './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { Session } from '../../emx/daemon/session.ts'

for (const agent of ['claude', 'codex', 'dsh']) {
  for (const entry of ['backend', 'session'] as const) for (const cancel of [true, false]) test(`${agent} ${entry}: ${cancel ? 'stop cancels pending environment' : 'overlapping starts share initialization'}`, async () => {
    const dir = mkdtempSync('/tmp/emx-lifecycle-'), saved = { ...process.env }
    const prefix = 'EMX_' + agent.toUpperCase()
    const log = join(dir, 'calls.jsonl')
    process.env[prefix + '_LOG'] = log
    process.env.HOME = dir
    process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
    let release!: (env: NodeJS.ProcessEnv) => void, lookups = 0
    const gate = new Promise<NodeJS.ProcessEnv>((resolve) => { release = resolve })
    const session = new Session({ id: 'test', agent, root: dir, environment: () => { lookups++; return gate } })
    const backend = session.backend
    const lifecycle = entry === 'session' ? session : backend
    try {
      const first = Promise.resolve(lifecycle.start()).catch((e) => { throw e })
      const second = Promise.resolve(lifecycle.start())
      // Attach rejection handlers before stop rejects in-flight initialization.
      const starts = Promise.allSettled([first, second])
      const stopping = cancel ? lifecycle.stop() : undefined
      release({ ...process.env })
      await starts
      await stopping
      assert.equal(lookups, entry === 'session' && !cancel ? 2 : 1)
      if (cancel) {
        assert.equal(existsSync(log), false, 'a cancelled start must never spawn')
        assert.equal(backend.alive(), false)
        if (entry === 'session') assert.equal(session.status, 'exited')
      } else {
        const calls = readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
        assert.equal(calls.filter((m) => agent === 'claude' ? m.type === 'spawn' : m.method === 'initialize').length, 1)
        assert.equal(backend.alive(), true)
      }
    } finally {
      await backend.stop()
      for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]
      Object.assign(process.env, saved)
      rmSync(dir, { recursive: true, force: true })
    }
  })
}

// Exercise the public socket path while the daemon resolves a local simulated
// host environment; no SSH or real remote is involved.
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { DaemonClient } from './client.ts'
import { mkdirSync, writeFileSync } from 'node:fs'
import { setTimeout as delay } from 'node:timers/promises'

test('session/stop cancels session/open during project environment resolution', async () => {
  const dir = mkdtempSync('/tmp/emx-open-stop-')
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
  const daemon = new DaemonServer({ varDir: dir, remote: true })
  let release!: (env: NodeJS.ProcessEnv) => void
  const gate = new Promise<NodeJS.ProcessEnv>((resolve) => { release = resolve })
  daemon.environments!.get = () => gate
  let client: DaemonClient | undefined
  try {
    await daemon.start()
    client = await SocketClient.connect(daemon.socket)
    await client.request('hello', { client: 'test', version: daemon.version })
    const opening = client.request('session/open', { agent: 'echo', root: dir })
    while (!daemon.sessions.size) await delay(1)
    const session = [...daemon.sessions.values()][0]
    await client.request('session/stop', { id: session.id })
    release({ ...process.env })
    await opening
    assert.equal(session.status, 'exited')
    assert.equal(session.backend.alive(), false)
    assert.equal(daemon.sessions.size, 0)
  } finally {
    release({ ...process.env }); client?.close(); await daemon.stop()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a new Session.start does not reuse the environment wait cancelled by stop', async () => {
  let release!: (env: NodeJS.ProcessEnv) => void, lookups = 0
  const firstEnvironment = new Promise<NodeJS.ProcessEnv>((resolve) => { release = resolve })
  const session = new Session({ id: 'restart', agent: 'echo', root: '',
    environment: () => ++lookups === 1 ? firstEnvironment : Promise.resolve({ ...process.env }) })
  try {
    const first = session.start()
    await session.stop()
    const second = session.start()
    release({ ...process.env })
    await Promise.all([first, second])
    assert.equal(lookups, 2)
    assert.equal(session.backend.alive(), true)
    assert.equal(session.status, 'idle')
  } finally { release({ ...process.env }); await session.stop() }
})
