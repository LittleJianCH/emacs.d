import './fixtures/environment.ts'
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
