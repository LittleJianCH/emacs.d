import './fixtures/environment.ts'
import * as assert from 'node:assert/strict'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { mkdtemp, mkdir, writeFile, rm, realpath, utimes, open, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { execFile } from 'node:child_process'
import { history } from '../../emx/backends/history.ts'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
const exec = promisify(execFile)
const timestamp = '2026-10-01T12:00:00.000Z'

async function fixture(t: TestContext) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-history-pi-')))
  const root = join(dir, 'repo'), sessions = join(dir, 'sessions')
  const old = process.env.EMX_PI_SESSIONS_DIR
  process.env.EMX_PI_SESSIONS_DIR = sessions
  t.after(async () => {
    if (old === undefined) delete process.env.EMX_PI_SESSIONS_DIR
    else process.env.EMX_PI_SESSIONS_DIR = old
    await rm(dir, { recursive: true, force: true })
  })
  await mkdir(root)
  async function session(id: string, entries: object[], cwd = root, filename = id) {
    // Pi's documented File Location encoding, independently of the implementation.
    const folder = join(sessions, `--${cwd.slice(1).replace(/[/\\:]/g, '-')}--`)
    await mkdir(folder, { recursive: true })
    const file = join(folder, `2026-10-01T12-00-00-000Z_${filename}.jsonl`)
    await writeFile(file, [
      { type: 'session', version: 3, id, timestamp, cwd }, ...entries,
    ].map((entry) => JSON.stringify(entry)).join('\n') + '\n')
    return file
  }
  return { dir, root, sessions, session }
}

function user(content: string | object[], id = 'a1b2c3d4', parentId: string | null = null) {
  return { type: 'message', id, parentId, timestamp,
    message: { role: 'user', content, timestamp: Date.parse(timestamp) } }
}
function info(name: string, id = 'b2c3d4e5', parentId: string | null = 'a1b2c3d4') {
  return { type: 'session_info', id, parentId, timestamp, name }
}
function padding() {
  return { type: 'custom', id: 'c3d4e5f6', parentId: 'a1b2c3d4', timestamp,
    customType: 'test-padding', data: { text: 'x'.repeat(1100000) } }
}

test('Pi discovers the encoded cwd directory and uses the header resume id', async (t) => {
  const { root, sessions, session } = await fixture(t)
  await session('header-id', [user('  First request\nDetails'), user('Later request', 'd4e5f6a7', 'a1b2c3d4')], root, 'different-filename-id')
  await session('foreign', [user('Other project')], join(root, 'unrelated'))
  const wrongFolder = join(sessions, `--${root.replace(/[/\\:]/g, '-')}--`)
  await mkdir(wrongFolder, { recursive: true })
  await writeFile(join(wrongFolder, 'wrong.jsonl'), JSON.stringify({ type: 'session', id: 'wrong' }) + '\n')
  const items = await history('pi', root)
  assert.equal(items.length, 1)
  assert.deepEqual({ ...items[0], time: 0 }, { id: 'header-id', title: 'First request', time: 0 })
})

test('Pi uses text blocks from the first user message', async (t) => {
  const { root, session } = await fixture(t)
  await session('array-content', [user([
    { type: 'image', data: 'AA==', mimeType: 'image/png' },
    { type: 'text', text: 'Array request' }, { type: 'text', text: 'More details' },
  ])])
  assert.equal((await history('pi', root))[0].title, 'Array request')
})

test('Pi session_info names override the first message and the latest name wins', async (t) => {
  const { root, session } = await fixture(t)
  await session('named', [user('First request'), info('Old name'), info('Latest name', 'd4e5f6a7', 'b2c3d4e5')])
  assert.equal((await history('pi', root))[0].title, 'Latest name')
})

test('Pi an explicit name clear restores the first user message title', async (t) => {
  const { root, session } = await fixture(t)
  await session('cleared', [user('First request'), info('Old name'), info('', 'd4e5f6a7', 'b2c3d4e5')])
  assert.equal((await history('pi', root))[0].title, 'First request')
})

