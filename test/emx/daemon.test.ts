// daemon.test.ts --- black-box tests of the emx daemon.
//
// They drive the daemon only through `bin/emx daemon ...` and its Unix
// socket protocol (emx/daemon/protocol.ts), never through its internals:
// every test gets its own --var directory and stops its daemon.

import './fixtures/environment.ts'
import type { ChildProcess } from 'node:child_process'
import type { TestContext } from 'node:test'
import type { AttachResult, Cursor } from '../../emx/daemon/protocol.ts'
import type { DaemonClient as EmxClient, Notification } from './client.ts'

import * as assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { test } from 'node:test'
import { SocketClient as EmxClientClass } from './client.ts'

const ROOT = path.resolve(import.meta.dirname, '..', '..')
const EMX = path.join(ROOT, 'bin', 'emx')
const WAIT_MS = 5000
// A short base for tests that need a short socket path.  On macOS
// os.tmpdir() is /var/folders/.../T, too long for the stale-socket test.
const SHORT_TMP = fs.existsSync('/tmp') ? '/tmp' : os.tmpdir()

interface EnsureInfo {
  socket: string
  version: string
  pid: number
  started: boolean
}

interface CommandResult {
  status: number | null
  stdout: string
  stderr: string
}

function emx(args: string[], timeoutMs = 10_000): CommandResult {
  const result = spawnSync(process.execPath, [EMX, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: timeoutMs,
  })
  if (result.error) {
    throw new Error(`could not run emx ${args.join(' ')}: ${result.error.message}`)
  }
  return {
    status: result.status,
    stdout: String(result.stdout ?? ''),
    stderr: String(result.stderr ?? ''),
  }
}

/** Start a daemon unless one answers, and return its one-line JSON result. */
function ensure(varDir: string, extra: string[] = []): EnsureInfo {
  const result = emx(['daemon', '--var', varDir, '--ensure', ...extra])
  assert.equal(
    result.status,
    0,
    `emx daemon --ensure exited ${result.status}: ${result.stderr.trim() || result.stdout.trim()}`,
  )
  const lines = result.stdout.trim().split('\n').filter(Boolean)
  assert.equal(
    lines.length,
    1,
    `emx daemon --ensure should print one JSON line, got: ${JSON.stringify(result.stdout)}`,
  )
  const info = JSON.parse(lines[0]) as EnsureInfo
  assert.equal(typeof info.socket, 'string', 'ensure result has a socket path')
  assert.ok(info.socket.length > 0, 'ensure result has a non-empty socket path')
  assert.equal(typeof info.version, 'string', 'ensure result has a version')
  assert.equal(typeof info.pid, 'number', 'ensure result has a pid')
  assert.equal(typeof info.started, 'boolean', 'ensure result has started')
  return info
}

function stop(varDir: string): void {
  const result = emx(['daemon', '--var', varDir, '--stop'])
  assert.equal(
    result.status,
    0,
    `emx daemon --stop exited ${result.status}: ${result.stderr.trim() || result.stdout.trim()}`,
  )
}

async function stopAndWait(varDir: string): Promise<void> {
  const lock = path.join(varDir, 'emx', 'daemon.lock')
  const pid = fs.existsSync(lock) ? JSON.parse(fs.readFileSync(lock, 'utf8')).pid : undefined
  try {
    stop(varDir)
  } finally {
    if (pid) {
      const gone = () => {
        try { process.kill(pid, 0); return false } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'ESRCH') return true
          throw error
        }
      }
      try { await waitUntil(gone, WAIT_MS, 'test daemon exit') } catch (error) {
        // Only this temp directory's recorded owner can be terminated here.
        if (!gone()) process.kill(pid, 'SIGKILL')
        await waitUntil(gone, WAIT_MS, 'forced test daemon exit')
        throw error
      }
    }
  }
}

/** A temp --var dir, stopped and removed after the test. */
function varDir(t: TestContext, base = os.tmpdir(), prefix = 'emx-test-'): string {
  const dir = fs.mkdtempSync(path.join(base, prefix))
  t.after(async () => {
    await stopAndWait(dir)
    fs.rmSync(dir, { recursive: true, force: true })
  })
  return dir
}

function track(t: TestContext, client: EmxClient): EmxClient {
  t.after(async () => {
    await client.close()
  })
  return client
}

