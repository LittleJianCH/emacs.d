import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { connect } from 'node:net'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Connection } from '../../emx/daemon/rpc.ts'
import { Collaboration } from '../../emx/daemon/collab.ts'

async function until(check: () => boolean) {
  for (let i = 0; i < 300; i++) { if (check()) return; await delay(10) }
  assert.fail('Timed out waiting for collaboration')
}
test('two daemons route list/read/ask and durable mailbox replies through the editor', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-hub-'))
  const oldHome = process.env.HOME
  process.env.HOME = dir
  const daemons = new Map<string, DaemonServer>()
  const peers = new Map<string, Connection>()
  let loseReceipt = true
  const attach = async (key: string) => {
    const daemon = daemons.get(key)!, socket = connect(daemon.socket)
    await new Promise<void>((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject) })
    const peer = new Connection(socket)
    peer.onRequest = async (method, p) => {
      assert.equal(method, 'editor/call')
      if (p.method === '_session_visible') return { ok: true, result: { visible: true } }
      if (p.method === '_session_open') return { ok: true, result: true }
      const other = [...peers.keys()].find((k) => k !== key)!
      const remote = peers.get(other)!
      const args = p.params
      if (p.method === '_collab_sessions') {
        const result: any = await remote.request('collab/list', {})
        return { ok: true, result: result.sessions.map((s: any) => ({ ...s, place: other })) }
      }
      if (p.method === '_collab_read' || p.method === '_collab_ask') {
        const list: any = await remote.request('collab/list', {})
        const target = list.sessions.find((s: any) => s.id === args.session)
        if (!target) return { ok: false, error: 'No cross-daemon session' }
        return { ok: true, result: await remote.request(p.method === '_collab_read' ? 'collab/read' : 'collab/ask',
          { ...args, id: target.session, route: { daemon: key, session: p.caller.session },
            origin: { handle: args.origin?.handle, agent: args.origin?.agent } }) }
      }
      if (p.method === '_collab_deliver') {
        const source = peers.get(args.route.daemon)
        if (!source) return { ok: false, error: 'Source daemon is not attached to Emacs' }
        const delivered = await source.request('collab/deliver', args)
        if (loseReceipt) { loseReceipt = false; throw new Error('Simulated lost acknowledgment') }
        return { ok: true, result: delivered }
      }
      throw new Error('Unknown hub call: ' + p.method)
    }
    peers.set(key, peer)
    await peer.request('hello', { client: 'hub-test', version: daemon.version })
    return peer
  }
  try {
    for (const key of ['local', 'host']) {
      const varDir = join(dir, key); mkdirSync(join(varDir, 'emx'), { recursive: true })
      writeFileSync(join(varDir, 'emx/config.json'), JSON.stringify({
        collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
      const daemon = new DaemonServer({ varDir, ...(key === 'host' ? { remote: true, clientId: 'hub-test' } : {}) })
      await daemon.start(); daemons.set(key, daemon)
    }
    const local = await attach('local'), host = await attach('host')
    const source = await local.request('session/open', { agent: 'echo', root: dir, handle: 'source' }) as any
    const dest = await host.request('session/open', { agent: 'echo', root: dir, handle: 'dest' }) as any
    const caller = daemons.get('local')!.sessions.get(source.id)!
    const target = daemons.get('host')!.sessions.get(dest.id)!
    const signal = new AbortController().signal
    const listed: any = await daemons.get('local')!.collab.call(caller, 'sessions', {}, signal)
    assert.ok(listed.sessions.some((s: any) => s.id === '@dest' && s.place === 'host'))
    assert.match(await daemons.get('local')!.collab.call(caller, 'session_read', { session: '@dest' }, signal) as string, /No turns yet/)
    const child = await local.request('session/open', { agent: 'echo', root: dir, parent: source.id }) as any
    await assert.rejects(daemons.get('local')!.collab.call(daemons.get('local')!.sessions.get(child.id)!,
      'session_ask', { session: '@dest', prompt: 'nested' }, signal), /doesn't ask/)
    await local.request('session/stop', { id: child.id })
    caller.setStatus('running')
    await daemons.get('local')!.collab.call(caller, 'session_ask', { session: '@dest', prompt: 'ask routed approval' }, signal)
    await until(() => target.asks.size === 1)
    assert.equal((target.blocks.find((b) => b.type === 'user') as any).origin, '@source')
    // Both editor transports vanish while the target still works.
    for (const p of peers.values()) p.socket.destroy()
    peers.clear()
    await until(() => [...daemons.values()].every((d) => !d.client))
    target.answer([...target.asks.keys()][0], { choice: 'allow' })
    await until(() => target.status === 'idle')
    await daemons.get('host')!.collab.settle()
    const restored = new Collaboration(daemons.get('host')!.collab.host)
    restored.restore()
    assert.equal(restored.outgoing.length, 1)
    assert.equal(restored.outgoing[0].route.session, caller.id)
    restored.stop()
    await assert.rejects(daemons.get('local')!.collab.call(caller, 'session_read', { session: '@dest' }, signal), /Emacs is not attached/)
    await assert.rejects(daemons.get('local')!.collab.call(caller, 'session_ask', { session: '@dest', prompt: 'offline' }, signal), /Emacs is not attached/)
    await attach('local'); await attach('host')
    await until(() => !!daemons.get('local')!.collab.mailbox.get(caller.id)?.length)
    const mail = daemons.get('local')!.collab.mailbox.get(caller.id)!
    assert.equal(mail.length, 1)
    assert.match(mail[0].text, /allowed/)
    await daemons.get('host')!.collab.settle()
    assert.equal(mail.length, 1)
    assert.equal(daemons.get('local')!.collab.receipts.size, 1)
    caller.setStatus('idle')
    await daemons.get('local')!.collab.settle()
    await until(() => caller.blocks.some((b) => b.type === 'user' && b.origin === '@dest'))
    assert.match(await daemons.get('local')!.collab.call(caller, 'session_read', { session: '@dest' }, signal) as string, /allowed/)
  } finally {
    for (const p of peers.values()) p.socket.destroy()
    for (const d of daemons.values()) await d.stop()
    if (oldHome === undefined) delete process.env.HOME
    else process.env.HOME = oldHome
    rmSync(dir, { recursive: true, force: true })
  }
})

test('MCP sessions retains daemon sessions and reports unavailable peers while Emacs is detached', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'emx-detached-list-'))
  mkdirSync(join(dir, 'emx'))
  writeFileSync(join(dir, 'emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 } }))
  const daemon = new DaemonServer({ varDir: dir })
  let editor: Connection | undefined, mcp: Connection | undefined
  try {
    await daemon.start()
    editor = new Connection(connect(daemon.socket))
    await editor.request('hello', { client: 'test', version: daemon.version })
    const { id } = await editor.request('session/open', { agent: 'echo', root: dir, handle: 'own' }) as any
    mcp = new Connection(connect(daemon.socket))
    await mcp.request('mcp/hello', { session: id })
    editor.socket.destroy()
    await until(() => !daemon.client)
    const result: any = await mcp.request('mcp/call', { name: 'sessions', arguments: {} })
    assert.deepEqual(result.sessions.map((s: any) => s.id), ['@own'])
    assert.match(result.note, /Other daemons are unavailable.*Emacs is not attached/)
  } finally {
    editor?.socket.destroy(); mcp?.socket.destroy(); await daemon.stop()
    rmSync(dir, { recursive: true, force: true })
  }
})
