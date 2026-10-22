// remote.test.ts --- a host is a second daemon with a private HOME; no SSH.
import './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createConnection } from 'node:net'
import * as fs from 'node:fs'
import { dirname, join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { codeVersion, checkoutRoot, runtimeFiles } from '../../emx/daemon/paths.ts'
import { Connection } from '../../emx/daemon/rpc.ts'
import { Configuration } from '../../emx/config.ts'
import { ConfigFiles } from '../../emx/daemon/config-files.ts'
import { UsageService } from '../../emx/usage/service.ts'
import { Outbox } from '../../emx/remote/outbox.ts'

const EMX = join(checkoutRoot, 'bin/emx')
const built = spawnSync(process.execPath, [EMX, 'daemon', '--manifest'], { encoding: 'utf8' })
assert.equal(built.status, 0, built.stderr)
const id = '1234567890abcdef'
function command(home: string, emx: string, args: string[]) {
  const out = spawnSync(process.execPath, [emx, 'daemon', '--client', id, ...args], {
    env: { ...process.env, HOME: home }, encoding: 'utf8', timeout: 10000,
  })
  assert.equal(out.status, 0, out.stderr)
  return out.stdout.trim() ? JSON.parse(out.stdout) : undefined
}
async function until(fn: () => boolean) {
  const deadline = Date.now() + 5000
  while (!fn()) { if (Date.now() > deadline) throw new Error('Timed out'); await delay(10) }
}
function peer(socket: string) { return new Connection(createConnection(socket)) }
const config = () => {
  const value = JSON.parse(fs.readFileSync(join(checkoutRoot, 'emx/config.json'), 'utf8'))
  value.collab.handleCommand = []; value.collab.agentHandleCommands = {}; value.usage.pollInterval = 0
  value.agents.codex.executable = join(checkoutRoot, 'test/emx/fixtures/codex.mjs')
  return value
}

test('runtime install hashes match without node_modules, and include the dsh runtime', () => {
  const home = fs.mkdtempSync('/tmp/emx-install-')
  try {
    const target = join(home, codeVersion())
    for (const file of runtimeFiles()) {
      fs.mkdirSync(dirname(join(target, file)), { recursive: true })
      fs.copyFileSync(join(checkoutRoot, file), join(target, file))
    }
    const read = () => spawnSync(process.execPath, [join(target, 'bin/emx'), 'daemon', '--manifest'], { encoding: 'utf8' })
    let out = read(); assert.equal(out.status, 0, out.stderr)
    assert.equal(JSON.parse(out.stdout).version, codeVersion())
    assert.ok(runtimeFiles().includes('lisp/agent/backend/dsh/emacs-bridge.mjs'))
    assert.ok(runtimeFiles().every((f) => !f.includes('node_modules') && !f.startsWith('test/') && !f.endsWith('.ts')))
    assert.ok(runtimeFiles().includes('emx/dist/config.json'))
    assert.ok(!runtimeFiles().includes('emx/package.json'))
    assert.ok(!fs.existsSync(join(target, 'emx/daemon')))
    fs.appendFileSync(join(target, 'lisp/agent/backend/dsh/emacs-bridge.mjs'), '\n// modified\n')
    out = read(); assert.equal(out.status, 0, out.stderr)
    assert.notEqual(JSON.parse(out.stdout).version, codeVersion())
  } finally { fs.rmSync(home, { recursive: true, force: true }) }
})

test('host ensure, config push, live agent cursor replay, editor calls, and usage receipts survive disconnect', async () => {
  const home = fs.mkdtempSync('/tmp/emx-host-')
  const local = fs.mkdtempSync('/tmp/emx-local-')
  const installed = join(home, '.cache/emacs-agent/emx', codeVersion())
  for (const file of runtimeFiles()) {
    fs.mkdirSync(dirname(join(installed, file)), { recursive: true })
    fs.copyFileSync(join(checkoutRoot, file), join(installed, file))
  }
  const hostEmx = join(installed, 'bin/emx')
  fs.mkdirSync(join(local, 'emx'))
  fs.writeFileSync(join(local, 'emx/config.json'), JSON.stringify(config()))
  fs.mkdirSync(join(home, '.config/emx'), { recursive: true })
  fs.writeFileSync(join(home, '.config/emx/config.json'), JSON.stringify({ agents: {
    codex: { executable: join(checkoutRoot, 'test/emx/fixtures/codex.mjs') },
    claude: { executable: join(checkoutRoot, 'test/emx/fixtures/bin/claude') },
    dsh: { executable: join(checkoutRoot, 'test/emx/fixtures/bin/dsh') },
  } }))
  let localConnection: Connection | undefined, editor: Connection | undefined, mcp: Connection | undefined
  try {
    const localEnsure = spawnSync(process.execPath, [EMX, 'daemon', '--var', local, '--ensure'], { encoding: 'utf8' })
    assert.equal(localEnsure.status, 0, localEnsure.stderr)
    const localPeer = localConnection = peer(JSON.parse(localEnsure.stdout).socket)
    // A second installed code version shares the client socket and state.
    const nextInstall = join(home, '.cache/emacs-agent/emx/staging')
    for (const file of runtimeFiles()) {
      fs.mkdirSync(dirname(join(nextInstall, file)), { recursive: true })
      fs.copyFileSync(join(checkoutRoot, file), join(nextInstall, file))
    }
    fs.appendFileSync(join(nextInstall, 'lisp/agent/backend/dsh/emacs-bridge.mjs'), '\n// next test version\n')
    const manifest = spawnSync(process.execPath, [join(nextInstall, 'bin/emx'), 'daemon', '--manifest'], { encoding: 'utf8' })
    assert.equal(manifest.status, 0, manifest.stderr)
    const nextVersion = JSON.parse(manifest.stdout).version
    const nextDir = join(home, '.cache/emacs-agent/emx', nextVersion)
    fs.renameSync(nextInstall, nextDir)
    const nextEmx = join(nextDir, 'bin/emx')
    const info = command(home, hostEmx, ['--ensure'])
    assert.equal(info.version, codeVersion()); assert.equal(info.started, true)
    assert.equal(info.socket, join(home, '.cache/emacs-agent/emx/run', id + '.sock'))
    assert.equal(fs.statSync(dirname(info.socket)).mode & 0o777, 0o700)
    assert.equal(fs.statSync(join(home, '.cache/emacs-agent/emx/state', id)).mode & 0o777, 0o700)
    assert.equal(command(home, hostEmx, ['--ensure']).pid, info.pid)
    await localPeer.request('hello', { client: 'local', version: '', tools: { tools: [], readOnly: [] } })
    localPeer.onRequest = (method, args) => {
      assert.equal(method, 'editor/call')
      assert.ok(['_config_modified', '_config_written'].includes(args.method))
      return { ok: true, result: args.method === '_config_modified' ? false : null }
    }
    const seen: any[] = [], deliveries: any[] = []
    const tools = { tools: [{ name: 'open', description: 'Open', inputSchema: { type: 'object' as const } }], readOnly: ['open'] }
    editor = peer(info.socket)
    editor.onNotification = (method, params) => { seen.push({ method, params }); if (method === 'usage/outbox') deliveries.push(...params.entries) }
    editor.onRequest = async (_method, args) => {
      if (args.method.startsWith('config_')) return { ok: true, result: await localPeer.request('config/call', { method: args.method, arguments: args.params }) }
      assert.equal(args.method, 'open'); assert.equal(args.params.path, '/host/project/a.el')
      return { ok: true, result: { file: args.params.path } }
    }
    const hello: any = await editor.request('hello', { client: 'remote', version: info.version, config: config(), tools })
    assert.equal(hello.config.usage.pollInterval, 0)
    const pushed = config(); pushed.collab.maxActive = 7; pushed.agents.codex.executable = '/wrong-local-path'
    const updated: any = await editor.request('config/push', { config: pushed })
    assert.equal(updated.config.collab.maxActive, 7)
    assert.equal(updated.config.agents.codex.executable, join(checkoutRoot, 'test/emx/fixtures/codex.mjs'))
    const opened: any = await editor.request('session/open', { agent: 'codex', root: home, settings: {} })
    const session = opened.id
    const attached: any = await editor.request('session/attach', { id: session })
    await until(() => seen.some((e) => e.method === 'history/done'))
    await editor.request('session/send', { id: session, text: 'hold' })
    await until(() => seen.some((e) => e.method === 'block/append' && e.params.text === 'holding'))
    const cursor = { epoch: attached.epoch, seq: Math.max(...seen.filter((e) => e.params.session === session).map((e) => e.params.seq)) }
    const stale = command(home, nextEmx, ['--ensure'])
    assert.equal(stale.stale, true); assert.equal(stale.pid, info.pid)
    mcp = peer(info.socket); await mcp.request('mcp/hello', { session })
    const listed: any = await mcp.request('mcp/tools', {})
    assert.equal(listed.tools.filter((t: any) => t.name === 'config_read').length, 1)
    assert.deepEqual(await mcp.request('mcp/call', { name: 'open', arguments: { path: '/host/project/a.el' } }), { file: '/host/project/a.el' })
    const relative = 'var/phase7-config-' + process.pid + '.el'
    const file = join(checkoutRoot, relative)
    try {
      await mcp.request('mcp/call', { name: 'config_write', arguments: { path: relative, content: 'one\ntwo\n' } })
      assert.equal(fs.readFileSync(file, 'utf8'), 'one\ntwo\n')
      await mcp.request('mcp/call', { name: 'config_edit', arguments: { path: relative, old_string: 'two', new_string: 'three' } })
      assert.match(String(await mcp.request('mcp/call', { name: 'config_read', arguments: { path: relative, offset: 2, limit: 1 } })), /2\tthree/)
      await assert.rejects(mcp.request('mcp/call', { name: 'config_read', arguments: { path: '.git/config' } }), /not a file/)
    } finally { fs.rmSync(file, { force: true }) }
    editor.socket.destroy(); await until(() => editor!.closed)
    await assert.rejects(mcp.request('mcp/call', { name: 'open', arguments: {} }), /not attached/)
    // A second client steers the still-running fake process while Emacs is away.
    const control = peer(info.socket)
    await control.request('hello', { client: 'test-control', version: info.version })
    await control.request('session/steer', { id: session, text: 'finished while disconnected' })
    await delay(100)
    control.socket.destroy()
    const replay: any[] = []
    editor = peer(info.socket)
    editor.onNotification = (method, params) => { replay.push({ method, params }); if (method === 'usage/outbox') deliveries.push(...params.entries) }
    await editor.request('hello', { client: 'remote', version: info.version, config: pushed, tools })
    const resumed: any = await editor.request('session/attach', { id: session, after: cursor })
    assert.equal(resumed.replay, 'events'); assert.equal(resumed.status, 'idle')
    await until(() => replay.some((e) => e.method === 'block/append' && e.params.text.includes('while disconnected')))
    assert.ok(replay.filter((e) => e.params.session === session).every((e) => e.params.seq > cursor.seq))
    await until(() => deliveries.some((e) => e.method === 'record'))
    const unique = [...new Map(deliveries.map((e) => [e.id, e])).values()]
    for (const entry of unique) {
      await localPeer.request('usage/' + entry.method, { id: entry.id, source: entry.source, sequence: entry.sequence, ...entry.params })
      // Lose the remote ack; resend exactly the same receipt after reconnect.
      await localPeer.request('usage/' + entry.method, { id: entry.id, source: entry.source, sequence: entry.sequence, ...entry.params })
    }
    const records = fs.readFileSync(join(local, 'agent-usage.jsonl'), 'utf8').trim().split('\n').map(JSON.parse as any)
    assert.equal(records.length, unique.filter((e) => e.method === 'record').length)
    for (const entry of unique) await editor.request('usage/ack', { source: entry.source, sequence: entry.sequence })
    const outbox = join(home, '.cache/emacs-agent/emx/state', id, 'emx/usage-outbox.json')
    assert.deepEqual(JSON.parse(fs.readFileSync(outbox, 'utf8')).entries, [])
    await editor.request('session/stop', { id: session })
    editor.socket.destroy(); mcp.socket.destroy()
    const upgraded = command(home, nextEmx, ['--ensure'])
    assert.equal(upgraded.version, nextVersion); assert.equal(upgraded.stale, false)
    assert.notEqual(upgraded.pid, info.pid)
    command(home, hostEmx, ['--stop'])
    const restarted = command(home, hostEmx, ['--ensure'])
    assert.notEqual(restarted.pid, info.pid)
    const persisted = peer(restarted.socket)
    const effective: any = await persisted.request('hello', { client: 'restart', version: '' })
    assert.equal(effective.config.collab.maxActive, 7)
    persisted.socket.destroy()
  } finally {
    editor?.socket.destroy(); mcp?.socket.destroy(); localConnection?.socket.destroy()
    try { command(home, EMX, ['--stop']) } finally {
      const stopped = spawnSync(process.execPath, [EMX, 'daemon', '--var', local, '--stop'])
      assert.equal(stopped.status, 0, String(stopped.stderr))
      fs.rmSync(home, { recursive: true, force: true }); fs.rmSync(local, { recursive: true, force: true })
    }
  }
})

test('outbox retains the unacknowledged sequence suffix on disk', () => {
  const dir = fs.mkdtempSync('/tmp/emx-outbox-'), file = join(dir, 'outbox.json')
  try {
    const first = new Outbox(file)
    first.add('record', { record: { input: 3 } }); first.add('quota', { reading: { agent: 'codex' } })
    const second = new Outbox(file); second.restore()
    assert.deepEqual(second.entries, first.entries)
    second.ack(first.source, first.entries[0].sequence)
    const third = new Outbox(file); third.restore()
    assert.deepEqual(third.entries, [first.entries[1]])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('local configuration tools reject escapes, duplicate replacements and unsaved buffers', async () => {
  const dir = fs.mkdtempSync('/tmp/emx-files-')
  let modified = false
  const files = new ConfigFiles(async () => modified, dir)
  try {
    fs.writeFileSync(join(dir, 'a'), 'a a')
    fs.symlinkSync('/tmp', join(dir, 'escape'))
    for (const file of ['../outside', '.git/config', 'escape/x']) await assert.rejects(files.call('config_read', { path: file }), /not a file/)
    await assert.rejects(files.call('config_edit', { path: 'a', old_string: 'a', new_string: 'b' }), /occurs 2/)
    fs.writeFileSync(join(dir, 'a'), 'a c')
    await Promise.all([
      files.call('config_edit', { path: 'a', old_string: 'a', new_string: 'b' }),
      files.call('config_edit', { path: 'a', old_string: 'c', new_string: 'd' }),
    ])
    assert.equal(fs.readFileSync(join(dir, 'a'), 'utf8'), 'b d')
    modified = true
    await assert.rejects(files.call('config_write', { path: 'a', content: 'b' }), /unsaved/)
    assert.equal(fs.readFileSync(join(dir, 'a'), 'utf8'), 'b d')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('host overrides are limited to executables and bad pushes retain the last good config', () => {
  const dir = fs.mkdtempSync('/tmp/emx-host-config-')
  const override = join(dir, 'host.json')
  const c = new Configuration(dir, undefined, override)
  try {
    c.push(config())
    fs.writeFileSync(override, JSON.stringify({ collab: { maxActive: 99 } }))
    assert.match(c.reload().errors.join(' '), /only override/)
    assert.equal(c.value.collab.maxActive, config().collab.maxActive)
    assert.throws(() => c.push({ agents: 'invalid' }))
    assert.equal(c.value.collab.maxActive, config().collab.maxActive)
  } finally { c.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('host fills keys an older client config lacks from its own defaults', () => {
  const dir = fs.mkdtempSync('/tmp/emx-host-skew-')
  const override = join(dir, 'host.json')
  const c = new Configuration(dir, undefined, override)
  try {
    const older: any = config(); older.collab.maxActive = 7
    delete older.collab.prompts.delegation
    const result = c.push(older)
    assert.deepEqual(result.errors, [])
    assert.equal(c.value.collab.maxActive, 7)
    assert.equal(c.value.collab.prompts.delegation, config().collab.prompts.delegation)
    // The persisted base predates this host too after an upgrade.
    fs.writeFileSync(c.baseFile!, JSON.stringify(older))
    const restarted = new Configuration(dir, undefined, override)
    try {
      assert.equal(restarted.value.collab.maxActive, 7)
      assert.equal(restarted.value.collab.prompts.delegation, config().collab.prompts.delegation)
    } finally { restarted.close() }
  } finally { c.close(); fs.rmSync(dir, { recursive: true, force: true }) }
})

test('delayed remote quota delivery preserves the sampling time and forecast history', () => {
  const dir = fs.mkdtempSync('/tmp/emx-quota-outbox-')
  const outbox = new Outbox(join(dir, 'outbox.json'))
  const host = new UsageService({ now: () => 100, capture: (method, params) => outbox.add(method, params) })
  const local = new UsageService({ now: () => 999 })
  try {
    host.initialize({ usageFile: join(dir, 'host.jsonl'), quotaFile: join(dir, 'host.json') })
    local.initialize({ usageFile: join(dir, 'local.jsonl'), quotaFile: join(dir, 'local.json') })
    host.quota({ agent: 'codex', windows: [{ id: '5h', minutes: 300, used: 0.25, resets: 1000 }] })
    const entry = outbox.entries[0]
    local.quota({ ...entry.params.reading, host: 'test-host' }, entry.id, entry.source, entry.sequence)
    local.quota({ ...entry.params.reading, host: 'test-host' }, entry.id, entry.source, entry.sequence)
    const reading = JSON.parse(fs.readFileSync(join(dir, 'local.json'), 'utf8'))[0]
    assert.equal(reading.time, 100)
    assert.deepEqual(reading.windows[0].history, [[100, 0.25]])
  } finally { host.stop(); local.stop(); fs.rmSync(dir, { recursive: true, force: true }) }
})
