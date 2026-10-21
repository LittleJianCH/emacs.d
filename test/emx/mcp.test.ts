// Real stdio MCP client + daemon socket + fake bidirectional editor.
import './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Connection } from '../../emx/daemon/rpc.ts'

const definition = (name: string) => ({ name, description: name, inputSchema: { type: 'object' } })
const tools = { tools: ['context', 'deferred', 'hold', 'error'].map(definition), readOnly: ['context'] }

async function setup(t: import('node:test').TestContext) {
  const dir = await mkdtemp(join(tmpdir(), 'emx-mcp-'))
  const daemon = new DaemonServer({ varDir: dir })
  t.after(async () => { await daemon.stop(); await rm(dir, { recursive: true, force: true }) })
  await daemon.start()
  const editor = new Connection(createConnection(daemon.socket))
  t.after(() => editor.socket.destroy())
  const calls: any[] = []
  editor.onRequest = (_method, params) => {
    assert.equal(_method, 'editor/call')
    calls.push(params)
    if (params.method === 'error') return { ok: false, error: 'Editor failure' }
    if (['hold', 'deferred'].includes(params.method)) return { ok: true, pending: params.method }
    if (params.method === '_poll') return params.params.cancel ? { ok: true, result: null }
      : params.params.id === 'hold' ? { ok: true, pending: 'hold' } : { ok: true, result: 'deferred result' }
    return { ok: true, result: params.caller }
  }
  await editor.request('hello', { client: 'test', version: daemon.version, tools })
  const { id } = await editor.request('session/open', { agent: 'echo', root: dir }) as any
  const child = spawn(process.execPath, [fileURLToPath(new URL('../../bin/emx', import.meta.url)), 'mcp'], {
    env: { ...process.env, EMX_DAEMON_SOCKET: daemon.socket, EMX_SESSION: id,
      EMX_EMACSCLIENT: '/does-not-exist', EMX_REMOTE_AGENT: '1' }, stdio: 'pipe',
  })
  t.after(() => { child.kill() })
  let next = 0
  const messages: any[] = []
  createInterface({ input: child.stdout }).on('line', (line) => messages.push(JSON.parse(line)))
  const wait = async (predicate: (m: any) => boolean) => {
    for (let i = 0; i < 500; i++) {
      const found = messages.find(predicate)
      if (found) return found
      await delay(10)
    }
    throw new Error('MCP message timed out: ' + JSON.stringify(messages))
  }
  const send = (method: string, params = {}) => {
    const id = ++next
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    return { id, result: wait((m) => m.id === id).then((m) => m.result) }
  }
  const request = (method: string, params = {}) => send(method, params).result
  return { dir, daemon, editor, calls, child, wait, request, send, id }
}

test('stdio initialize, list, caller identity, deferred polling, errors, list changes and offline cache', async (t) => {
  const { dir, daemon, editor, calls, request, wait, id } = await setup(t)
  const init = await request('initialize')
  assert.equal(init.capabilities.tools.listChanged, true)
  assert.equal(init.instructions.includes('config_read'), false)
  assert.deepEqual(await request('tools/list'), { tools: daemon.collab.tools(tools).tools })
  assert.equal(daemon.client?.socket.destroyed, false, 'MCP hello does not replace editor')
  const result = await request('tools/call', { name: 'context', arguments: {} })
  assert.deepEqual(JSON.parse(result.content[0].text), { session: id, root: dir, place: null })
  assert.equal((await request('tools/call', { name: 'deferred' })).content[0].text, 'deferred result')
  assert.ok(calls.some((call) => call.method === '_poll'))
  assert.equal((await request('tools/call', { name: 'error' })).isError, true)
  const updated = { ...tools, tools: [...tools.tools, definition('new')] }
  editor.notify('editor/tools', updated)
  await wait((m) => m.method === 'notifications/tools/list_changed')
  assert.deepEqual(await request('tools/list'), { tools: daemon.collab.tools(updated).tools })
  await daemon.editor.flush()
  assert.deepEqual(JSON.parse(await readFile(join(dir, 'emx/tools.json'), 'utf8')), updated)
  editor.socket.destroy()
  await delay(50)
  assert.deepEqual(await request('tools/list'), { tools: daemon.collab.tools(updated).tools })
  const offline = await request('tools/call', { name: 'context' })
  assert.equal(offline.isError, true)
  assert.match(offline.content[0].text, /Emacs is not attached/)
  await daemon.stop()
  const restored = new DaemonServer({ varDir: dir })
  try {
    await restored.start()
    const peer = new Connection(createConnection(restored.socket))
    try {
      await peer.request('mcp/hello', { session: id })
      assert.deepEqual(await peer.request('mcp/tools', {}), { tools: daemon.collab.tools(updated).tools })
      await assert.rejects(peer.request('mcp/call', { name: 'context' }), /Emacs is not attached/)
    } finally { peer.socket.destroy() }
  } finally { await restored.stop() }
})

test('cancellation cleans up the deferred result and stops polling', async (t) => {
  const { request, send, child, calls } = await setup(t)
  await request('tools/list')
  const call = send('tools/call', { name: 'hold' })
  while (!calls.some((call) => call.method === 'hold')) await delay(10)
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: call.id } }) + '\n')
  assert.match((await call.result).content[0].text, /Cancelled/)
  await delay(100)
  assert.ok(calls.some((call) => call.method === '_poll' && call.params.cancel))
  const count = calls.length
  await delay(1100)
  assert.equal(calls.length, count)
})