async function waitUntil(
  predicate: () => boolean,
  timeoutMs = WAIT_MS,
  description = 'condition',
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (predicate()) return
    if (Date.now() > deadline) {
      throw new Error(`timed out after ${timeoutMs} ms waiting for ${description}`)
    }
    await delay(20)
  }
}

/** Wait for a child to exit, rejecting on a timeout and leaving no timer. */
function waitForExit(
  child: ChildProcess,
  timeoutMs: number,
): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
  return new Promise((resolve, reject) => {
    const finish = (code: number | null, signal: NodeJS.Signals | null): void => {
      clearTimeout(timer)
      child.off('exit', finish)
      resolve({ code, signal })
    }
    const timer = setTimeout(() => {
      child.off('exit', finish)
      reject(new Error(`process did not exit within ${timeoutMs} ms`))
    }, timeoutMs)
    child.once('exit', finish)
    if (child.exitCode !== null || child.signalCode !== null) {
      finish(child.exitCode, child.signalCode)
    }
  })
}

/** Connect, retrying until a just-started daemon is listening. */
async function connect(socketPath: string): Promise<EmxClient> {
  const deadline = Date.now() + WAIT_MS
  for (;;) {
    try {
      return await EmxClientClass.connect(socketPath)
    } catch (error) {
      if (Date.now() > deadline) {
        throw new Error(`could not connect to ${socketPath}: ${String(error)}`)
      }
      await delay(25)
    }
  }
}

async function hello(socketPath: string, version: string): Promise<EmxClient> {
  const client = await connect(socketPath)
  const result = await client.request('hello', { client: 'emx-daemon-test', version })
  assert.equal(typeof result.daemon, 'number', 'hello result carries the daemon pid')
  assert.equal(result.version, version, 'hello reports the daemon code version')
  return client
}

function sessionEvents(client: EmxClient, id: string, from = 0): Notification[] {
  return client.notifications.slice(from).filter((n) => n.params?.session === id)
}

function lastSeq(client: EmxClient, id: string): number {
  const seqs = sessionEvents(client, id).map((n) => Number(n.params.seq))
  return seqs.length ? Math.max(...seqs) : 0
}

function historyBlocks(client: EmxClient, id: string, from = 0): any[] {
  return sessionEvents(client, id, from)
    .filter((n) => n.method === 'block/add' && n.params.history === true)
    .map((n) => n.params.block)
}

async function historyDone(client: EmxClient, id: string, from = 0): Promise<Notification> {
  return client.waitFor((n) => n.method === 'history/done' && n.params.session === id,
    WAIT_MS, 'history/done', from)
}

function sendMessage(
  client: EmxClient,
  id: string,
  text: string,
  block?: string,
): Promise<{ queued: boolean }> {
  return client.request('session/send', block === undefined ? { id, text } : { id, text, block })
}

async function sendAndWaitIdle(
  client: EmxClient,
  id: string,
  text: string,
  block?: string,
): Promise<Notification[]> {
  const mark = client.notifications.length
  await sendMessage(client, id, text, block)
  await client.waitFor(
    (n) => n.params?.session === id && n.method === 'status' && n.params.status === 'idle',
    WAIT_MS,
    `status idle after sending ${JSON.stringify(text)}`,
    mark,
  )
  return sessionEvents(client, id, mark)
}

/** A round trip that orders the stream: replies only after earlier writes. */
async function sync(client: EmxClient): Promise<void> {
  await client.request('sessions/list', {})
}

async function openEcho(t: TestContext, info: EnsureInfo): Promise<{
  client: EmxClient
  id: string
  attach: AttachResult
}> {
  const client = track(t, await hello(info.socket, info.version))
  const { id } = await client.request('session/open', { agent: 'echo', root: '' })
  const attach = await client.request('session/attach', { id })
  await historyDone(client, id)
  return { client, id, attach }
}

