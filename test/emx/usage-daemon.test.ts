// Usage ownership, producer-only accounting, restart and fake quota polling.
import * as assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { UsageService, readLedger } from '../../emx/usage/service.ts'
import { SocketClient } from './client.ts'

async function setup(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), 'emx-account-'))
  const daemon = new DaemonServer({varDir: dir})
  await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  t.after(async () => { await client.close(); await daemon.stop(); rmSync(dir, {recursive: true, force: true}) })
  await client.request('hello', {client: 'account-test', version: daemon.version})
  const {id} = await client.request('session/open', {agent: 'echo', root: '/tmp/project/', handle: 'turn-test', parent: 'parent'})
  const session = daemon.sessions.get(id)!
  const ledger = () => readLedger(join(dir, 'agent-usage.jsonl'))
  return {dir, daemon, client, id, session, ledger}
}

const call = (input: number) => ({input, cacheRead: 2, cacheWrite: 3, output: 4})

test('multiple calls/models count one child turn; zero records and replay never count', async (t) => {
  const {client, id, session, ledger} = await setup(t)
  await client.request('session/attach', {id})
  session.emit({type: 'usage/call', model: 'empty', usage: {input: 0, cacheRead: 0, cacheWrite: 0, output: 0}})
  session.emit({type: 'usage/call', model: 'a', usage: call(1)})
  session.emit({type: 'usage/call', model: 'a', usage: call(5)})
  session.emit({type: 'usage/call', model: 'b', usage: call(7)})
  session.emit({type: 'usage/end'})
  session.emit({type: 'usage/end'})
  assert.deepEqual(ledger().map(({model, input, turns, child, root, session}) => ({model, input, turns, child, root, session})), [
    {model: 'a', input: 6, turns: 1, child: true, root: '/tmp/project/', session: 'turn-test'},
    {model: 'b', input: 7, turns: 0, child: true, root: '/tmp/project/', session: 'turn-test'},
  ])
  const after = {epoch: session.epoch, seq: 0}
  await client.request('session/attach', {id, after})
  await client.request('session/attach', {id})
  assert.equal(ledger().length, 2)
  assert.equal(session.log.some((e) => e.type.startsWith('usage/') || e.type.startsWith('quota')), false)
  assert.equal(client.notifications.some((e) => ['usage/call', 'usage/end', 'quota', 'quota/rate-limits'].includes(e.method)), false)
  assert.equal((await client.request('usage/report', {range: 'all'})).total.child_turns, 1)
})

test('detached accounting and process exit flush once; Lisp notifications use the same writer', async (t) => {
  const {daemon, client, id, session, ledger, dir} = await setup(t)
  await client.close()
  session.emit({type: 'usage/call', model: 'crash', usage: call(10)})
  session.setStatus('exited')
  session.emit({type: 'usage/end'})
  session.emit({type: 'quota/rate-limits', rateLimits: {windows: [
    {id: 'seven_day_opus', minutes: 10080, used: 0.5, resets: 2000000000} ]}})
  const peer = await SocketClient.connect(daemon.socket)
  try {
    await peer.request('hello', {client: 'new-editor', version: daemon.version})
    peer.notify('usage/record', {record: {agent: 'claude', root: '/rpc:dev:/project/', session: 'lisp', model: 'lisp', input: 3, turns: 1}})
    peer.notify('usage/quota', {agent: 'dsh', host: 'dev', balance: [{amount: 9, currency: 'CNY'}]})
    const report = await peer.request('usage/report', {range: 'all'})
    assert.equal(report.total.tokens, 22)
    assert.equal(report.total.turns, 2)
    assert.equal(report.quotas[0].windows[0].label, '周·Opus')
    assert.equal(ledger().length, 2)
    const before = ledger()
    await peer.request('session/attach', {id})
    assert.deepEqual(ledger(), before)
    await peer.request('usage/clear', {})
    assert.equal((await peer.request('usage/report', {range: 'all'})).total.tokens, 0)
    assert.equal(JSON.parse(readFileSync(join(dir, 'agent-quota.json'), 'utf8')).length, 2)
  } finally { await peer.close() }
})