test('editor replacement fails a running call, MCP cannot take over or control sessions', async (t) => {
  const { daemon, request, send, calls, id } = await setup(t)
  await request('tools/list')
  const call = send('tools/call', { name: 'hold' })
  while (!calls.some((call) => call.method === 'hold')) await delay(10)
  const replacement = new Connection(createConnection(daemon.socket))
  const peer = new Connection(createConnection(daemon.socket))
  try {
    await replacement.request('hello', { client: 'new', version: daemon.version })
    assert.match((await call.result).content[0].text, /Emacs is not attached/)
    await peer.request('mcp/hello', { session: id })
    await assert.rejects(peer.request('hello', { client: 'bad', version: '' }), /MCP connections/)
    await assert.rejects(peer.request('session/stop', { id }), /MCP connections/)
  } finally { replacement.socket.destroy(); peer.socket.destroy() }
})

test('cancellation releases a deferred id that arrives after cancellation', async (t) => {
  const { editor, request, send, child, calls } = await setup(t)
  await request('tools/list')
  let started = false
  let release!: (value: unknown) => void
  const original = editor.onRequest
  editor.onRequest = (method, params, id) => {
    if (params.method === 'hold') {
      started = true
      return new Promise((resolve) => { release = resolve })
    }
    return original(method, params, id)
  }
  const call = send('tools/call', { name: 'hold' })
  while (!started) await delay(10)
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: call.id } }) + '\n')
  assert.match((await call.result).content[0].text, /Cancelled/)
  release({ ok: true, pending: 'late' })
  for (let i = 0; i < 100 && !calls.length; i++) await delay(10)
  assert.ok(calls.some((call) => call.method === '_poll' && call.params.id === 'late' && call.params.cancel))
})

test('editor detach promptly fails deferred and not-yet-answered calls', async (t) => {
  const { editor, request, send, calls } = await setup(t)
  await request('tools/list')
  let started = false
  const original = editor.onRequest
  editor.onRequest = (method, params, id) => {
    if (params.method === 'context') { started = true; return new Promise(() => {}) }
    return original(method, params, id)
  }
  const deferred = send('tools/call', { name: 'hold' })
  const unanswered = send('tools/call', { name: 'context' })
  while (!started || !calls.some((call) => call.method === 'hold')) await delay(10)
  editor.socket.destroy()
  for (const call of [deferred, unanswered]) {
    const result = await call.result
    assert.equal(result.isError, true)
    assert.match(result.content[0].text, /Emacs is not attached/)
  }
})


test('session stop fails pending MCP calls and releases deferred editor work', async (t) => {
  const { daemon, editor, request, send, calls, id } = await setup(t)
  await request('tools/list')
  let started = false
  let release!: (value: unknown) => void
  const original = editor.onRequest
  editor.onRequest = (method, params, requestId) => {
    if (params.method === 'context' && params.caller.session === id) {
      started = true
      return new Promise((resolve) => { release = resolve })
    }
    return original(method, params, requestId)
  }
  const deferred = send('tools/call', { name: 'hold' })
  const unanswered = send('tools/call', { name: 'context' })
  while (!started || !calls.some((call) => call.method === 'hold')) await delay(10)
  const { id: otherId } = await editor.request('session/open', { agent: 'echo', root: '/other' }) as any
  const other = new Connection(createConnection(daemon.socket))
  try {
    await other.request('mcp/hello', { session: otherId })
    await editor.request('session/stop', { id })
    for (const call of [deferred, unanswered]) {
      const result = await call.result
      assert.equal(result.isError, true)
      assert.match(result.content[0].text, /Session stopped/)
    }
    release({ ok: true, pending: 'late-stopped' })
    for (let i = 0; i < 100 && calls.filter((call) => call.params.cancel).length < 2; i++) await delay(10)
    for (const pending of ['hold', 'late-stopped']) {
      assert.ok(calls.some((call) => call.method === '_poll' && call.params.id === pending && call.params.cancel))
    }
    const count = calls.length
    await delay(1100)
    assert.equal(calls.length, count, 'stopped calls no longer poll')
    assert.deepEqual(await other.request('mcp/call', { name: 'context' }),
      { session: otherId, root: '/other', place: null })
  } finally { other.socket.destroy() }
})


test('MCP hello binds once to an existing session', async (t) => {
  const { daemon, editor, id, dir } = await setup(t)
  const peer = new Connection(createConnection(daemon.socket))
  try {
    await assert.rejects(peer.request('mcp/hello', { session: 'missing' }), /No such session/)
    await assert.rejects(peer.request('mcp/tools', {}), /Say hello/)
    await peer.request('mcp/hello', { session: id })
    const { id: second } = await editor.request('session/open', { agent: 'echo', root: '/second' }) as any
    await assert.rejects(peer.request('mcp/hello', { session: second }), /already bound/)
    await assert.rejects(peer.request('mcp/hello', { session: id }), /already bound/)
    assert.deepEqual(await peer.request('mcp/call', { name: 'context' }),
      { session: id, root: dir, place: null })
  } finally { peer.socket.destroy() }
})
