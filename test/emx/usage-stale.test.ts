// Stale upgrades require an atomic, capability-gated stop without editor takeover.
import * as assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { test } from 'node:test'
import { socketPath } from '../../emx/daemon/paths.ts'
import { Connection, Reply } from '../../emx/daemon/rpc.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'

const emx = resolve(import.meta.dirname, '../../bin/emx')
const run = promisify(execFile)
for (const capability of [false, true]) for (const live of [false, true]) {
  test(`ensure preserves stale code unless conditional stop succeeds (capability=${capability}, live=${live})`, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'emx-stale-'))
    const socket = socketPath(dir)
    mkdirSync(join(dir, 'emx'))
    writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({ collab: { handleCommand: [], agentHandleCommands: {} } }))
    mkdirSync(dirname(socket), { recursive: true })
    const calls: { method: string, params: any }[] = []
    const peers = new Set<Connection>()
    const server = createServer((socket) => {
      const peer = new Connection(socket); peers.add(peer)
      peer.onClose = () => peers.delete(peer)
      peer.onRequest = (method, params) => {
        calls.push({ method, params })
        if (method === 'ping') return { daemon: process.pid, version: 'old-code',
          ...(capability || live ? { liveAgents: 0, capabilities: { usage: 1, ...(capability ? { stopIfIdle: 1 } : {}) } } : {}) }
        if (method === 'daemon/stop') {
          // live=true models an agent launched just after the idle ping.
          if (capability && params.ifIdle && live) return { stopped: false }
          return new Reply({ stopped: true }, () => { peer.close(); server.close() })
        }
        throw new Error('Unexpected request: ' + method)
      }
    })
    await new Promise<void>((resolve) => server.listen(socket, resolve))
    try {
      const result = JSON.parse((await run(process.execPath, [emx, 'daemon', '--var', dir, '--ensure'], { timeout: 10000 })).stdout)
      const restarted = capability && !live
      assert.equal(result.stale, !restarted)
      assert.equal(result.started, restarted)
      if (!restarted) assert.equal(result.pid, process.pid)
      else assert.notEqual(result.version, 'old-code')
      assert.deepEqual(calls.filter((c) => c.method === 'daemon/stop'), capability
        ? [{ method: 'daemon/stop', params: { ifIdle: true } }] : [])
    } finally {
      for (const peer of peers) peer.socket.destroy()
      if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()))
      else await run(process.execPath, [emx, 'daemon', '--var', dir, '--stop'], { timeout: 10000 }).catch(() => {})
      rmSync(dir, { recursive: true, force: true })
    }
  })
}

test('conditional stop rechecks live and starting agents after ping, then commits an idle stop', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-conditional-'))
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({ collab: { handleCommand: [], agentHandleCommands: {} } }))
  const daemon = new DaemonServer({ varDir: dir }); await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  try {
    await client.request('hello', { client: 'test', version: '' })
    assert.equal((await client.request('ping', {})).liveAgents, 0)
    const { id } = await client.request('session/open', { agent: 'echo', root: dir })
    const session = daemon.sessions.get(id)!
    assert.deepEqual(await client.request('daemon/stop', { ifIdle: true }), { stopped: false })
    assert.equal(session.backend.alive(), true)
    await session.stop()
    session.setStatus('starting')
    assert.deepEqual(await client.request('daemon/stop', { ifIdle: true }), { stopped: false })
    session.setStatus('idle')
    assert.deepEqual(await client.request('daemon/stop', { ifIdle: true }), { stopped: true })
    await daemon.finished
  } finally { await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
})
