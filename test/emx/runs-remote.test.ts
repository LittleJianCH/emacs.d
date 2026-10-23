// Host run rows share the durable usage stream and retain their daemon identity.
import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { appendFileSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import { SocketClient } from './client.ts'
import type { DaemonClient } from './client.ts'

function config() {
  const value = JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
  value.collab.handleCommand = []; value.collab.agentHandleCommands = {}; value.usage.pollInterval = 0
  value.agents.echo = { title: 'Echo', executable: process.execPath }
  value.profiles.echo = { agent: 'echo' }
  return value
}
async function setup(remote = false) {
  const dir = mkdtempSync(join(tmpdir(), 'emx-runs-remote-'))
  mkdirSync(join(dir, 'emx'))
  const file = join(dir, 'config.json'); writeFileSync(file, JSON.stringify(config()))
  let daemon: DaemonServer, client: DaemonClient
  const start = async () => {
    daemon = new DaemonServer({ varDir: dir, configFile: file, remote })
    await daemon.start()
    client = await SocketClient.connect(daemon.socket)
    await client.request('hello', { client: 'runs-test', version: '' })
  }
  await start()
  return { dir, get daemon() { return daemon }, get client() { return client },
    restart: async () => { await client.close(); await daemon.stop(); await start() },
    cleanup: async () => { await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) } }
}
const run = (number = 1, session = 'same-parent', profile = 'echo') => ({
  type: 'run', run: number, start: Date.now() / 1000, end: Date.now() / 1000, duration: 1,
  parent: { session }, profile, agent: 'echo', model: 'actual', outcome: 'ok',
  tokens: { input: 1, cache_read: 2, cache_write: 3, output: 4 },
})
const rating = (score: number, session = 'same-parent') => ({ type: 'rating', run: 1, time: Date.now() / 1000, session, score })

test('host appends both run and rating rows to its durable outbox and keeps its own log', async () => {
  const t = await setup(true)
  try {
    const { id } = await t.client.request('session/open', { agent: 'echo', root: t.dir })
    const parent = t.daemon.sessions.get(id)!
    parent.setStatus('running')
    t.daemon.collab.host.view = async (child) => { child.backend.send = () => { child.setStatus('running') } }
    const signal = new AbortController().signal
    await t.daemon.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'task', handle: 'worker' }, signal)
    await t.daemon.collab.call(parent, 'session_stop', { session: '@worker' }, signal)
    await t.daemon.collab.call(parent, 'session_rate', { run: 1, score: 9 }, signal)
    const rows = t.daemon.collab.runLog()
    assert.deepEqual(rows.map((r) => r.type), ['run', 'rating'])
    const entries = t.daemon.outbox!.entries.filter((entry) => entry.method === 'runs/record')
    assert.deepEqual(entries.map((entry) => entry.params.row), rows)
    assert.ok(entries.every((entry) => entry.source && entry.sequence > 0))
    const saved = JSON.parse(readFileSync(t.daemon.outbox!.file, 'utf8'))
    assert.deepEqual(saved.entries.filter((e: any) => e.method === 'runs/record'), entries)
    await assert.rejects(t.client.request('runs/record', { id: 'bad', source: 'other', sequence: 1, host: 'other', row: run() }), /local daemon/)
  } finally { await t.cleanup() }
})

test('mixed usage, run, quota and rating deliveries deduplicate and recover a missing watermark', async () => {
  const t = await setup()
  try {
    const entry = { id: 'run', source: 'producer', sequence: 2, host: 'dev', row: run() }
    await assert.rejects(t.client.request('runs/record', entry), /sequence gap/)
    await t.client.request('usage/record', { id: 'usage', source: 'producer', sequence: 1, record: { agent: 'echo', input: 5 } })
    assert.deepEqual(await t.client.request('runs/record', entry), { id: 'run', source: 'producer', sequence: 2 })
    await t.client.request('runs/record', { ...entry, id: 'replayed' })
    assert.equal(t.daemon.collab.runLog().length, 1)
    await t.client.request('usage/quota', { id: 'quota', source: 'producer', sequence: 3, reading: { agent: 'echo', host: 'dev' } })
    const score = { id: 'rating', source: 'producer', sequence: 4, host: 'dev', row: rating(8) }
    await t.client.request('runs/record', score)
    const rows = t.daemon.collab.runLog()
    assert.deepEqual(rows.map((r) => r.host), ['dev', 'dev'])
    assert.deepEqual(rows[1]._delivery, { source: 'producer', sequence: 4 })
    // Simulate a crash after durable append and before advancing the watermark.
    t.daemon.usage.watermarks.producer = 3
    writeFileSync(t.daemon.usage.watermarkFile, JSON.stringify({ producer: 3 }))
    appendFileSync(join(t.dir, 'emx/subagent-runs.jsonl'), '{"type":"run"')
    await t.restart()
    assert.deepEqual(await t.client.request('runs/record', score), { id: 'rating', source: 'producer', sequence: 4 })
    assert.equal(t.daemon.collab.runLog().length, 2)
    await t.client.request('usage/record', { id: 'next', source: 'producer', sequence: 5, record: { agent: 'echo', input: 7 } })
    await t.client.request('runs/record', { ...score, id: 'after-truncated-line', sequence: 6, row: rating(8) })
    assert.equal(t.daemon.collab.runLog().length, 3)
    await t.restart()
    await t.client.request('runs/record', { ...score, id: 'after-truncated-line', sequence: 6, row: rating(8) })
    assert.equal(t.daemon.collab.runLog().length, 3)
    const groups = (await t.client.request('collab/runs', {})).groups
    assert.equal(groups[0].score, 8)
    assert.equal((await t.client.request('usage/report', { range: 'all' })).total.input, 12)
    for (const row of [{ ...rating(11) }, { ...run(), run: 0 }, { ...run(), tokens: {} }, { type: 'other', run: 1 }]) {
      await assert.rejects(t.client.request('runs/record', { ...entry, sequence: 7, row }), { code: -32602 })
    }
  } finally { await t.cleanup() }
})