test('ensure starts one daemon and --stop removes its socket', async (t) => {
  const dir = varDir(t)

  const first = ensure(dir)
  assert.equal(first.started, true, 'the first --ensure starts a daemon')
  await waitUntil(() => fs.existsSync(first.socket), WAIT_MS, 'the daemon socket')
  assert.ok(fs.statSync(first.socket).isSocket(), 'ensure reports a Unix socket path')

  const second = ensure(dir)
  assert.equal(second.started, false, 'the second --ensure finds the daemon already running')
  assert.equal(second.socket, first.socket, 'both runs report the same socket')
  assert.equal(second.pid, first.pid, 'both runs report the same daemon pid')
  assert.equal(second.version, first.version, 'both runs report the same code version')

  const client = track(t, await hello(first.socket, first.version))
  assert.deepEqual(
    (await client.request('sessions/list', {})).sessions,
    [],
    'a fresh daemon lists no sessions',
  )
  await client.close()

  stop(dir)
  await waitUntil(() => !fs.existsSync(first.socket), WAIT_MS, 'the socket to disappear after --stop')
})

test('echo round trip streams a consecutive event sequence', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const client = track(t, await hello(info.socket, info.version))
  const { id } = await client.request('session/open', { agent: 'echo', root: dir })
  const attach = await client.request('session/attach', { id })
  await historyDone(client, id)
  assert.equal(attach.replay, 'fresh', 'the first attach is a fresh view')

  const mark = client.notifications.length
  const sent = await sendMessage(client, id, 'hi', 'u-1')
  assert.equal(sent.queued, false, 'an idle echo session takes the message at once')

  await client.waitFor(
    (n) => n.params?.session === id && n.method === 'status' && n.params.status === 'idle',
    WAIT_MS,
    'status idle at the end of the turn',
    mark,
  )
  const events = sessionEvents(client, id, mark).filter((n) => n.method !== 'info')
  assert.deepEqual(
    events.map((n) => n.method),
    [
      'status',
      'block/add',
      'block/add',
      'block/append',
      'block/append',
      'block/update',
      'status',
    ],
    'the echo agent emits the documented sequence',
  )

  const [running, userAdd, textAdd, prefixAppend, textAppend, update, idle] = events
  assert.equal(running.params.status, 'running')
  assert.equal(userAdd.params.block.type, 'user')
  assert.equal(userAdd.params.block.id, 'u-1', 'the user block takes the id Emacs sent')
  assert.equal(userAdd.params.block.text, 'hi')
  assert.equal(textAdd.params.block.type, 'text')
  assert.equal(textAdd.params.block.kind, 'assistant')
  const textId = textAdd.params.block.id
  assert.equal(typeof textId, 'string')
  assert.equal(prefixAppend.params.id, textId)
  assert.equal(prefixAppend.params.text, 'echo: ')
  assert.equal(textAppend.params.id, textId)
  assert.equal(textAppend.params.text, 'hi')
  assert.equal(update.params.id, textId)
  assert.equal(update.params.fields.done, true)
  assert.equal(update.params.fields.text, 'echo: hi')
  assert.equal(idle.params.status, 'idle')

  const seqs = sessionEvents(client, id, mark).map((n) => Number(n.params.seq))
  assert.equal(seqs[0], attach.seq + 1, 'the first event follows the attach snapshot')
  for (let i = 1; i < seqs.length; i++) {
    assert.equal(seqs[i], seqs[i - 1] + 1, `event ${i} has the next seq (${JSON.stringify(seqs)})`)
  }
})

test('an ask waits for an answer and a second answer is stale', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const { client, id } = await openEcho(t, info)
  const mark = client.notifications.length

  await sendMessage(client, id, 'ask me')
  const askAdd = await client.waitFor(
    (n) => n.params?.session === id && n.method === 'ask/add',
    WAIT_MS,
    'ask/add',
    mark,
  )
  const ask = askAdd.params.ask
  assert.equal(ask.type, 'approval')
  assert.deepEqual(ask.choices, ['allow', 'deny'])

  const answer = await client.request('session/answer', { id, ask: ask.id, choice: 'allow' })
  assert.equal(answer.stale, false, 'the first answer is accepted')

  const update = await client.waitFor(
    (n) => n.params?.session === id &&
      n.method === 'block/update' &&
      n.params.fields?.done === true &&
      typeof n.params.fields.text === 'string' &&
      n.params.fields.text.trim().endsWith('allowed'),
    WAIT_MS,
    'the allowed reply',
    mark,
  )
  assert.equal(update.params.fields.text, 'allowed')
  await client.waitFor(
    (n) => n.params?.session === id && n.method === 'ask/remove' && n.params.id === ask.id,
    WAIT_MS,
    'ask/remove after answering',
    mark,
  )

  const again = await client.request('session/answer', { id, ask: ask.id, choice: 'allow' })
  assert.equal(again.stale, true, 'a late answer for the same ask is stale')
})

