import { addedStateEntries } from './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { ProjectEnvironments } from '../../emx/remote/environment.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Connection } from '../../emx/daemon/rpc.ts'
import { createConnection } from 'node:net'
import { checkoutRoot } from '../../emx/daemon/paths.ts'

test('two host roots use their own allowed direnv PATH for lookup, CLI and inherited MCP', async () => {
  const dir = mkdtempSync('/tmp/emx-env-')
  const savedEnv = { ...process.env }
  const savedHome = process.env.HOME
  process.env.EMX_CLAUDE_LOG = join(dir, 'claude.log')
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  process.env.HOME = dir
  const savedPath = process.env.PATH
  const bin = join(dir, 'bin'); mkdirSync(bin)
  writeFileSync(join(bin, 'direnv'), `#!${process.execPath}
import fs from 'node:fs'; import path from 'node:path';
const env = JSON.parse(fs.readFileSync(fs.existsSync('.direnv/env') ? '.direnv/env' : '.envrc', 'utf8'));
if (env.blocked) process.exit(1);
console.log(JSON.stringify({PATH: path.resolve(env.bin) + ':' + process.env.PATH, VIRTUAL_ENV: env.bin, SECRET: 'excluded'}));
`, { mode: 0o700 })
  process.env.PATH = bin + ':' + savedPath
  const daemon = new DaemonServer({ varDir: join(dir, 'state'), remote: true })
  let peer: Connection | undefined
  try {
    const roots = ['a', 'b'].map((name) => join(dir, name))
    for (const root of roots) {
      mkdirSync(join(root, 'bin'), { recursive: true })
      writeFileSync(join(root, '.envrc'), JSON.stringify({ bin: join(root, 'bin') }))
      for (const agent of ['codex', 'claude', 'dsh']) {
        writeFileSync(join(root, 'bin', agent), `#!/bin/sh\nprintf '%s' "$VIRTUAL_ENV" > '${root}/${agent}.env'\nexec '${process.execPath}' '${checkoutRoot}/test/emx/fixtures/${agent}.mjs' "$@"\n`, { mode: 0o700 })
      }
    }
    await daemon.start()
    peer = new Connection(createConnection(daemon.socket))
    const config = JSON.parse(readFileSync(join(checkoutRoot, 'emx/config.json'), 'utf8'))
    config.collab.handleCommand = []; config.collab.agentHandleCommands = {}; config.usage.pollInterval = 0
    await peer.request('hello', { client: 'test', version: '', config })
    const environments = new ProjectEnvironments()
    for (const root of roots) {
      const env = await environments.get(root)
      assert.equal(execFileSync('sh', ['-c', 'command -v codex'], { cwd: root, env, encoding: 'utf8' }).trim(), join(root, 'bin/codex'))
      for (const agent of ['codex', 'claude', 'dsh']) {
        const opened: any = await peer.request('session/open', { agent, root, settings: {} })
        assert.equal(readFileSync(join(root, agent + '.env'), 'utf8'), join(root, 'bin'))
        await peer.request('session/stop', { id: opened.id })
      }
      // emx mcp is launched by each CLI and inherits this same environment.
      assert.equal(env.VIRTUAL_ENV, join(root, 'bin')); assert.equal(env.SECRET, undefined)
    }
    const root = roots[0]
    writeFileSync(join(root, '.envrc'), JSON.stringify({ bin: join(root, 'changed') }))
    assert.equal((await environments.get(root)).VIRTUAL_ENV, join(root, 'changed'))
    mkdirSync(join(root, '.direnv'))
    writeFileSync(join(root, '.direnv/env'), JSON.stringify({ bin: join(root, 'direnv-changed') }))
    assert.equal((await environments.get(root)).VIRTUAL_ENV, join(root, 'direnv-changed'))
    writeFileSync(join(root, '.direnv/env'), JSON.stringify({ blocked: true }))
    assert.equal((await environments.get(root)).PATH, process.env.PATH)
    assert.equal((await environments.get(roots[1])).VIRTUAL_ENV, join(roots[1], 'bin'))
  } finally {
    peer?.socket.destroy(); await daemon.stop(); process.env.PATH = savedPath; process.env.HOME = savedHome
    for (const key of ['EMX_CLAUDE_LOG', 'EMX_CLAUDE_PROJECTS_DIR']) {
      if (savedEnv[key] === undefined) delete process.env[key]; else process.env[key] = savedEnv[key]
    }
    rmSync(dir, { recursive: true, force: true })
  }
})