test('Pi returns the newest 50 sessions by mtime rather than filename or header time', async (t) => {
  const { root, session } = await fixture(t)
  for (let i = 0; i < 52; i++) {
    const file = await session(`session-${i}`, [user(`Request ${i}`)], root, String(100 - i))
    await utimes(file, 1700000000 + i, 1700000000 + i)
  }
  const items = await history('pi', root)
  assert.equal(items.length, 50)
  assert.deepEqual(items.map((item) => item.id), Array.from({ length: 50 }, (_, i) => `session-${51 - i}`))
  assert.equal(items[0].time, 1700000051)
})

test('Pi missing sessions directories return an empty history', async (t) => {
  const { root } = await fixture(t)
  assert.deepEqual(await history('pi', root), [])
})

test('Pi resolves absolute roots and rejects relative or editor-remote roots', async (t) => {
  const { root, session } = await fixture(t)
  await session('resolved', [user('Resolved request')])
  assert.equal((await history('pi', `${root}/../repo/`))[0].id, 'resolved')
  await assert.rejects(history('pi', 'relative'), /host-local absolute root/)
  await assert.rejects(history('pi', '/ssh:host:/repo'), /host-local absolute root/)
})

test('Pi titles files over 1 MB using bounded head and tail reads', async (t) => {
  const { root, session } = await fixture(t)
  const first = await session('large-user', [user('Large first request'), padding()])
  await session('large-head-name', [user('Fallback'), info('Name in head'), padding()])
  await session('large-tail-name', [user('Fallback'), info('Old name'), padding(), info('Name in tail', 'd4e5f6a7', 'c3d4e5f6')])
  assert.ok((await stat(first)).size > 1024 * 1024)
  const probe = await open(first, 'r')
  const prototype = Object.getPrototypeOf(probe), read = prototype.read
  await probe.close()
  let bytesRequested = 0
  t.mock.method(prototype, 'read', function (this: unknown, ...args: any[]) {
    bytesRequested += args[0].length
    return read.apply(this, args)
  })
  const items = await history('pi', root)
  assert.deepEqual(Object.fromEntries(items.map((item) => [item.id, item.title])), {
    'large-user': 'Large first request', 'large-head-name': 'Name in head', 'large-tail-name': 'Name in tail',
  })
  assert.ok(bytesRequested > 0 && bytesRequested <= 3 * 2 * 65536, `Requested ${bytesRequested} bytes`)
})

test('Pi daemon history groups git worktrees and preserves their resume roots', async (t) => {
  const { dir, root, session } = await fixture(t)
  const other = join(dir, 'other')
  await exec('git', ['init', '-q', root])
  await exec('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Empty', '--allow-empty'])
  await exec('git', ['-C', root, 'worktree', 'add', '-qb', 'other', other])
  await session('main', [user('Main request')])
  await session('worktree', [user('Worktree request')], other)
  await session('foreign', [user('Other project')], join(dir, 'unrelated'))
  await mkdir(join(dir, 'emx'))
  await writeFile(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  const daemon = new DaemonServer({ varDir: dir })
  await daemon.start()
  try {
    const client = await SocketClient.connect(daemon.socket)
    try {
      await client.request('hello', { client: 'history-pi', version: daemon.version })
      const { items } = await client.request('sessions/history', { agent: 'pi', root })
      assert.equal(items.length, 2)
      const main = items.find((item) => item.id === 'main')!
      assert.equal(main.root, undefined)
      assert.equal(main.worktree, undefined)
      assert.equal(items.find((item) => item.id === 'worktree')!.root, other)
      assert.equal(items.find((item) => item.id === 'worktree')!.worktree, 'other')
      const reverse = (await client.request('sessions/history', { agent: 'pi', root: other })).items
      assert.equal(reverse.find((item) => item.id === 'main')!.root, root)
      assert.equal(reverse.find((item) => item.id === 'main')!.worktree, 'repo')
      assert.equal(reverse.find((item) => item.id === 'worktree')!.root, undefined)
      assert.equal(daemon.sessions.size, 0)
    } finally { await client.close() }
  } finally { await daemon.stop() }
})