test('fake quota poll commands persist and poll without an editor after restart', async (t) => {
  const {daemon, client, dir} = await setup(t)
  const fixture = new URL('./fixtures/usage-poller.mjs', import.meta.url).pathname
  const executables = Object.fromEntries(['claude', 'codex', 'dsh'].map((source) => {
    const file = join(dir, source)
    writeFileSync(file, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(fixture)} ${source} "$@"\n`)
    chmodSync(file, 0o700)
    return [source, { executable: file }]
  }))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({ agents: executables,
    usage: { pollInterval: 900 }, collab: { handleCommand: [], agentHandleCommands: {} } }))
  await client.request('config/reload', {})
  await client.request('usage/configure', {agents: ['claude', 'codex', 'dsh']})
  const pollers = structuredClone(daemon.usage.pollers)
  await daemon.usage.pollAll(true)
  // configure may already have started each source; wait for its quota pushes.
  for (const source of ['claude', 'codex', 'dsh']) {
    await client.waitFor((n) => n.method === 'usage/quotas' && n.params.quotas.some((q: any) => q.agent === source))
  }
  assert.equal(daemon.usage.quotas.find((q) => q.agent === 'claude')!.windows[0].used, 0.25)
  assert.equal(daemon.usage.quotas.find((q) => q.agent === 'codex')!.credits, 'unlimited')
  assert.equal(daemon.usage.quotas.find((q) => q.agent === 'dsh')!.balance![0].amount, 9.03)
  await client.close()
  await daemon.stop()
  const stored = JSON.parse(readFileSync(join(dir, 'emx/usage.json'), 'utf8'))
  stored.pollers = { claude: { command: ['/removed/lisp/poller'] } }
  writeFileSync(join(dir, 'emx/usage.json'), JSON.stringify(stored))
  const restarted = new DaemonServer({varDir: dir})
  try {
    await restarted.start()
    assert.deepEqual(restarted.usage.pollers, pollers)
    assert.equal(restarted.usage.pollInterval, 900)
    assert.ok(restarted.usage.timer)
    await restarted.usage.pollAll(true)
    assert.equal(restarted.usage.quotas.length, 3)
    assert.equal(readLedger(join(dir, 'agent-usage.jsonl')).length, 0, 'polling does not charge model usage')
  } finally { await restarted.stop() }
})

test('a second daemon cannot become a ledger writer for the same var directory', async (t) => {
  const {dir, daemon, client} = await setup(t)
  const other = new DaemonServer({varDir: dir})
  await assert.rejects(other.start(), /lock|running/i)
  assert.equal(other.usage.initialized, false)
  assert.equal((await client.request('usage/report', {range: 'all'})).total.tokens, 0)
  assert.ok(daemon.usage.initialized)
})

test('a stopped quota poll cannot publish a late reading after releasing ownership', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-late-quota-'))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  let finish!: (reading: {agent: string, windows: []}) => void
  const reading = new Promise<{agent: string, windows: []}>((resolve) => { finish = resolve })
  const sent: unknown[] = []
  const service = new UsageService({send: (message) => { sent.push(message) }, fetchers: {claude: () => reading}})
  service.initialize({usageFile: join(dir, 'agent-usage.jsonl'), quotaFile: join(dir, 'agent-quota.json'), pollInterval: 0,
    pollers: {claude: {command: ['fake']}}})
  service.pollInterval = 900
  const pending = service.pollAll(true)
  service.stop()
  finish({agent: 'claude', windows: []})
  await pending
  assert.deepEqual(sent, [])
  assert.deepEqual(service.loadQuotas(), [])
})


test('two usage subscribers do not replace the editor or each other', async (t) => {
  const {daemon, client, ledger} = await setup(t)
  const a = await SocketClient.connect(daemon.socket)
  const b = await SocketClient.connect(daemon.socket)
  t.after(async () => { await a.close(); await b.close() })
  for (const peer of [a, b]) {
    const hello = await peer.request('usage/hello', {})
    assert.equal(hello.capabilities?.usage, 1)
    await assert.rejects(peer.request('sessions/list', {}), /usage/i)
  }
  assert.deepEqual(await a.request('usage/record', {id: 'a', record: {agent: 'claude', input: 3}}), {id: 'a'})
  assert.deepEqual(await b.request('usage/record', {id: 'b', record: {agent: 'codex', input: 5}}), {id: 'b'})
  await a.request('usage/quota', {id: 'q', reading: {agent: 'codex', windows: [{id: 'week', used: 0.5}]}})
  for (const peer of [a, b]) await peer.waitFor((n) => n.method === 'usage/quotas' && n.params.quotas.length > 0)
  assert.equal((await a.request('usage/report', {range: 'all'})).total.tokens, 8)
  assert.equal((await client.request('sessions/list', {})).sessions.length, 1)
  assert.equal(ledger().length, 2)
  for (const peer of [client, a, b]) assert.ok(!peer.notifications.some((n) => n.method === 'replaced'))
})

test('acknowledged ids dedupe uncertain delivery even after daemon restart', async (t) => {
  const {daemon, client, dir, ledger} = await setup(t)
  const record = {id: 'uncertain-record', record: {agent: 'codex', input: 7}}
  const quota = {id: 'uncertain-quota', reading: {agent: 'codex', windows: [{id: 'week', used: 0.5}]}}
  await client.request('usage/record', record)
  await client.request('usage/quota', quota)
  await client.close()
  await daemon.stop()
  const restarted = new DaemonServer({varDir: dir})
  await restarted.start()
  const peer = await SocketClient.connect(restarted.socket)
  try {
    await peer.request('usage/hello', {})
    assert.deepEqual(await peer.request('usage/record', record), {id: record.id})
    const before = readFileSync(join(dir, 'agent-quota.json'), 'utf8')
    assert.deepEqual(await peer.request('usage/quota', quota), {id: quota.id})
    assert.equal(readFileSync(join(dir, 'agent-quota.json'), 'utf8'), before)
    assert.equal(ledger().length, 1)
    assert.equal((await peer.request('usage/report', {range: 'all'})).total.tokens, 7)
  } finally { await peer.close(); await restarted.stop() }
})


test('an idle-only restart rechecks turns and ephemeral children before stopping', async (t) => {
  const {client, session} = await setup(t)
  session.setStatus('running')
  await assert.rejects(client.request('daemon/stop', {idleOnly: true}), /Finish active/)
  session.setStatus('idle')
  await assert.rejects(client.request('daemon/stop', {idleOnly: true}), /children/)
  delete session.info.parent
  await client.request('daemon/stop', {idleOnly: true})
})
