import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'

const fixture = fileURLToPath(new URL('./fixtures/codex.mjs', import.meta.url))

test('acme uses its protocol for history, models, forks, selection and daemon restore', async (t) => {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-agent-kind-')))
  await mkdir(join(dir, 'emx'))
  await writeFile(join(dir, 'emx/config.json'), JSON.stringify({
    agents: { acme: { backend: 'codex', title: 'Acme', executable: fixture, extraArgs: ['--acme'] },
      codex: { executable: '/does-not-exist' }, echo: { title: 'Echo', executable: process.execPath } },
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  let daemon = new DaemonServer({ varDir: dir })
  await daemon.start()
  let client = await SocketClient.connect(daemon.socket)
  t.after(async () => { await client.close(); await daemon.stop(); await rm(dir, { recursive: true, force: true }) })
  await client.request('hello', { client: 'test', version: '', agents: ['acme', 'echo'] })
  const models = (await client.request('agents/models', { agent: 'acme' })).models
  assert.deepEqual(models, [{ id: 'fake-cheap', label: 'Cheap' }])
  await client.request('config/set', { path: ['agents', 'acme', 'models'], value: { include: ['^fake'], exclude: ['cheap'] } })
  assert.deepEqual((await client.request('agents/models', { agent: 'acme' })).models, [])
  await client.request('config/set', { path: ['agents', 'acme', 'models'], value: null })
  const { items } = await client.request('sessions/history', { agent: 'acme', root: dir })
  assert.equal(items.length, 1)
  assert.equal(daemon.sessions.size, 0, 'discovery never opens a session')
  await client.request('usage/configure', { agents: ['acme'] })
  assert.deepEqual(daemon.usage.pollers.acme, { backend: 'codex', command: [fixture, '--acme'] })
  const opened = await client.request('session/open', { agent: 'acme', root: dir, resume: items[0].id })
  const source = daemon.sessions.get(opened.id)!
  assert.equal(source.agent, 'acme')
  assert.ok(source.blocks.some((b) => b.type === 'text' && b.text === 'reply 1'))
  assert.ok(daemon.usage.quotas.some((q) => q.agent === 'acme'))
  assert.ok(!daemon.usage.quotas.some((q) => q.agent === 'codex'))
  const fork = await client.request('session/open', { fork: opened.id, root: dir })
  assert.equal(daemon.sessions.get(fork.id)!.agent, 'acme')
  assert.notEqual(daemon.sessions.get(fork.id)!.resumeId(), source.resumeId())
  const echo = await client.request('session/open', { agent: 'echo', root: dir })
  await client.request('session/select', { id: echo.id, agent: 'acme', model: null, unrestricted: true })
  assert.equal(daemon.sessions.get(echo.id)!.agent, 'acme')
  assert.equal(daemon.sessions.get(echo.id)!.capabilities.models[0].id, 'fake-cheap')
  await client.request('session/select', { id: source.id, agent: 'acme', model: null, unrestricted: true })
  assert.equal(source.settings.mode, 'edits', 'default mode follows the protocol kind')
  await client.close(); await daemon.stop()
  daemon = new DaemonServer({ varDir: dir })
  await daemon.start(); client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'test', version: '' })
  const restored = daemon.sessions.get(opened.id)!
  assert.equal(restored.agent, 'acme')
  await restored.restart()
  assert.equal(restored.resumeId(), items[0].id)
  assert.equal(restored.status, 'idle')
})