test('host capture survives a run log write failure', async () => {
  const t = await setup(true)
  try {
    const { id } = await t.client.request('session/open', { agent: 'echo', root: t.dir })
    const parent = t.daemon.sessions.get(id)!
    parent.setStatus('running')
    t.daemon.collab.host.view = async (child) => { child.backend.send = () => { child.setStatus('running') } }
    const signal = new AbortController().signal
    await t.daemon.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'task', handle: 'worker' }, signal)
    // A directory where the log should be makes its append fail independently.
    mkdirSync(join(t.dir, 'emx/subagent-runs.jsonl'))
    await t.daemon.collab.call(parent, 'session_stop', { session: '@worker' }, signal)
    const entries = t.daemon.outbox!.entries.filter((entry) => entry.method === 'runs/record')
    assert.equal(entries.length, 1)
    assert.equal(entries[0].params.row.type, 'run')
    assert.equal(entries[0].params.row.run, 1)
    assert.equal(JSON.parse(readFileSync(t.daemon.outbox!.file, 'utf8')).entries.filter((e: any) => e.method === 'runs/record').length, 1)
    rmSync(join(t.dir, 'emx/subagent-runs.jsonl'), { recursive: true })
  } finally { await t.cleanup() }
})

test('reports join ratings by host and run, check owners, and still merge model groups', async () => {
  const t = await setup()
  try {
    const file = join(t.dir, 'emx/subagent-runs.jsonl')
    writeFileSync(file, [run(), rating(2)].map((row) => JSON.stringify(row)).join('\n') + '\n')
    for (const [host, score] of [['a', 8], ['b', 4]] as const) {
      await t.client.request('runs/record', { id: host, source: host, sequence: 1, host, row: run() })
      await t.client.request('runs/record', { id: host + '-rating', source: host, sequence: 2, host, row: rating(score) })
    }
    // A newer rating by a different owner on a host must not overwrite its score.
    await t.client.request('runs/record', { id: 'unauthorized', source: 'b', sequence: 3, host: 'b', row: rating(10, 'stranger') })
    const [group] = (await t.client.request('collab/runs', {})).groups
    assert.equal(group.runs, 3); assert.equal(group.rated, 3); assert.equal(group.score, 4.7)
    assert.deepEqual(group.tokens, { input: 3, cache_read: 6, cache_write: 9, output: 12 })
    // A local rating cannot authorize itself using a relayed row, even if ids match.
    const { id } = await t.client.request('session/open', { agent: 'echo', root: t.dir })
    await t.client.request('runs/record', { id: 'host-only', source: 'c', sequence: 1, host: 'c', row: run(99, id) })
    await assert.rejects(t.daemon.collab.call(t.daemon.sessions.get(id)!, 'session_rate', { run: 99, score: 10 }, new AbortController().signal), /isn't one you started/)
  } finally { await t.cleanup() }
})

test('restore ignores host rows when allocating run numbers and pruning active children', async () => {
  const t = await setup()
  try {
    const { id } = await t.client.request('session/open', { agent: 'echo', root: t.dir })
    const parent = t.daemon.sessions.get(id)!
    parent.setStatus('running')
    t.daemon.collab.host.view = async (child) => { child.backend.send = () => { child.setStatus('running') } }
    await t.daemon.collab.call(parent, 'session_start', { profile: 'echo', prompt: 'task' }, new AbortController().signal)
    await t.client.request('runs/record', { id: 'collision', source: 'a', sequence: 1, host: 'a', row: run() })
    await t.client.request('runs/record', { id: 'larger', source: 'a', sequence: 2, host: 'a', row: run(500) })
    await t.restart()
    assert.equal(t.daemon.collab.runs, 1)
    assert.equal(t.daemon.collab.runLog().filter((row) => row.host == null && row.run === 1 && row.outcome === 'closed').length, 1)
    // Even without collab.json, only the local log determines the counter.
    unlinkSync(join(t.dir, 'emx/collab.json'))
    await t.restart()
    assert.equal(t.daemon.collab.runs, 1)
  } finally { await t.cleanup() }
})
