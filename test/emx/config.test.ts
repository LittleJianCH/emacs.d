import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, openSync, closeSync, readdirSync, fstatSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { agentBackend, Configuration, merge, validate } from '../../emx/config.ts'
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
  for (const key of ['delegation', 'startSummary', 'forkAgents', 'failedReply', 'replyError', 'partialReply', 'candidateSkipped', 'candidatesSkipped', 'candidateUnavailable', 'candidateModelExcluded', 'candidateQuotaUsed', 'candidateQuotaLimited', 'candidateBalanceExhausted', 'candidateSameAgent', 'noCandidate']) {
    const c = defaults()
    delete c.collab.prompts[key]
    assert.throws(() => validate(c), { message: `config.collab.prompts.${key}: expected string` })
  }
})
test('role candidates and legacy overrides validate; malformed candidates and quota thresholds fail', () => {
  const c = defaults()
  assert.equal(validate(c).collab.quotaSkip, 0.9)
  assert.deepEqual(validate(c).profiles.coder.candidates, c.profiles.coder.candidates)
  const legacy = { agent: 'claude', model: 'sonnet', mode: 'auto', effort: 'high', cost: 'medium' }
  c.profiles.legacy = legacy
  assert.deepEqual(validate(c).profiles.legacy, legacy)
  assert.equal(validate(merge(defaults(), { profiles: { coder: legacy } })).profiles.coder.agent, 'claude')
  for (const quotaSkip of [0, 0.3, 1]) assert.equal(validate(merge(c, { collab: { quotaSkip } })).collab.quotaSkip, quotaSkip)
  for (const quotaSkip of [0, 0.3, 1]) assert.equal(validate(merge(c, { agents: { claude: { quotaSkip } } })).agents.claude.quotaSkip, quotaSkip)
  for (const quotaSkip of [-0.01, 1.01, NaN, Infinity, '0.9', null]) {
    assert.throws(() => validate(merge(c, { collab: { quotaSkip } })), /collab.quotaSkip/)
    assert.throws(() => validate(merge(c, { agents: { claude: { quotaSkip } } })), /agents.claude.quotaSkip/)
  }
  assert.deepEqual(validate(c).collab.disabled, [])
  const disabled = ['unknown', 'unknown:no-agent', 'unknown:no-agent/no-model', 'worker:pi/opencode-go/kimi-k3']
  assert.deepEqual(validate(merge(c, { collab: { disabled } })).collab.disabled, disabled)
  for (const disabled of [null, 'coder', {}, [1], [null]]) {
    assert.throws(() => validate(merge(c, { collab: { disabled } })), { message: 'config.collab.disabled: expected string[]' })
  }
  for (const candidates of [[], null, {}, [{ agent: 'missing' }], [{ agent: 'codex', mode: 'unsafe' }],
    [{ agent: 'codex', cost: 'low' }], [{ agent: 'codex', model: 2 }], [{ agent: 'codex', effort: false }]]) {
    assert.throws(() => validate(merge(c, { profiles: { coder: { candidates } } })), /profiles.coder.candidates/)
  }
  assert.throws(() => validate(merge(c, { profiles: { reviewer: { preferOtherAgent: 'yes' } } })), /preferOtherAgent/)
})

test('config/set creates, preserves, deletes and prunes overlay keys with atomic replacement', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-set-'))
  const c = new Configuration(dir)
  let fd: number | undefined
  try {
    assert.equal(c.set(['agents', 'claude', 'quotaSkip'], 0.7).config.agents.claude.quotaSkip, 0.7)
    const original = '{\n  "agents": {\n    "claude": {\n      "quotaSkip": 0.7\n    }\n  }\n}\n'
    assert.equal(readFileSync(c.override, 'utf8'), original)
    fd = openSync(c.override, 'r')
    assert.equal(c.set(['collab', 'disabled'], ['coder:claude']).config.collab.disabled[0], 'coder:claude')
    assert.notEqual(statSync(c.override).ino, fstatSync(fd).ino, 'publishes a new inode, never truncates the existing file')
    assert.equal(readFileSync(fd, 'utf8'), original, 'an existing reader retains a complete old snapshot')
    assert.deepEqual(JSON.parse(readFileSync(c.override, 'utf8')), {
      agents: { claude: { quotaSkip: 0.7 } }, collab: { disabled: ['coder:claude'] },
    })
    assert.equal(c.set(['agents', 'claude', 'quotaSkip'], null).config.agents.claude.quotaSkip, undefined)
    assert.deepEqual(JSON.parse(readFileSync(c.override, 'utf8')), { collab: { disabled: ['coder:claude'] } })
    assert.deepEqual(c.set(['collab', 'disabled'], null).config.collab.disabled, [])
    assert.equal(readFileSync(c.override, 'utf8'), '{}\n')
    c.set(['agents', 'missing', 'quotaSkip'], null)
    assert.equal(readFileSync(c.override, 'utf8'), '{}\n', 'deleting an absent key creates no intermediate objects')
    assert.deepEqual(readdirSync(join(dir, 'emx')), ['config.json'], 'no publication temp files remain')
  } finally { if (fd !== undefined) closeSync(fd); c.close(); rmSync(dir, { recursive: true, force: true }) }
})