test('a tool turn finishes its tool block before replying', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const { client, id } = await openEcho(t, info)

  const events = await sendAndWaitIdle(client, id, 'tool x')
  const toolAdd = events.find((n) => n.method === 'block/add' && n.params.block?.type === 'tool')
  assert.ok(toolAdd, 'the turn adds a tool block')
  assert.equal(toolAdd.params.block.view.kind, 'command')
  const toolId = toolAdd.params.block.id
  assert.equal(typeof toolId, 'string')

  const output = events.find((n) => n.method === 'block/append' && n.params.id === toolId)
  assert.ok(output, 'the tool block gets its output appended')
  assert.ok(String(output.params.text).length > 0, 'the appended output is not empty')

  const done = events.find(
    (n) => n.method === 'block/update' && n.params.id === toolId && n.params.fields?.status === 'done',
  )
  assert.ok(done, 'the tool block is marked done')

  const textAdd = events.find(
    (n) => n.method === 'block/add' && n.params.block?.type === 'text' && n.params.block.kind === 'assistant',
  )
  assert.ok(textAdd, 'the turn adds an assistant reply block')
  assert.ok(
    events.indexOf(output) < events.indexOf(done),
    'the output is appended before the tool is done',
  )
  assert.ok(
    events.indexOf(done) < events.indexOf(textAdd),
    'the tool is done before the reply block starts',
  )
})

test('session/attach after a seq replays exactly the missed events', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const first = track(t, await hello(info.socket, info.version))
  const { id } = await first.request('session/open', { agent: 'echo', root: dir })
  const attach = await first.request('session/attach', { id })
  await historyDone(first, id)
  const beforeTurn = attach.seq

  const mark = first.notifications.length
  await sendMessage(first, id, 'one')
  await first.waitFor(
    (n) => n.params?.session === id && n.method === 'status' && n.params.status === 'idle',
    WAIT_MS,
    'status idle',
    mark,
  )
  const original = sessionEvents(first, id, mark)
  const last = lastSeq(first, id)
  assert.ok(original.length > 0)
  assert.equal(Number(original[original.length - 1].params.seq), last)
  await first.close()

  const second = track(t, await hello(info.socket, info.version))
  const upToDateMark = second.notifications.length
  const upToDate = await second.request('session/attach', { id, after: { epoch: attach.epoch, seq: last } })
  assert.equal(upToDate.replay, 'events', 'the ring buffer can replay from the last seq')
  // A later round trip orders the stream: any event the attach wrote has
  // already been parsed when its reply arrives.
  await sync(second)
  assert.deepEqual(
    sessionEvents(second, id, upToDateMark),
    [],
    'a client that is up to date receives no events again',
  )

  const replayMark = second.notifications.length
  const fromBefore = await second.request('session/attach', { id, after: { epoch: attach.epoch, seq: beforeTurn } })
  assert.equal(fromBefore.replay, 'events')
  await second.waitFor(
    (n) => n.params?.session === id && n.params.seq === last,
    WAIT_MS,
    'the last missed event',
    replayMark,
  )
  const replayed = sessionEvents(second, id, replayMark)
  assert.deepEqual(
    replayed.map((n) => n.params.seq),
    original.map((n) => n.params.seq),
    'the missed seqs come back in order, once each',
  )
  assert.deepEqual(
    replayed.map((n) => ({ method: n.method, params: n.params })),
    original.map((n) => ({ method: n.method, params: n.params })),
    'the replayed events are the same events',
  )
})

