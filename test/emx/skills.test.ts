import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { checkoutRoot } from '../../emx/daemon/paths.ts'
import { SocketClient } from './client.ts'

for (const agent of ['claude', 'codex', 'dsh']) test(`${agent} children inherit refreshed neutral skill context`, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-skills-'))
  const saved = { ...process.env }
  process.env.HOME = dir
  process.env.EMX_CLAUDE_LOG = join(dir, 'claude.jsonl')
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  process.env.EMX_CODEX_LOG = join(dir, 'codex.jsonl')
  process.env.EMX_CODEX_CONFIG = '{}'
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    agents: Object.fromEntries(['claude', 'codex', 'dsh'].map((name) => [name,
      { executable: join(checkoutRoot, 'test/emx/fixtures', name + '.mjs') }])),
    collab: { handleCommand: [], agentHandleCommands: {}, closeFinished: false }, usage: { pollInterval: 0 },
    profiles: { c: { agent: 'claude', mode: 'ask' }, x: { agent: 'codex', mode: 'ask' } },
  }))
  const daemon = new DaemonServer({ varDir: dir })
  await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  try {
    await client.request('hello', { client: 'skills-test', version: daemon.version })
    const { id } = await client.request('session/open', { agent, root: dir,
      skills: { skillsDir: join(dir, 'old'), supersededSkills: ['old-skill'] } })
    // Refresh the context before creating either child backend.
    await client.request('session/context', { id,
      skills: { skillsDir: join(dir, 'new'), supersededSkills: ['atomic-review'] } })
    await client.close()
    for (let i = 0; daemon.client && i < 100; i++) await new Promise((r) => setTimeout(r, 10))
    const parent = daemon.sessions.get(id)!
    parent.setStatus('running')
    const targets = agent === 'claude' ? ['x'] : agent === 'codex' ? ['c'] : ['c', 'x']
    for (const profile of targets) {
      await daemon.collab.call(parent, 'session_start', { profile, prompt: 'task' }, new AbortController().signal)
      const child = [...daemon.sessions.values()].find((s) => s.info.parent === id && s.info.profile === profile)!
      assert.deepEqual(child.info.skills, { skillsDir: join(dir, 'new'), supersededSkills: ['atomic-review'] })
      if (profile === 'c') {
        const spawn: any = readFileSync(process.env.EMX_CLAUDE_LOG!, 'utf8').trim().split('\n')
          .map((s) => JSON.parse(s)).findLast((s) => s.type === 'spawn')
        assert.equal(spawn.argv[spawn.argv.indexOf('--add-dir') + 1], join(dir, 'new'))
        assert.deepEqual(JSON.parse(spawn.argv[spawn.argv.indexOf('--settings') + 1]),
          { skillOverrides: { 'atomic-review': 'off' } })
      } else {
        const rows: any[] = readFileSync(process.env.EMX_CODEX_LOG!, 'utf8').trim().split('\n').map((s) => JSON.parse(s))
        assert.ok(rows.findLast((s) => s.method === 'initialize').argv.includes('skills.config=[{name="atomic-review",enabled=false}]'))
        assert.deepEqual(rows.findLast((s) => s.method === 'skills/extraRoots/set').params,
          { extraRoots: [join(dir, 'new/.claude/skills')] })
      }
    }
  } finally {
    await daemon.stop(); await client.close()
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]
    Object.assign(process.env, saved)
    rmSync(dir, { recursive: true, force: true })
  }
})
