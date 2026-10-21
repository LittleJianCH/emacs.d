import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, readFileSync, writeFileSync, renameSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Configuration, merge, validate } from '../../emx/config.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'

const defaults = () => JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
test('config merges objects deeply and replaces arrays, scalars and null', () => {
  assert.deepEqual(merge({ a: { b: 1, c: [1, 2] }, d: 2 }, { a: { c: [] }, d: null }),
    { a: { b: 1, c: [] }, d: null })
  assert.throws(() => merge({}, JSON.parse('{"__proto__": {"polluted": true}}')), /Invalid config key/)
})
test('config validates defaults and rejects malformed policy with a field path', () => {
  assert.equal(validate(defaults()).collab.maxActive, 4)
  for (const patch of [{ collab: { maxActive: -1 } }, { collab: { confirm: 'yes' } },
    { profiles: { coder: { agent: 'missing' } } }, { daemon: { idleExit: Infinity } },
    { profiles: { coder: { mode: 'unsafe' } } }, { collab: { handleCommand: [3] } },
    { collab: { typo: true } }, { agents: { claude: { executable: '' } } }]) {
    assert.throws(() => validate(merge(defaults(), patch)), /config\./)
  }
  for (const key of ['startSummary', 'forkAgents']) {
    const c = defaults()
    delete c.collab.prompts[key]
    assert.throws(() => validate(c), { message: `config.collab.prompts.${key}: expected string` })
  }
})
test('config reload retains last good config on JSON and validation errors; deletion resets override', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-'))
  const c = new Configuration(dir)
  c.watch(() => {})
  try {
    writeFileSync(c.override, JSON.stringify({ collab: { maxActive: 2 }, agents: { claude: { extraArgs: ['--test'] } } }))
    assert.deepEqual(c.reload().errors, [])
    assert.equal(c.value.collab.maxActive, 2)
    assert.equal(c.value.agents.claude.executable, 'claude')
    writeFileSync(c.override, '{')
    assert.equal(c.reload().errors.length, 1)
    assert.equal(c.value.collab.maxActive, 2)
    writeFileSync(c.override, '{"collab":{"maxActive":false}}')
    assert.match(c.reload().errors[0], /collab.maxActive/)
    rmSync(c.override)
    assert.equal(c.reload().config.collab.maxActive, 4)
  } finally { c.close(); rmSync(dir, { recursive: true, force: true }) }
})
test('daemon exposes effective config, watches both paths after atomic replace and notifies MCP', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-daemon-'))
  const tracked = join(dir, 'defaults.json')
  writeFileSync(tracked, JSON.stringify(defaults()))
  const daemon = new DaemonServer({ varDir: dir, configFile: tracked })
  await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  const mcp = await SocketClient.connect(daemon.socket)
  try {
    assert.equal((await client.request('hello', { client: 'test', version: '' })).config?.collab.maxActive, 4)
    writeFileSync(daemon.configuration.override, JSON.stringify({ usage: { pollInterval: 17 } }))
    await client.request('config/reload', {})
    await client.request('usage/configure', { pollInterval: 900 })
    assert.equal(daemon.usage.pollInterval, 17, 'legacy editors cannot replace file policy')
    const { id } = await client.request('session/open', { agent: 'echo', root: dir })
    await mcp.request('mcp/hello', { session: id })
    for (const file of [tracked, daemon.configuration.override, tracked]) {
      const from = client.notifications.length
      const next = file === tracked ? defaults() : { collab: { maxActive: 1 } }
      if (file === tracked) next.collab.startGuidance += String(from)
      writeFileSync(file + '.tmp', JSON.stringify(next))
      renameSync(file + '.tmp', file)
      await client.waitFor((n) => n.method === 'config', 3000, 'config change', from)
      await mcp.waitFor((n) => n.method === 'mcp/tools_changed')
    }
    writeFileSync(daemon.configuration.override, '{"collab":{"maxActive":0}}')
    const result = await client.request('config/reload', {})
    assert.match(result.errors[0], /collab.maxActive/)
    assert.equal(result.config.collab.maxActive, 1)
    assert.equal((await client.request('config/get', {})).config.collab.maxActive, 1)
  } finally { await mcp.close(); await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
})
