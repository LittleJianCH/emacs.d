// Public daemon entry points: place-specific approval flags and private metadata.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { checkoutRoot } from '../../emx/daemon/paths.ts'
import { SocketClient } from './client.ts'

for (const agent of ['claude', 'codex', 'dsh']) {
  for (const remote of [false, true]) test(`${agent} uses the audited set at its place (host: ${remote})`, async (t) => {
    const dir = await mkdtemp(join(tmpdir(), 'emx-readonly-'))
    const prefix = 'EMX_' + agent.toUpperCase()
    const keys = ['HOME', prefix + '_EXECUTABLE', prefix + '_LOG', 'EMX_CLAUDE_PROJECTS_DIR']
    const previous = keys.map((key) => process.env[key])
    process.env.HOME = dir
    process.env[prefix + '_EXECUTABLE'] = join(checkoutRoot, 'test/emx/fixtures', agent + '.mjs')
    process.env[prefix + '_LOG'] = join(dir, 'cli.jsonl')
    process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
    await mkdir(join(dir, 'emx'))
    await writeFile(join(dir, 'emx/config.json'), JSON.stringify({
      collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
    }))
    const daemon = new DaemonServer({ varDir: dir, remote })
    let client: Awaited<ReturnType<typeof SocketClient.connect>> | undefined
    let mcp: typeof client
    t.after(async () => {
      await mcp?.close(); await client?.close(); await daemon.stop()
      keys.forEach((key, i) => {
        if (previous[i] === undefined) delete process.env[key]
        else process.env[key] = previous[i]
      })
      await rm(dir, { recursive: true, force: true })
    })
    await daemon.start()
    client = await SocketClient.connect(daemon.socket)
    const tools = ['context', 'eval', 'inspect.state', 'session_start',
      ...(remote ? ['config_read', 'config_write', 'config_edit'] : [])].map((name) => ({
      name, description: name, inputSchema: { type: 'object' }, annotations: { readOnlyHint: true },
    }))
    await client.request('hello', { client: 'readonly-test', version: daemon.version,
      tools: { tools, readOnly: ['inspect.state', 'context', 'context', 'session_start', 'removed',
        ...(remote ? ['config_write', 'config_edit'] : [])] } })
    const { id } = await client.request('session/open', { agent, root: dir })
    await client.request('session/attach', { id })
    await client.waitFor((n) => n.method === 'history/done')
    // dsh returns before its fixture has finished appending initialize to disk.
    let calls: any[] = []
    for (let i = 0; i < 500; i++) {
      calls = (await readFile(join(dir, 'cli.jsonl'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line))
      if (calls.some((c) => c.type === 'spawn' || c.method === 'initialize')) break
      await delay(10)
    }
    const expected = [...(remote ? ['config_read'] : []), 'context', 'inspect.state', 'session_read', 'sessions']
    if (agent === 'claude') {
      const argv = calls.find((c) => c.type === 'spawn').argv
      assert.deepEqual(argv[argv.indexOf('--allowedTools') + 1].split(','), expected.map((n) => 'mcp__emacs__' + n))
      assert.equal(argv.at(-2), '--allowedTools')
    } else if (agent === 'codex') {
      const argv: string[] = calls.find((c) => c.method === 'initialize').argv
      const overrides = argv.filter((_, i) => argv[i - 1] === '-c')
      assert.equal(new Set(overrides.map((s) => s.split('=')[0])).size, overrides.length)
      assert.deepEqual(overrides.filter((s) => s.includes('.approval_mode=')), expected.map((name) =>
        `mcp_servers.emacs.tools.${name.includes('.') ? JSON.stringify(name) : name}.approval_mode="approve"`))
    } else {
      assert.deepEqual(calls.find((c) => c.method === 'initialize').params.mcpServers[0].readOnly, expected)
    }
    mcp = await SocketClient.connect(daemon.socket)
    await mcp.request('mcp/hello', { session: id })
    const listed = await mcp.request('mcp/tools', {})
    assert.ok(listed.tools.every((tool) => !('annotations' in tool) && !('readOnlyHint' in tool)))
    assert.equal('readOnly' in listed, false)
    await daemon.editor.flush()
    const cached = JSON.parse(await readFile(join(dir, 'emx/tools.json'), 'utf8'))
    assert.ok(cached.readOnly.includes('context'))
    assert.ok(cached.tools.every((tool: any) => !('annotations' in tool)))
  })
}
