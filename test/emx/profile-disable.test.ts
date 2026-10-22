import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { mkdtempSync, readFileSync, writeFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Configuration, merge, validate } from '../../emx/config.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import { SocketClient } from './client.ts'

async function setup(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), 'emx-profile-disable-'))
  const config = JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}; config.usage.pollInterval = 0
  config.collab.disabled = ['default-disabled']
  config.profiles.worker = { candidates: [
    { agent: 'codex' }, { agent: 'codex', model: 'provider/model:version/variant' },
    { agent: 'codex', model: 'other' }, { agent: 'claude', model: 'sonnet' },
  ] }
  config.profiles.legacy = { agent: 'codex' }
  const file = join(dir, 'defaults.json')
  writeFileSync(file, JSON.stringify(config))
  const daemon = new DaemonServer({ varDir: dir, configFile: file })
  await daemon.start(); daemon.configuration.close()
  const client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'test', version: '' })
  t.after(async () => { await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) })
  const worker = async () => (await client.request('collab/profiles', {})).profiles.find((p) => p.name === 'worker')!
  return { dir, file, daemon, client, worker }
}

test('collab/disable preserves current disk updates, defaults and other overlay keys without a watcher', async (t) => {
  const { dir, file, daemon, client } = await setup(t)
  const stale = await client.request('config/get', {})
  const writer = new Configuration(dir, file)
  writer.close()
  try {
    writer.set(['agents', 'codex', 'quotaSkip'], 0.75)
    writer.set(['collab', 'disabled'], ['default-disabled', 'external:claude', 'worker:codex/other'])
    assert.deepEqual(daemon.configuration.value.collab.disabled, stale.config.collab.disabled)
    const result = await client.request('collab/disable', { profile: 'worker', candidate: 0, disabled: true })
    assert.deepEqual(Object.keys(result), ['config'])
    assert.deepEqual(result.config.collab.disabled,
      ['default-disabled', 'external:claude', 'worker:codex/other', 'worker:codex/'])
    assert.equal(result.config.agents.codex.quotaSkip, 0.75)
    await client.waitFor((n) => n.method === 'config' && n.params.config.collab.disabled.includes('worker:codex/'))
    assert.deepEqual(JSON.parse(readFileSync(daemon.configuration.override, 'utf8')), {
      agents: { codex: { quotaSkip: 0.75 } }, collab: { disabled: result.config.collab.disabled },
    })
    // Multiple pending edits serialize within the daemon, with no stale read between them.
    await Promise.all([
      client.request('collab/disable', { profile: 'worker', candidate: 1, disabled: true }),
      client.request('collab/disable', { profile: 'legacy', disabled: true }),
    ])
    const disabled = (await client.request('config/get', {})).config.collab.disabled
    assert.ok(disabled.includes('worker:codex/'))
    assert.ok(disabled.includes('worker:codex/provider/model:version/variant'))
    assert.ok(disabled.includes('external:claude'))
    assert.ok(disabled.includes('legacy'))
    const last = await client.request('collab/disable', { profile: 'legacy', candidate: 0, disabled: true })
    assert.ok(last.config.collab.disabled.includes('legacy:codex/'), 'legacy candidates use the same exact default form')
  } finally { writer.close() }
})

test('enabling a candidate expands broad entries, removes all its exact entries and preserves siblings', async (t) => {
  const { client, worker } = await setup(t)
  const model = 'worker:codex/provider/model:version/variant'
  await client.request('config/set', { path: ['collab', 'disabled'], value: [
    'worker', 'worker:codex', model, model, 'worker:claude/sonnet', 'unrelated:codex', 'unrelated:codex',
  ] })
  assert.deepEqual((await worker()).candidates[1].disabledBy, ['worker', 'worker:codex', model, model])
  const enabled = await client.request('collab/disable', { profile: 'worker', candidate: 1, disabled: false })
  assert.deepEqual(enabled.config.collab.disabled,
    ['worker', 'worker:claude/sonnet', 'unrelated:codex', 'unrelated:codex', 'worker:codex/', 'worker:codex/other'])
  assert.deepEqual((await worker()).candidates[1].disabledBy, ['worker'], 'a candidate cannot clear its whole profile')
  const result = await client.request('collab/disable', { profile: 'worker', disabled: false })
  assert.deepEqual(result.config.collab.disabled,
    ['worker:claude/sonnet', 'unrelated:codex', 'unrelated:codex', 'worker:codex/', 'worker:codex/other'])
  assert.deepEqual((await worker()).candidates.map((c) => c.disabled), [true, false, true, true])
  assert.deepEqual((await worker()).candidates.map((c) => c.disabledBy),
    [['worker:codex/'], [], ['worker:codex/other'], ['worker:claude/sonnet']])
  // Enabling the default candidate under an agent-wide entry preserves named models.
  await client.request('config/set', { path: ['collab', 'disabled'], value: ['worker:codex'] })
  await client.request('collab/disable', { profile: 'worker', candidate: 0, disabled: false })
  assert.deepEqual((await worker()).candidates.map((c) => c.disabled), [false, true, true, false])
})