test('fresh attach pages history and session/earlier prepends older turns', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const first = track(t, await hello(info.socket, info.version))
  const { id } = await first.request('session/open', { agent: 'echo', root: dir })
  await first.request('session/attach', { id })
  await historyDone(first, id)

  for (const text of ['one', 'two', 'three']) {
    await sendAndWaitIdle(first, id, text)
  }

  // A brand new connection without `after` gets a fresh view of the
  // session's last turns.
  const freshClient = track(t, await hello(info.socket, info.version))
  const freshMark = freshClient.notifications.length
  const fresh = await freshClient.request('session/attach', { id })
  assert.equal(fresh.replay, 'fresh')
  await waitUntil(
    () => historyBlocks(freshClient, id, freshMark).length >= 6,
    WAIT_MS,
    'history blocks for three turns',
  )
  const freshDone = await historyDone(freshClient, id, freshMark)
  assert.equal(freshDone.params.earlier, false)
  assert.equal(sessionEvents(freshClient, id, freshMark).at(-1)?.method, 'history/done')
  const freshBlocks = historyBlocks(freshClient, id, freshMark)
  assert.equal(freshBlocks.length, 6, 'three turns give three user and three text blocks')
  assert.deepEqual(
    freshBlocks.filter((b) => b.type === 'user').map((b) => b.text),
    ['one', 'two', 'three'],
    'the default fresh view includes the earlier turns in order',
  )
  assert.deepEqual(
    freshBlocks.filter((b) => b.type === 'text').map((b) => b.text),
    ['echo: one', 'echo: two', 'echo: three'],
    'both user and text blocks are sent as history',
  )
  for (const n of sessionEvents(freshClient, id, freshMark)) {
    if (n.method === 'block/add') assert.equal(n.params.history, true, 'attach history is marked as history')
    assert.equal(n.params.seq, fresh.seq, 'history blocks do not advance seq')
  }

  // turns: 1 shows only the last turn and says more remain.
  const oneTurn = track(t, await hello(info.socket, info.version))
  const oneMark = oneTurn.notifications.length
  const lastTurn = await oneTurn.request('session/attach', { id, turns: 1 })
  assert.equal(lastTurn.replay, 'fresh')
  assert.equal(lastTurn.earlier, true, 'turns: 1 leaves earlier turns to fetch')
  await waitUntil(
    () => historyBlocks(oneTurn, id, oneMark).length >= 2,
    WAIT_MS,
    'history blocks for the last turn',
  )
  await sync(oneTurn)
  const lastBlocks = historyBlocks(oneTurn, id, oneMark)
  assert.deepEqual(
    lastBlocks.map((b) => [b.type, b.text]),
    [['user', 'three'], ['text', 'echo: three']],
    'turns: 1 omits the two earlier turns',
  )
  assert.equal((await historyDone(oneTurn, id, oneMark)).params.earlier, true)
  const firstShown = lastBlocks[0].id

  // session/earlier adds what was left, before the first shown block.
  const earlierMark = oneTurn.notifications.length
  const earlier = await oneTurn.request('session/earlier', { id, before: firstShown, turns: 5 })
  assert.equal(earlier.earlier, false, 'asking for more than remains exhausts the history')
  await waitUntil(
    () => historyBlocks(oneTurn, id, earlierMark).length >= 4,
    WAIT_MS,
    'older history blocks',
  )
  const earlierDone = await historyDone(oneTurn, id, earlierMark)
  assert.equal(earlierDone.params.earlier, earlier.earlier)
  assert.equal(earlierDone.params.seq, lastTurn.seq)
  const olderNotifications = sessionEvents(oneTurn, id, earlierMark)
  assert.equal(olderNotifications.at(-1)?.method, 'history/done')
  const older = historyBlocks(oneTurn, id, earlierMark)
  assert.deepEqual(
    older.map((b) => [b.type, b.text]),
    [
      ['user', 'one'],
      ['text', 'echo: one'],
      ['user', 'two'],
      ['text', 'echo: two'],
    ],
    'session/earlier sends the older turns in order',
  )
  // Retrying the same request delivers the same page, regardless of prior reads.
  const retryMark = oneTurn.notifications.length
  assert.deepEqual(await oneTurn.request('session/earlier', { id, before: firstShown, turns: 5 }), earlier)
  await historyDone(oneTurn, id, retryMark)
  assert.deepEqual(historyBlocks(oneTurn, id, retryMark), older)
  await assert.rejects(oneTurn.request('session/earlier', { id, before: 'unknown' }), { code: -32602 })
  const emptyMark = oneTurn.notifications.length
  assert.deepEqual(await oneTurn.request('session/earlier', { id, before: older[0].id }), { earlier: false })
  assert.equal((await historyDone(oneTurn, id, emptyMark)).params.earlier, false)
  assert.deepEqual(historyBlocks(oneTurn, id, emptyMark), [])
  for (const n of olderNotifications.filter((n) => n.method === 'block/add')) {
    assert.equal(n.method, 'block/add')
    assert.equal(n.params.history, true)
    assert.equal(n.params.before, firstShown, 'older blocks are inserted before the first shown block')
  }
})