test('host collaboration inherits root PATH while enforcing role-specific MCP tools', async () => {
  const dir = mkdtempSync('/tmp/emx-env-profiles-'), savedEnv = { ...process.env }
  const bin = join(dir, 'bin'), a = join(dir, 'a'), b = join(dir, 'b')
  for (const path of [bin, a, b, join(a, 'bin')]) mkdirSync(path, { recursive: true })
  writeFileSync(join(bin, 'direnv'), `#!${process.execPath}
import path from 'node:path'; import fs from 'node:fs';
console.log(JSON.stringify({PATH:(fs.existsSync('disabled')?'/missing':path.join(process.cwd(),'bin'))+':'+process.env.PATH}));
`, { mode: 0o700 })
  writeFileSync(join(a, 'bin', 'project-dsh'), `#!/bin/sh\nexec '${process.execPath}' '${checkoutRoot}/test/emx/fixtures/dsh.mjs' "$@"\n`, { mode: 0o700 })
  process.env.PATH = bin + ':' + process.env.PATH
  process.env.HOME = dir
  const daemon = new DaemonServer({ varDir: join(dir, 'state'), remote: true })
  let editor: Connection | undefined
  const peers: Connection[] = []
  try {
    await daemon.start()
    editor = new Connection(createConnection(daemon.socket))
    editor.onRequest = () => ({ ok: true, result: { visible: false } })
    const config = JSON.parse(readFileSync(join(checkoutRoot, 'emx/config.json'), 'utf8'))
    config.agents.dsh.executable = 'project-dsh'
    config.collab.handleCommand = []; config.collab.agentHandleCommands = {}
    config.collab.closeFinished = false; config.usage.pollInterval = 0
    config.profiles['project-worker'] = { agent: 'dsh', model: 'fake/child', mode: 'ask' }
    await editor.request('hello', { client: 'test', version: '', config })
    const sessions = []
    const changes = [0, 0]
    for (const root of [a, b]) {
      const opened: any = await editor.request('session/open', { agent: 'echo', root, settings: { mode: 'auto' } })
      const peer = new Connection(createConnection(daemon.socket)); peers.push(peer)
      const index = peers.length - 1
      peer.onNotification = (method) => { if (method === 'mcp/tools_changed') changes[index]++ }
      await peer.request('mcp/hello', { session: opened.id })
      const result: any = await peer.request('mcp/tools', {})
      const description = result.tools.find((t: any) => t.name === 'session_start').description
      assert.equal(description.includes('- project-worker:'), root === a)
      sessions.push(daemon.sessions.get(opened.id)!)
    }
    const parent = sessions[0]
    await daemon.collab.call(parent, 'session_start', { profile: 'project-worker', prompt: 'fake child' }, new AbortController().signal)
    const child = [...daemon.sessions.values()].find((s) => s.info.parent === parent.id)!
    assert.ok(child)
    assert.equal(child.root, parent.root)
    assert.equal(daemon.collab.projectEnvironment(child.root).PATH,
      daemon.collab.projectEnvironment(parent.root).PATH)
    const parentTools = parent.editorTools(), childTools = child.editorTools()
    assert.deepEqual(childTools.tools, parentTools.tools.filter((tool) =>
      tool.name !== 'session_start' && tool.name !== 'session_ask' && tool.name !== 'session_rate'))
    assert.deepEqual(childTools.readOnly, parentTools.readOnly.filter((name) => name !== 'session_rate'))
    await assert.rejects(daemon.collab.call(child, 'session_start',
      { profile: 'project-worker', prompt: 'not allowed' }, new AbortController().signal),
    /not allowed|can't start sessions/)
    await assert.rejects(daemon.collab.call(sessions[1], 'session_start', { profile: 'project-worker', prompt: 'unavailable' }, new AbortController().signal), /No candidate available for profile project-worker: DeepSeek fake\/child: unavailable here/)
    writeFileSync(join(a, 'disabled'), '')
    writeFileSync(join(a, '.envrc'), 'changed')
    await editor.request('session/open', { agent: 'echo', root: a, settings: {} })
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.equal(changes[0], 1)
    assert.equal(changes[1], 0)
    const updated: any = await peers[0].request('mcp/tools', {})
    assert.ok(!updated.tools.find((t: any) => t.name === 'session_start').description.includes('- project-worker:'))
  } finally {
    for (const peer of peers) peer.socket.destroy()
    editor?.socket.destroy(); await daemon.stop()
    for (const key of ['PATH', 'HOME']) {
      if (savedEnv[key] === undefined) delete process.env[key]; else process.env[key] = savedEnv[key]
    }
    rmSync(dir, { recursive: true, force: true })
  }
})

test('environment fingerprint ignores deep direnv trees and reports filesystem errors as fallback', async () => {
  const dir = mkdtempSync('/tmp/emx-env-fingerprint-'), savedPath = process.env.PATH
  const bin = join(dir, 'bin'), root = join(dir, 'project')
  mkdirSync(bin); mkdirSync(join(root, '.direnv/deep/tree'), { recursive: true })
  const counter = join(dir, 'exports')
  writeFileSync(join(bin, 'direnv'), `#!${process.execPath}
import fs from 'node:fs'; fs.appendFileSync(${JSON.stringify(counter)}, 'x'); console.log('{"VIRTUAL_ENV":"cached"}');
`, { mode: 0o700 })
  process.env.PATH = bin + ':' + savedPath
  const environments = new ProjectEnvironments()
  try {
    assert.equal((await environments.get(root)).VIRTUAL_ENV, 'cached')
    writeFileSync(join(root, '.direnv/deep/tree/leaf'), 'new dependency cache')
    assert.equal((await environments.get(root)).VIRTUAL_ENV, 'cached')
    assert.equal(readFileSync(counter, 'utf8'), 'x', 'deep dependency trees must not invalidate or be walked')
    const invalid = join(dir, 'not-a-directory'); writeFileSync(invalid, 'file')
    const notices: string[] = []
    const env = await environments.get(invalid, (message: string) => notices.push(message))
    assert.equal(env.PATH, process.env.PATH)
    assert.equal(env.VIRTUAL_ENV, undefined)
    assert.equal(notices.length, 1)
    assert.match(notices[0], /ENOTDIR/)
  } finally { process.env.PATH = savedPath; rmSync(dir, { recursive: true, force: true }) }
})

test('a root without an .envrc gets the base environment and no notice', async () => {
  const dir = mkdtempSync('/tmp/emx-env-empty-')
  const savedPath = process.env.PATH
  const bin = join(dir, 'bin'); mkdirSync(bin)
  // direnv prints nothing when there is no .envrc or nothing changes.
  writeFileSync(join(bin, 'direnv'), '#!/bin/sh\nexit 0\n', { mode: 0o700 })
  process.env.PATH = bin + ':' + savedPath
  try {
    const root = join(dir, 'project'); mkdirSync(root)
    const notices: string[] = []
    const env = await new ProjectEnvironments().get(root, (message) => notices.push(message))
    assert.deepEqual(notices, [])
    assert.equal(env.PATH, process.env.PATH)
  } finally {
    process.env.PATH = savedPath
    rmSync(dir, { recursive: true, force: true })
  }
})


test('state isolation ignores only the existing daemon snapshot, never test writes', () => {
  const dir = mkdtempSync('/tmp/emx-state-inventory-')
  try {
    const pid = process.pid + 1
    writeFileSync(join(dir, 'daemon.lock'), JSON.stringify({ pid }))
    const before = new Set(['daemon.lock'])
    writeFileSync(join(dir, `sessions.json.${pid}.tmp`), '')
    assert.deepEqual(addedStateEntries(dir, before), [])
    writeFileSync(join(dir, 'unexpected.json'), '')
    writeFileSync(join(dir, `sessions.json.${process.pid}.tmp`), '')
    assert.deepEqual(addedStateEntries(dir, before).sort(), [`sessions.json.${process.pid}.tmp`, 'unexpected.json'].sort())
    assert.ok(addedStateEntries(dir, new Set()).includes(`sessions.json.${pid}.tmp`), 'a new daemon lock grants no exemption')
    writeFileSync(join(dir, 'daemon.lock'), JSON.stringify({ pid: process.pid }))
    assert.ok(addedStateEntries(dir, before).includes(`sessions.json.${process.pid}.tmp`))
  } finally { rmSync(dir, { recursive: true, force: true }) }
})