test('candidate disable is exact, idempotent and distinguishes omitted models from same-agent siblings', async (t) => {
  const { client, worker } = await setup(t)
  for (const candidate of [0, 1, 2, 3]) {
    const token = ['worker:codex/', 'worker:codex/provider/model:version/variant', 'worker:codex/other', 'worker:claude/sonnet'][candidate]
    for (const disabled of [true, true, false, false]) {
      const result = await client.request('collab/disable', { profile: 'worker', candidate, disabled })
      assert.deepEqual(result.config.collab.disabled, disabled ? ['default-disabled', token] : ['default-disabled'])
      const candidates = (await worker()).candidates
      assert.deepEqual(candidates.map((c) => c.disabled), candidates.map((_, i) => disabled && i === candidate))
      assert.deepEqual(candidates[candidate].disabledBy, disabled ? [token] : [])
    }
  }
})

test('invalid collab/disable requests and malformed disk policy fail without publication', async (t) => {
  const { client, daemon } = await setup(t)
  await client.request('config/set', { path: ['collab', 'disabled'], value: [] })
  const saved = readFileSync(daemon.configuration.override, 'utf8'), inode = statSync(daemon.configuration.override).ino
  for (const params of [
    {}, { profile: '' }, { profile: 42 }, { profile: 'missing', disabled: true },
    { profile: 'worker', disabled: null }, { profile: 'worker', disabled: 'false' },
    ...[-1, 0.5, 4, null, '0'].map((candidate) => ({ profile: 'worker', candidate, disabled: true })),
  ]) {
    await assert.rejects(client.request('collab/disable', params as any), /collab\/disable|Unknown profile/)
    assert.equal(readFileSync(daemon.configuration.override, 'utf8'), saved)
    assert.equal(statSync(daemon.configuration.override).ino, inode)
  }
  for (const invalid of ['{', JSON.stringify({ collab: { disabled: ['worker:'] } })]) {
    writeFileSync(daemon.configuration.override, invalid)
    await assert.rejects(client.request('collab/disable', { profile: 'worker', disabled: true }))
    assert.equal(readFileSync(daemon.configuration.override, 'utf8'), invalid)
  }
})

test('disabled entry validation splits the first colon and slash, allowing opaque models and an empty default suffix', () => {
  const config = JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
  const disabled = ['worker', 'worker:codex', 'worker:codex/', 'worker:codex/provider/model:version/variant', 'unknown:agent/model']
  assert.deepEqual(validate(merge(config, { collab: { disabled } })).collab.disabled, disabled)
  for (const entry of ['', ':codex', 'worker:', 'worker:/model', ':codex/']) {
    assert.throws(() => validate(merge(config, { collab: { disabled: [entry] } })), /config.collab.disabled/)
  }
  assert.throws(() => validate(merge(config, { profiles: { 'bad:name': { agent: 'codex' } } })), /profile name/)
  assert.throws(() => validate(merge(config, { agents: { 'bad/name': config.agents.codex } })), /agent name/)
})

test('host configuration rejects collab/disable without changing its overlay', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-profile-disable-host-')), file = join(dir, 'host.json')
  const config = new Configuration(dir, undefined, file)
  try {
    writeFileSync(file, '{}\n')
    assert.throws(() => config.disable('coder', 0, true), /only available on local daemons/)
    assert.equal(readFileSync(file, 'utf8'), '{}\n')
  } finally { config.close(); rmSync(dir, { recursive: true, force: true }) }
})