test('config/set rejects invalid edits before writing and leaves last-good policy and overlay intact', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-set-invalid-'))
  const c = new Configuration(dir)
  try {
    c.set(['agents', 'claude', 'quotaSkip'], 0.7)
    const original = readFileSync(c.override, 'utf8'), inode = statSync(c.override).ino
    for (const [path, value, message] of [
      [['agents', 'claude', 'quotaSkip'], 1.1, 'config.agents.claude.quotaSkip: expected number 0..1'],
      [['collab', 'disabled'], [1], 'config.collab.disabled: expected string[]'],
      [['collab', 'typo'], true, 'config.collab.typo: unknown key'],
      [[], 1, 'config/set path: expected nonempty string[]'],
      [[''], 1, 'config/set path: expected nonempty string[]'],
      ['collab.quotaSkip', 1, 'config/set path: expected nonempty string[]'],
      [['__proto__', 'polluted'], true, 'Invalid config key: __proto__'],
      [['agents', 'constructor', 'quotaSkip'], 0.5, 'Invalid config key: constructor'],
      [['collab', 'quotaSkip'], undefined, 'config/set requires value (use null to delete)'],
    ] as const) {
      assert.throws(() => c.set(path, value), { message })
      assert.equal(readFileSync(c.override, 'utf8'), original)
      assert.equal(statSync(c.override).ino, inode)
      assert.equal(c.value.agents.claude.quotaSkip, 0.7)
    }
    writeFileSync(c.override, '{')
    assert.throws(() => c.set(['collab', 'quotaSkip'], 0.8), SyntaxError)
    assert.equal(readFileSync(c.override, 'utf8'), '{', 'malformed existing JSON is not overwritten')
    assert.deepEqual(readdirSync(join(dir, 'emx')), ['config.json'])
  } finally { c.close(); rmSync(dir, { recursive: true, force: true }) }
})

test('host configuration rejects config/set, including executable overrides', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-set-host-'))
  const file = join(dir, 'host.json')
  const c = new Configuration(dir, undefined, file)
  try {
    writeFileSync(file, '{}\n')
    assert.throws(() => c.set(['agents', 'claude', 'executable'], process.execPath), {
      message: 'config/set is only available on local daemons',
    })
    assert.equal(readFileSync(file, 'utf8'), '{}\n')
  } finally { c.close(); rmSync(dir, { recursive: true, force: true }) }
})

test('config/set wire reloads immediately and notifies editor and MCP without a watcher', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-config-set-wire-'))
  const tracked = join(dir, 'defaults.json'), config = defaults()
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}; config.usage.pollInterval = 0
  writeFileSync(tracked, JSON.stringify(config))
  const daemon = new DaemonServer({ varDir: dir, configFile: tracked })
  await daemon.start(); daemon.configuration.close()
  const client = await SocketClient.connect(daemon.socket), mcp = await SocketClient.connect(daemon.socket)
  try {
    await client.request('hello', { client: 'test', version: '' })
    const { id } = await client.request('session/open', { agent: 'echo', root: dir })
    await mcp.request('mcp/hello', { session: id })
    const result = await client.request('config/set', { path: ['collab', 'disabled'], value: ['coder'] })
    assert.deepEqual(Object.keys(result), ['config'])
    assert.deepEqual(result.config.collab.disabled, ['coder'])
    assert.deepEqual((await client.request('config/get', {})).config.collab.disabled, ['coder'])
    await client.waitFor((n) => n.method === 'config' && n.params.config.collab.disabled.includes('coder'))
    await mcp.waitFor((n) => n.method === 'mcp/tools_changed')
    assert.doesNotMatch((await mcp.request('mcp/tools', {})).tools.find((t) => t.name === 'session_start')!.description, /- coder:/)
    await assert.rejects(client.request('config/set', { path: ['collab', 'quotaSkip'], value: 2 }), {
      message: 'config.collab.quotaSkip: expected number 0..1',
    })
    assert.deepEqual((await client.request('config/get', {})).config.collab.disabled, ['coder'])
    assert.deepEqual((await client.request('config/set', { path: ['collab', 'disabled'], value: null })).config.collab.disabled, [])
  } finally { await mcp.close(); await client.close(); await daemon.stop(); rmSync(dir, { recursive: true, force: true }) }
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


test('agent identities select registered protocols and reject unknown kinds', () => {
  const c = validate(merge(defaults(), { agents: { acme: { backend: 'codex', title: 'Acme', executable: 'acme' } } }))
  assert.equal(agentBackend(c, 'acme'), 'codex')
  assert.equal(agentBackend(c, 'codex'), 'codex')
  for (const backend of ['missing', '', null, 12, 'constructor', '__proto__']) {
    assert.throws(() => validate(merge(c, { agents: { acme: { backend } } })), /agents.acme.backend/)
  }
  const { backend, ...identity } = c.agents.acme
  assert.throws(() => validate({ ...c, agents: { ...c.agents, acme: identity } }), /agents.acme.backend/)
})

