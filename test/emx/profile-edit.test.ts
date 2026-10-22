import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import { Configuration } from '../../emx/config.ts'
import { profileCandidates } from '../../emx/daemon/collab.ts'
import { SocketClient } from './client.ts'

test('profile candidates override either form, validate atomically and restore defaults on the wire', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-profile-edit-'))
  const config = JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}; config.usage.pollInterval = 0
  config.profiles.legacy = { agent: 'claude', model: 'sonnet', effort: 'high', mode: 'ask', description: 'Legacy' }
  const file = join(dir, 'defaults.json')
  writeFileSync(file, JSON.stringify(config))
  const daemon = new DaemonServer({ varDir: dir, configFile: file })
  await daemon.start(); daemon.configuration.close()
  const client = await SocketClient.connect(daemon.socket)
  t.after(async () => { await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) })
  await client.request('hello', { client: 'test', version: '' })
  const catalog = async (name: string) => (await client.request('collab/profiles', {})).profiles.find((p) => p.name === name)!
  assert.equal((await catalog('legacy')).overridden, false)
  assert.equal((await catalog('legacy')).candidates[0].mode, 'ask')
  assert.equal((await catalog('legacy')).candidates[0].effort, 'high')
  const candidates = [{ agent: 'pi', model: 'opencode-go/grok', effort: 'low', mode: 'auto' }]
  for (const name of ['legacy', 'coder']) {
    // Simulate an older single-agent override over either kind of default.
    await client.request('config/set', { path: ['profiles', name], value: { agent: 'claude', model: 'haiku', effort: 'high', mode: 'ask' } })
    assert.equal((await catalog(name)).candidates[0].model, 'haiku')
    const result = await client.request('config/set', { path: ['profiles', name, 'candidates'], value: candidates })
    assert.deepEqual(profileCandidates(result.config.profiles[name]), candidates)
    assert.deepEqual(JSON.parse(readFileSync(daemon.configuration.override, 'utf8')).profiles[name], { candidates })
    const profile = await catalog(name)
    assert.equal(profile.overridden, true)
    assert.equal(profile.candidates[0].mode, 'auto')
    assert.equal(profile.candidates[0].effort, 'low')
    const saved = readFileSync(daemon.configuration.override, 'utf8')
    for (const value of [[], [{ agent: 'unknown' }], [{ agent: 'pi', mode: 'unsafe' }]]) {
      await assert.rejects(client.request('config/set', { path: ['profiles', name, 'candidates'], value }), /config.profiles/)
      assert.equal(readFileSync(daemon.configuration.override, 'utf8'), saved)
    }
    await client.request('config/set', { path: ['profiles', name], value: null })
    assert.equal((await catalog(name)).overridden, false)
    assert.deepEqual(daemon.configuration.value.profiles[name], config.profiles[name])
  }
  await client.request('config/set', { path: ['profiles', 'coder'], value: config.profiles.coder })
  assert.equal((await catalog('coder')).overridden, true, 'presence matters even if values equal defaults')
  // File-authored overrides use the same normalization as config/set.
  writeFileSync(daemon.configuration.override, JSON.stringify({ profiles: { legacy: { candidates } } }))
  assert.deepEqual(daemon.configuration.reload().errors, [])
  assert.deepEqual(profileCandidates(daemon.configuration.value.profiles.legacy), candidates)
  assert.equal((await catalog('legacy')).overridden, true)
  writeFileSync(daemon.configuration.override, '{')
  assert.equal(daemon.configuration.reload().errors.length, 1)
  assert.equal((await catalog('legacy')).overridden, true, 'last-good provenance survives an invalid overlay')
})