test('a second hello replaces the first client', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const first = track(t, await hello(info.socket, info.version))
  await first.request('session/open', { agent: 'echo', root: dir })
  const mark = first.notifications.length

  const second = track(t, await hello(info.socket, info.version))
  assert.notEqual(first, second)
  await first.waitFor((n) => n.method === 'replaced', WAIT_MS, 'the replaced notification', mark)
})

test('a foreground daemon with --idle-exit 1 exits after its client leaves', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  stop(dir)
  await waitUntil(() => !fs.existsSync(info.socket), WAIT_MS, 'the socket after --stop')

  const child: ChildProcess = spawn(
    process.execPath,
    [EMX, 'daemon', '--var', dir, '--idle-exit', '1'],
    { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] },
  )
  let stdout = ''
  let stderr = ''
  child.stdout?.on('data', (chunk: Buffer) => {
    stdout += chunk.toString()
  })
  child.stderr?.on('data', (chunk: Buffer) => {
    stderr += chunk.toString()
  })
  let exited = false
  child.once('exit', () => {
    exited = true
  })
  t.after(async () => {
    if (exited) return
    child.kill('SIGKILL')
    await waitForExit(child, 1000).catch(() => undefined)
  })

  await waitUntil(() => fs.existsSync(info.socket), WAIT_MS, 'the foreground socket')
  const client = await hello(info.socket, info.version)
  await client.close()

  let closed: { code: number | null; signal: NodeJS.Signals | null }
  try {
    closed = await waitForExit(child, 4000)
  } catch (error) {
    child.kill('SIGKILL')
    assert.fail(
      `${(error as Error).message}; stdout: ${JSON.stringify(stdout)}, ` +
      `stderr: ${JSON.stringify(stderr)}`,
    )
  }
  assert.equal(closed.code, 0, `the idle daemon exits cleanly; stderr: ${stderr}`)
})

test('a stale regular file at the socket path is replaced', async (t) => {
  const dir = varDir(t, SHORT_TMP)
  const info = ensure(dir)
  // This test only means something when the socket really lives under var.
  assert.equal(info.socket, path.join(dir, 'emx', 'daemon.sock'))
  stop(dir)
  await waitUntil(() => !fs.existsSync(info.socket), WAIT_MS, 'the socket after --stop')

  fs.mkdirSync(path.dirname(info.socket), { recursive: true })
  fs.writeFileSync(info.socket, 'not a socket')
  assert.equal(fs.lstatSync(info.socket).isFile(), true)

  const restarted = ensure(dir)
  assert.equal(restarted.started, true, 'a stale file does not count as a running daemon')
  assert.equal(restarted.socket, info.socket)
  assert.ok(fs.statSync(restarted.socket).isSocket(), 'the file was replaced by a listening socket')

  const client = track(t, await hello(restarted.socket, restarted.version))
  await client.request('sessions/list', {})
})

test('a var path too long for a Unix socket uses the OS temp directory', async (t) => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-long-'))
  const dir = path.join(base, 'a'.repeat(80), 'b'.repeat(40))
  fs.mkdirSync(dir, { recursive: true })
  t.after(async () => {
    await stopAndWait(dir)
    fs.rmSync(base, { recursive: true, force: true })
  })

  const underVar = path.join(dir, 'emx', 'daemon.sock')
  assert.ok(
    Buffer.byteLength(underVar) > 100,
    `the fixture path must exceed the socket limit: ${underVar}`,
  )

  const info = ensure(dir)
  assert.equal(info.started, true)
  assert.notEqual(info.socket, underVar, 'the daemon does not bind the too-long path')
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'emx', 'daemon.lock'), 'utf8')).pid,
    info.pid, 'the lock stays in the state directory when the socket falls back')
  assert.equal(
    path.resolve(path.dirname(info.socket)),
    path.resolve(os.tmpdir()),
    'the fallback socket lives directly in the OS temp directory',
  )
  assert.match(
    path.basename(info.socket),
    /^emx-[0-9a-f]{12}\.sock$/,
    'the fallback socket is named after the var directory',
  )

  const client = track(t, await hello(info.socket, info.version))
  await client.request('sessions/list', {})
  await client.close()
  stop(dir)
  await waitUntil(() => !fs.existsSync(info.socket), WAIT_MS, 'the fallback socket after --stop')
})