test('temporary var directories ignore implicit site policy while the default var opts in', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-site-isolation-'))
  const paths = { defaultVar: join(dir, 'var'), site: join(dir, 'site/emx/config.json') }
  mkdirSync(join(dir, 'site/emx'), { recursive: true })
  writeFileSync(paths.site, JSON.stringify({ agents: {
    acme: { backend: 'codex', title: 'Acme', executable: 'acme' },
  } }))
  // Substitute installation paths so the real checkout's site is never touched.
  const isolated = new Configuration(join(dir, 'temporary'), undefined, undefined, undefined, paths)
  const local = new Configuration(join(paths.defaultVar, '.'), undefined, undefined, undefined, paths)
  const host = new Configuration(join(dir, 'host'), undefined, join(dir, 'host.json'), undefined, paths)
  try {
    assert.equal(isolated.site, undefined)
    assert.equal(isolated.value.agents.acme, undefined)
    assert.equal(host.site, undefined, 'temporary host simulations also stay isolated')
    assert.equal(host.value.agents.acme, undefined)
    assert.equal(local.site, paths.site)
    assert.equal(local.value.agents.acme.backend, 'codex')
    writeFileSync(paths.site, '{')
    assert.deepEqual(isolated.reload().errors, [])
    assert.deepEqual(host.reload().errors, [])
    assert.equal(local.reload().errors.length, 1, 'the default var still reads site policy')
  } finally {
    isolated.close(); local.close(); host.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('site policy merges before var policy and supplies host executable overrides', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-site-'))
  const tracked = join(dir, 'emx/config.json'), site = join(dir, 'site/emx/config.json')
  mkdirSync(join(dir, 'emx'), { recursive: true }); mkdirSync(join(dir, 'site/emx'), { recursive: true })
  writeFileSync(tracked, JSON.stringify(defaults()))
  writeFileSync(site, JSON.stringify({ agents: { acme: { backend: 'codex', title: 'Acme', executable: 'acme', extraArgs: ['site'] } },
    profiles: { coder: { agent: 'acme', model: 'site-model' } }, collab: { maxActive: 3 } }))
  const local = new Configuration(join(dir, 'local'), tracked, undefined, site)
  const hostFile = join(dir, 'host.json')
  writeFileSync(hostFile, JSON.stringify({ agents: { acme: { executable: 'host-acme' } } }))
  const host = new Configuration(join(dir, 'host'), tracked, hostFile, site)
  let restored: Configuration | undefined
  try {
    assert.deepEqual(local.errors, [])
    assert.equal(local.value.collab.maxActive, 3)
    assert.equal(local.value.profiles.coder.agent, 'acme')
    assert.equal(local.value.profiles.coder.candidates, undefined)
    assert.equal(host.value.agents.acme.executable, 'host-acme', 'installed site agents exist before any config push')
    assert.equal(local.set(['agents', 'acme', 'extraArgs'], ['var']).config.agents.acme.backend, 'codex')
    assert.deepEqual(local.value.agents.acme.extraArgs, ['var'])
    local.set(['profiles', 'coder', 'candidates'], [{ agent: 'acme', model: 'var-model' }])
    assert.equal(local.value.profiles.coder.agent, undefined)
    local.set(['profiles', 'coder'], null)
    assert.equal(local.value.profiles.coder.agent, 'acme', 'deleting var policy reveals the site default')
    assert.deepEqual(host.push(local.value).errors, [])
    assert.equal(host.value.agents.acme.executable, 'host-acme')
    assert.deepEqual(host.value.agents.acme.extraArgs, ['var'])
    restored = new Configuration(join(dir, 'host'), tracked, hostFile, site)
    assert.equal(restored.value.agents.acme.executable, 'host-acme')
    writeFileSync(hostFile, JSON.stringify({ agents: { acme: { backend: 'echo' } } }))
    assert.match(host.reload().errors[0], /only override/)
    assert.equal(host.value.agents.acme.backend, 'codex')
    const changed = new Promise<void>((resolve) => local.watch((result) => {
      if (result.config.agents.acme.title === 'Acme updated') resolve()
    }))
    await new Promise((resolve) => setTimeout(resolve, 300))
    writeFileSync(site, JSON.stringify({ agents: { acme: { backend: 'codex', title: 'Acme updated', executable: 'acme' } } }))
    await Promise.race([changed, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('Site watcher timed out')), 3000)
      timer.unref()
    })])
    writeFileSync(site, '{')
    assert.equal(local.reload().errors.length, 1)
    assert.equal(local.value.agents.acme.title, 'Acme updated')
  } finally { local.close(); host.close(); restored?.close(); rmSync(dir, { recursive: true, force: true }) }
})