test('normalized legacy and candidate overrides keep their meaning when pushed to a host', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-profile-host-'))
  const local = new Configuration(join(dir, 'local'))
  const host = new Configuration(join(dir, 'host'), undefined, join(dir, 'host-override.json'))
  try {
    const legacy = { agent: 'claude', model: 'haiku', mode: 'ask' }
    local.set(['profiles', 'coder'], legacy)
    assert.equal(local.value.profiles.coder.candidates, undefined)
    assert.deepEqual(host.push(local.value).errors, [])
    assert.equal(host.value.profiles.coder.agent, legacy.agent)
    assert.equal(host.value.profiles.coder.model, legacy.model)
    const candidates = [{ agent: 'pi', model: 'opencode-go/grok', mode: 'auto' }]
    local.set(['profiles', 'coder', 'candidates'], candidates)
    assert.deepEqual(host.push(local.value).errors, [])
    assert.deepEqual(profileCandidates(host.value.profiles.coder), candidates)
    assert.equal(host.value.profiles.coder.agent, undefined)
  } finally { local.close(); host.close(); rmSync(dir, { recursive: true, force: true }) }
})

test('agents/models discovers Codex and filtered Pi choices without sessions or model turns', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-agent-models-'))
  const peer = join(dir, 'models.mjs'), log = join(dir, 'calls.jsonl')
  writeFileSync(peer, `#!${process.execPath}
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';
const log = ${JSON.stringify(log)};
appendFileSync(log, JSON.stringify({args:process.argv.slice(2)})+'\\n');
createInterface({ input: process.stdin }).on('line', line => {
 const m = JSON.parse(line);
 appendFileSync(log, line+'\\n');
 if(m.method === 'initialized') return;
 let result = {};
 if(m.method === 'model/list') result = m.params.cursor ? { data:[{model:'second',displayName:'Second'}] }
 : {data:[{model:'first',displayName:'First'},{model:'hidden',hidden:true}],nextCursor:'page2'};
 if(m.type === 'get_available_models') result = {models:[
 {provider:'opencode-go',id:'grok',name:'Grok'}, {provider:'opencode-go',id:'free'},
 {provider:'other',id:'paid',name:'Paid'}]};
 process.stdout.write(JSON.stringify(m.type ? {type:'response',id:m.id,success:true,data:result}
 : {jsonrpc:'2.0',id:m.id,result})+'\\n');
});`, { mode: 0o700 })
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    agents: { codex: { executable: peer }, pi: { executable: peer } },
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  const daemon = new DaemonServer({ varDir: dir }); await daemon.start(); daemon.configuration.close()
  const client = await SocketClient.connect(daemon.socket)
  t.after(async () => { await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) })
  await client.request('hello', { client: 'test', version: '' })
  assert.deepEqual(await client.request('agents/models', { agent: 'codex' }),
    { models: [{ id: 'first', label: 'First' }, { id: 'second', label: 'Second' }] })
  assert.deepEqual(await client.request('agents/models', { agent: 'pi' }),
    { models: [{ id: 'opencode-go/grok', label: 'Grok' }] })
  await client.request('config/set', { path: ['agents', 'pi', 'models'], value: { include: ['^other/'], exclude: [] } })
  assert.deepEqual(await client.request('agents/models', { agent: 'pi' }),
    { models: [{ id: 'other/paid', label: 'Paid' }] })
  assert.deepEqual((await client.request('agents/models', { agent: 'claude' })).models.map((m) => m.id),
    ['default', 'sonnet', 'opus', 'haiku'])
  assert.deepEqual(await client.request('agents/models', { agent: 'dsh' }), { models: [] })
  await assert.rejects(client.request('agents/models', { agent: 'unknown' }), /Unknown agent/)
  await client.request('config/set', { path: ['agents', 'codex', 'executable'], value: join(dir, 'missing') })
  await assert.rejects(client.request('agents/models', { agent: 'codex' }), /ENOENT/)
  assert.equal(daemon.sessions.size, 0)
  const calls = readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
  assert.ok(calls.some((c) => c.args?.includes('--no-session')))
  assert.ok(calls.every((c) => c.args || ['initialize', 'initialized', 'model/list'].includes(c.method) || c.type === 'get_available_models'))
})