test('ping, --ensure and --stop do not replace an attached client', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const { client, id } = await openEcho(t, info)
  const probe = track(t, await connect(info.socket))
  const mark = client.notifications.length
  assert.deepEqual(await probe.request('ping', {}), { daemon: info.pid, version: info.version, capabilities: { usage: 1, stopIfIdle: 1 }, liveAgents: 1 })
  await assert.rejects(probe.request('sessions/list', {}), { code: 2 })
  assert.equal(ensure(dir).pid, info.pid)
  await sendAndWaitIdle(client, id, 'still attached')
  assert.equal(client.notifications.slice(mark).some((n) => n.method === 'replaced'), false)
  stop(dir)
  await waitUntil(() => client.closed)
  assert.equal(client.notifications.slice(mark).some((n) => n.method === 'replaced'), false)
})

test('a stale epoch is fresh even when its seq equals the current seq', async (t) => {
  const dir = varDir(t)
  const { client, id, attach } = await openEcho(t, ensure(dir))
  await sendAndWaitIdle(client, id, 'one')
  const mark = client.notifications.length
  const fresh = await client.request('session/attach', {
    id, after: { epoch: attach.epoch + '-stale', seq: lastSeq(client, id) },
  })
  assert.equal(fresh.replay, 'fresh')
  assert.equal(fresh.epoch, attach.epoch)
  await historyDone(client, id, mark)
  assert.equal(historyBlocks(client, id, mark).length, 2)
})

test('fresh history defaults to 20 turns and earlier defaults to 20 without paging state', async (t) => {
  const dir = varDir(t)
  const { client, id } = await openEcho(t, ensure(dir))
  for (let i = 0; i < 23; i++) await sendAndWaitIdle(client, id, `turn-${i}`)
  const mark = client.notifications.length
  const fresh = await client.request('session/attach', { id })
  assert.equal(fresh.earlier, true)
  assert.equal((await historyDone(client, id, mark)).params.earlier, true)
  const blocks = historyBlocks(client, id, mark)
  assert.equal(blocks.length, 40)
  assert.equal(blocks[0].text, 'turn-3')
  const earlierMark = client.notifications.length
  assert.deepEqual(await client.request('session/earlier', { id, before: blocks[0].id }), { earlier: false })
  await historyDone(client, id, earlierMark)
  assert.deepEqual(historyBlocks(client, id, earlierMark).filter((b) => b.type === 'user').map((b) => b.text),
    ['turn-0', 'turn-1', 'turn-2'])
})

