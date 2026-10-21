import './fixtures/environment.ts'
import * as assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtemp, mkdir, writeFile, rm, realpath } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { execFile } from 'node:child_process'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { encodePath } from '../../emx/backends/claude.ts'
import { SocketClient } from './client.ts'
const exec = promisify(execFile)

test('native discovery groups worktrees and keeps resume roots for every agent', async (t) => {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-history-')))
  const root = join(dir, 'repo'), other = join(dir, 'other'), projects = join(dir, 'projects')
  await mkdir(root); await mkdir(projects)
  await exec('git', ['init', '-q', root])
  await exec('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Empty', '--allow-empty'])
  await exec('git', ['-C', root, 'worktree', 'add', '-qb', 'other', other])
  const old = process.env.EMX_CLAUDE_PROJECTS_DIR
  process.env.EMX_CLAUDE_PROJECTS_DIR = projects
  const removed = join(root, '.claude/worktrees/deleted')
  for (const [i, path] of [root, other, removed].entries()) {
    const folder = join(projects, encodePath(path)); await mkdir(folder)
    await writeFile(join(folder, `session-${i}.jsonl`), [
      { type: 'user', isMeta: true, message: { content: 'skip' } },
      { type: 'user', message: { content: [{ type: 'text', text: 'First' }, { type: 'image' }] } },
      { type: 'custom-title', customTitle: 'Named\nsecond' },
    ].map((e) => JSON.stringify(e)).join('\n') + '\n')
  }
  const peer = join(dir, 'peer.mjs')
  await writeFile(peer, `#!${process.execPath}\nimport {createInterface} from 'node:readline';
createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);
if(m.method==='initialized')return;
const result=m.method==='initialize'?{}:m.method==='thread/list'?{data:[
{id:'codex',name:'Old Codex',updatedAt:12,cwd:${JSON.stringify(other)}},
{id:'foreign',cwd:'/unrelated'}]}:{sessions:[{id:'dsh',title:'Old dsh',time:13,cwd:${JSON.stringify(other)}}]};
process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n')});\n`, { mode: 0o700 })
  await mkdir(join(dir, 'emx'))
  const config = join(dir, 'emx/config.json')
  await writeFile(config, JSON.stringify({ agents: { codex: { executable: peer }, dsh: { executable: peer } },
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
  const daemon = new DaemonServer({ varDir: dir }); await daemon.start()
  const client = await SocketClient.connect(daemon.socket)
  t.after(async () => { await daemon.stop(); await client.close(); if (old === undefined) delete process.env.EMX_CLAUDE_PROJECTS_DIR; else process.env.EMX_CLAUDE_PROJECTS_DIR = old; await rm(dir, { recursive: true, force: true }) })
  await client.request('hello', { client: 'history', version: daemon.version })
  const claude = (await client.request('sessions/history', { agent: 'claude', root })).items
  assert.equal(claude.length, 3)
  assert.ok(claude.every((v: any) => v.title === 'Named'))
  assert.equal(claude.find((v: any) => v.id === 'session-1')!.root, other)
  assert.equal(claude.find((v: any) => v.id === 'session-2')!.worktree, 'deleted')
  for (const agent of ['codex', 'dsh']) {
    const { items } = await client.request('sessions/history', { agent, root })
    assert.equal(items.length, 1); assert.equal(items[0].id, agent)
    assert.equal(items[0].root, other); assert.equal(items[0].worktree, 'other')
  }
  assert.equal(daemon.sessions.size, 0)
  await client.request('usage/configure', { agents: ['codex'] })
  assert.deepEqual(daemon.usage.pollers.codex.command, [peer])
  await client.request('usage/configure', { pollers: { codex: { command: ['/stale/lisp/command'] } } })
  assert.deepEqual(daemon.usage.pollers.codex.command, [peer])
  await assert.rejects(client.request('sessions/history', { agent: 'unknown', root }))
  await assert.rejects(client.request('sessions/history', { agent: 'codex', root: 'relative' }))
})