for (const shutdown of ['--stop', 'SIGTERM', 'SIGINT'] as const) {
  test(`restart after ${shutdown} restores all blocks with a fresh epoch, no asks and an idle turn`, async (t) => {
    const dir = varDir(t)
    const info = ensure(dir)
    const { client, id, attach } = await openEcho(t, info)
    for (const text of ['one', 'tool two']) await sendAndWaitIdle(client, id, text)
    await sendMessage(client, id, 'ask pending', 'pending-user')
    const ask = await client.waitFor((n) => n.method === 'ask/add' && n.params.session === id)
    // This must be flushed on shutdown even if the debounce has not fired.
    await sendMessage(client, id, 'queued message', 'queued-user')
    const snapshotMark = client.notifications.length
    const snapshot = await client.request('session/attach', { id })
    await historyDone(client, id, snapshotMark)
    const expected = historyBlocks(client, id, snapshotMark)
    const cursor: Cursor = { epoch: attach.epoch, seq: lastSeq(client, id) }
    if (shutdown === '--stop') stop(dir)
    else process.kill(info.pid, shutdown)
    const lock = path.join(dir, 'emx', 'daemon.lock')
    await waitUntil(() => !fs.existsSync(lock), WAIT_MS, 'the shutdown lock to disappear')
    const file = path.join(dir, 'emx', 'sessions', `${id}.json`)
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'))
    assert.deepEqual(saved.blocks, expected)
    assert.deepEqual(saved.queue, [{ text: 'queued message', block: 'queued-user' }])
    assert.equal(snapshot.status, 'running')

    const restarted = ensure(dir)
    const second = track(t, await hello(restarted.socket, restarted.version))
    const mark = second.notifications.length
    const fresh = await second.request('session/attach', { id, after: cursor })
    assert.equal(fresh.replay, 'fresh')
    assert.notEqual(fresh.epoch, cursor.epoch)
    assert.equal(fresh.seq, 0)
    assert.equal(fresh.status, 'idle')
    assert.deepEqual(fresh.asks, [])
    assert.deepEqual(fresh.queue, ['queued message'])
    assert.equal((await second.request('session/answer', { id, ask: ask.params.ask.id, choice: 'allow' })).stale, true)
    await historyDone(second, id, mark)
    assert.deepEqual(historyBlocks(second, id, mark), expected)
    await second.request('session/stop', { id })
    assert.equal(fs.existsSync(file), false)
    assert.equal((await second.request('sessions/list', {})).sessions.some((s) => s.id === id), false)
  })
}

test('debounced transcript writes survive a crash and a stale lock', async (t) => {
  const dir = varDir(t)
  const info = ensure(dir)
  const { client, id } = await openEcho(t, info)
  await sendAndWaitIdle(client, id, 'durable', 'durable-user')
  const file = path.join(dir, 'emx', 'sessions', `${id}.json`)
  await waitUntil(() => JSON.parse(fs.readFileSync(file, 'utf8')).blocks.length === 2,
    WAIT_MS, 'debounced transcript write')
  process.kill(info.pid, 'SIGKILL')
  await waitUntil(() => client.closed)
  const restarted = ensure(dir)
  const second = track(t, await hello(restarted.socket, restarted.version))
  const fresh = await second.request('session/attach', { id })
  assert.equal(fresh.status, 'idle')
  await historyDone(second, id)
  assert.equal(historyBlocks(second, id)[1].text, 'echo: durable')
})

test('two simultaneous foreground daemons leave exactly one owner and its socket', async (t) => {
  const dir = varDir(t, SHORT_TMP)
  const children = [0, 1].map(() => spawn(process.execPath, [EMX, 'daemon', '--var', dir],
    { cwd: ROOT, stdio: ['ignore', 'ignore', 'pipe'] }))
  const errors = ['', '']
  children.forEach((child, i) => {
    child.stderr?.on('data', (chunk) => { errors[i] += chunk })
    t.after(async () => {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
      await waitForExit(child, 1000).catch(() => undefined)
    })
  })
  await waitUntil(() => children.filter((child) => child.exitCode !== null).length === 1,
    WAIT_MS, 'one competing daemon to exit')
  const loser = children.findIndex((child) => child.exitCode !== null)
  assert.equal(children[loser].exitCode, 1)
  assert.match(errors[loser], /Another daemon owns this state directory/)
  const survivor = children[1 - loser]
  const socket = path.join(dir, 'emx', 'daemon.sock')
  const probe = track(t, await connect(socket))
  assert.equal((await probe.request('ping', {})).daemon, survivor.pid)
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'emx', 'daemon.lock'), 'utf8')).pid, survivor.pid)
  assert.equal(ensure(dir).pid, survivor.pid)
  // A non-client may stop the daemon without saying hello.
  await probe.request('daemon/stop', {})
  assert.equal((await waitForExit(survivor, WAIT_MS)).code, 0)
  assert.equal(fs.existsSync(socket), false)
  assert.equal(fs.existsSync(path.join(dir, 'emx', 'daemon.lock')), false)
})

test('an unreadable lock is reclaimed before binding the socket', async (t) => {
  const dir = varDir(t)
  const state = path.join(dir, 'emx')
  fs.mkdirSync(state, { recursive: true })
  fs.writeFileSync(path.join(state, 'daemon.lock'), 'invalid pid')
  const info = ensure(dir)
  const probe = track(t, await connect(info.socket))
  assert.equal((await probe.request('ping', {})).daemon, info.pid)
})
