// pi.test.ts --- Pi RPC behavior through a daemon and a deterministic fake CLI.
import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { SocketClient } from './client.ts'
import type { ChoiceId, OpenParams } from '../../emx/daemon/protocol.ts'
import { allowedModel, toolView } from '../../emx/backends/pi.ts'
import { merge, validate } from '../../emx/config.ts'

async function setup(t: TestContext, options: Partial<OpenParams> = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'emx-pi-'))
  const oldLog = process.env.EMX_PI_LOG
  process.env.EMX_PI_LOG = join(dir, 'rpc.jsonl')
  await mkdir(join(dir, 'emx'))
  await writeFile(join(dir, 'emx/config.json'), JSON.stringify({ usage: { pollInterval: 0 },
    collab: { handleCommand: [], agentHandleCommands: {}, closeFinished: false } }))
  const daemon = new DaemonServer({ varDir: dir })
  let client: Awaited<ReturnType<typeof SocketClient.connect>>
  t.after(async () => {
    await daemon.stop(); await client?.close()
    if (oldLog === undefined) delete process.env.EMX_PI_LOG
    else process.env.EMX_PI_LOG = oldLog
    await rm(dir, { recursive: true, force: true })
  })
  await daemon.start()
  client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'pi-test', version: daemon.version, tools: {
    tools: [{ name: 'context', description: 'Context', inputSchema: { type: 'object' } }], readOnly: ['context'] } })
  const { id } = await client.request('session/open', { agent: 'pi', root: dir, ...options })
  const attached = await client.request('session/attach', { id })
  await client.waitFor((n) => n.method === 'history/done')
  const session = daemon.sessions.get(id)!
  const idle = (from: number, sessionId = id) => client.waitFor((n) => n.method === 'status'
    && n.params.status === 'idle' && n.params.session === sessionId, 5000, 'Pi settled', from)
  const send = async (text: string) => {
    const from = client.notifications.length
    await client.request('session/send', { id, text }); await idle(from)
    return client.notifications.slice(from)
  }
  const requests = async () => (await readFile(join(dir, 'rpc.jsonl'), 'utf8')).trim().split('\n')
    .map((line) => JSON.parse(line)).filter((r) => r.direction === 'in')
  const call = async (tool: string, input = {}, choice?: ChoiceId) => {
    const from = client.notifications.length
    await client.request('session/send', { id, text: JSON.stringify({ tool, input }) })
    let ask
    if (choice) {
      ask = (await client.waitFor((n) => n.method === 'ask/add', 5000, 'approval', from)).params.ask
      await client.request('session/answer', { id, ask: ask.id, choice })
    }
    await idle(from)
    assert.equal(client.notifications.slice(from).filter((n) => n.method === 'ask/add').length, choice ? 1 : 0)
    return { ask, reply: (await requests()).filter((r) => r.type === 'extension_ui_response').at(-1) }
  }
  return { dir, daemon, client, id, attached, session, send, requests, call, idle }
}

test('new Pi sessions explicitly select a filtered default, advertise models and efforts, and bind daemon MCP', async (t) => {
  const { attached, requests, daemon, id, session } = await setup(t)
  const init = (await requests())[0]
  assert.equal(init.argv[init.argv.indexOf('--model') + 1], 'opencode-go/kimi-k3')
  assert.ok(!init.argv.includes('--thinking'), 'no effort means Pi keeps its own default level')
  assert.equal(init.argv[init.argv.indexOf('--tools') + 1], '+grep,+find,+ls', 'read-only search tools join the defaults')
  assert.ok(!init.argv.includes('--no-session'))
  assert.ok(!init.argv.includes('--approve'))
  assert.match(init.argv[init.argv.indexOf('-e') + 1], /pi\/emacs-extension.js$/)
  assert.equal(init.socket, daemon.socket); assert.equal(init.session, id)
  assert.equal(init.emx, fileURLToPath(new URL('../../bin/emx', import.meta.url)))
  assert.deepEqual(attached.capabilities.models.map((m: any) => m.id), ['opencode-go/kimi-k3', 'opencode-go/glm-5.3-flash'])
  assert.deepEqual(attached.capabilities.models[1].efforts, ['low', 'high', 'max'])
  assert.deepEqual(attached.capabilities.modes, ['plan', 'ask', 'edits', 'auto', 'full'])
  assert.equal(session.settings.model, 'opencode-go/kimi-k3')
})

test('plan denies mutations; read-only builtins and audited Emacs MCP calls always pass', async (t) => {
  const { call, client, id, session } = await setup(t, { settings: { mode: 'plan', beforePlan: 'full' } })
  for (const tool of ['write', 'edit', 'bash', 'mcp__emacs__open', 'unknown']) {
    assert.equal((await call(tool, { path: 'a', command: 'echo hi' })).reply.value, 'deny-plan')
  }
  for (const tool of ['read', 'grep', 'find', 'ls', 'mcp__emacs__context', 'mcp__emacs__sessions']) {
    assert.equal((await call(tool)).reply.value, 'allow')
  }
  assert.equal(session.settings.beforePlan, 'full')
  await client.request('session/configure', { id, mode: 'ask' })
  assert.equal(session.settings.beforePlan, 'ask')
})

test('ask presents tool views; always grants are per tool and cannot bypass plan', async (t) => {
  const { call, client, id } = await setup(t, { settings: { mode: 'ask' } })
  const first = await call('bash', { command: 'echo hi' }, 'always')
  assert.equal(first.ask.view.kind, 'command'); assert.equal(first.ask.view.command, 'echo hi')
  assert.deepEqual(first.ask.choices, ['allow', 'always', 'deny'])
  assert.equal((await call('bash', { command: 'echo again' })).reply.value, 'allow')
  assert.equal((await call('custom', {}, 'deny')).reply.value, 'deny')
  await client.request('session/configure', { id, mode: 'plan' })
  assert.equal((await call('bash')).reply.value, 'deny-plan')
})

test('edits permits local writes and edits, asks for external, traversal, tilde, URL and symlink paths', async (t) => {
  const { dir, call } = await setup(t, { settings: { mode: 'edits' } })
  const outside = await mkdtemp(join(tmpdir(), 'emx-pi-outside-'))
  t.after(() => rm(outside, { recursive: true, force: true }))
  await symlink(outside, join(dir, 'escape'))
  await symlink(join(outside, 'missing'), join(dir, 'dangling'))
  assert.equal((await call('edit', { path: 'a', edits: [{ oldText: 'old', newText: 'new' }] })).reply.value, 'allow')
  assert.equal((await call('write', { path: join(dir, 'new/sub/file'), content: 'x' })).reply.value, 'allow')
  assert.equal((await call('write', { path: '@local', content: 'x' })).reply.value, 'allow')
  for (const path of [join(outside, 'a'), '../escape', 'escape/a', 'escape/../a',
    'dangling', '~/outside', '@' + outside + '/x', 'file://' + outside + '/x']) {
    const { ask, reply } = await call('edit', { path, edits: [{ oldText: 'old', newText: 'new' }] }, 'deny')
    assert.equal(reply.value, 'deny'); assert.equal(ask.view.kind, 'edit')
    assert.match(ask.view.diff, /-old\n\+new/)
  }
  assert.equal((await call('bash', { command: 'echo hi' }, 'allow')).reply.value, 'allow')
})

test('auto permits bash and local edits, full permits unknown MCP tools and external edits', async (t) => {
  const { call, client, id } = await setup(t, { settings: { mode: 'auto' } })
  assert.equal((await call('bash', { command: 'echo hi' })).reply.value, 'allow')
  assert.equal((await call('write', { path: 'a' })).reply.value, 'allow')
  await call('mcp__emacs__open', {}, 'deny')
  await client.request('session/configure', { id, mode: 'full' })
  assert.equal((await call('write', { path: '/outside/file' })).reply.value, 'allow')
  assert.equal((await call('custom')).reply.value, 'allow')
})

test('streaming preserves Unicode separators and authoritative text, tools, notices and usage', async (t) => {
  const { send, session, daemon, call } = await setup(t)
  await send('hello')
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.kind === 'thinking' && b.text === '最终思考' && b.done))
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === '最终回复\u2028保留\u2029字符' && b.done))
  assert.equal(daemon.usage.report({ range: 'all' }).total.tokens, 14)
  assert.equal(daemon.usage.report({ range: 'all' }).total.turns, 1)
  await call('read', { path: 'a' })
  assert.ok(session.blocks.some((b) => b.type === 'tool' && b.view.kind === 'read' && b.output === 'allow' && b.status === 'done'))
  await send('retry')
  assert.ok(session.blocks.some((b) => b.type === 'notice' && b.notice.args?.message === 'fixture retry'))
  await send('/handled')
  assert.equal(session.status, 'idle')
})

test('live model and thinking changes validate filters even while hibernated; prompt reconciles native model changes', async (t) => {
  const { client, id, session, requests, send } = await setup(t)
  await client.request('session/configure', { id, model: 'opencode-go/glm-5.3-flash', effort: 'low' })
  assert.equal(session.info.model, 'opencode-go/glm-5.3-flash'); assert.equal(session.settings.effort, 'low')
  assert.ok((await requests()).some((r) => r.type === 'set_model' && r.modelId === 'glm-5.3-flash'))
  assert.ok((await requests()).some((r) => r.type === 'set_thinking_level' && r.level === 'low'))
  await assert.rejects(client.request('session/configure', { id, effort: 'off' }), /does not support/)
  assert.equal(session.settings.effort, 'low')
  await send('bad-model'); await send('reconciled')
  const calls = await requests(), prompt = calls.findLastIndex((r) => r.type === 'prompt')
  assert.ok(calls.findLastIndex((r) => r.type === 'set_model') < prompt)
  await session.hibernate()
  for (const model of ['opencode-go/model-free', 'other-provider/other']) {
    await assert.rejects(client.request('session/configure', { id, model }), /excluded/)
  }
  assert.equal(session.settings.model, 'opencode-go/glm-5.3-flash')
  await send('resumed')
  await client.request('session/configure', { id, model: 'opencode-go/kimi-k3' })
  assert.equal(session.settings.effort, 'max', 'a model switch clears the inherited unsupported effort')
})

test('steer and abort stay live; idle waits for agent_settled, queued messages run afterward', async (t) => {
  const { client, id, idle, session, requests } = await setup(t)
  let from = client.notifications.length
  await client.request('session/send', { id, text: 'hold' })
  await client.waitFor((n) => n.method === 'status' && n.params.status === 'running', 5000, 'running', from)
  assert.deepEqual(await client.request('session/steer', { id, text: 'steered' }), { accepted: true })
  await idle(from)
  assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === 'steered'))
  from = client.notifications.length
  await client.request('session/send', { id, text: 'hold' })
  await client.request('session/interrupt', { id }); await idle(from)
  assert.ok((await requests()).some((r) => r.type === 'abort'))
  assert.deepEqual(await client.request('session/steer', { id, text: 'late' }), { accepted: false })
  from = client.notifications.length
  await client.request('session/send', { id, text: 'hold' })
  assert.deepEqual(await client.request('session/send', { id, text: 'queued' }), { queued: true })
  await client.request('session/interrupt', { id })
  const first = await idle(from)
  await idle(client.notifications.indexOf(first) + 1)
  const log = (await readFile(join(session.root, 'rpc.jsonl'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  const queued = log.findIndex((r) => r.direction === 'in' && r.type === 'prompt' && r.message === 'queued')
  const settled = log.findLastIndex((r, i) => i < queued && r.direction === 'out' && r.type === 'agent_settled')
  assert.ok(settled >= 0 && settled < queued)
})

test('pending approvals cancel on abort and a live switch to plan takes precedence', async (t) => {
  const { client, id, idle, session, requests } = await setup(t, { settings: { mode: 'ask' } })
  for (const action of ['plan', 'abort']) {
    const from = client.notifications.length
    await client.request('session/send', { id, text: JSON.stringify({ tool: 'write', input: { path: 'a' } }) })
    const ask = (await client.waitFor((n) => n.method === 'ask/add', 5000, 'approval', from)).params.ask
    if (action === 'plan') {
      await client.request('session/configure', { id, mode: 'plan' })
      await client.request('session/answer', { id, ask: ask.id, choice: 'always' })
    } else await client.request('session/interrupt', { id })
    await idle(from)
    assert.equal(session.asks.size, 0)
    if (action === 'plan') assert.equal((await requests()).filter((r) => r.type === 'extension_ui_response').at(-1).value, 'deny-plan')
    await client.request('session/configure', { id, mode: 'ask' })
  }
})

test('resume uses --session; fork uses --fork and ephemeral children keep their editor tool set', async (t) => {
  const { daemon, client, id, session, send, requests } = await setup(t, { resume: 'saved-native' })
  assert.equal(session.resumeId(), 'saved-native')
  assert.ok((await requests())[0].argv.includes('--session'))
  await send('history')
  await session.backend.flush?.()
  // No editor is needed to open the child view; reconnect after creating it.
  await client.close()
  await daemon.collab.call(session, 'session_start', { context: 'fork', prompt: 'hold', handle: 'pi-fork' }, new AbortController().signal)
  const child = [...daemon.sessions.values()].find((s) => s.info.parent === id)!.id
  const childStart = (await requests()).find((r) => r.session === child)
  assert.equal(childStart.argv[childStart.argv.indexOf('--fork') + 1], 'saved-native')
  assert.ok(!childStart.argv.includes('--no-session'), 'Pi 1.3 ignores --fork when --no-session is set')
  const peer = await SocketClient.connect(daemon.socket)
  t.after(() => peer.close())
  await peer.request('hello', { client: 'pi-reconnected', version: daemon.version })
  await peer.request('session/attach', { id: child })
  await peer.waitFor((n) => n.method === 'history/done')
  const idle = (sessionId: string, from: number) => peer.waitFor((n) => n.method === 'status'
    && n.params.status === 'idle' && n.params.session === sessionId, 5000, 'settled', from)
  let from = peer.notifications.length
  await peer.request('session/interrupt', { id: child }); await idle(child, from)
  peer.notify('editor/tools', { tools: [], readOnly: [] })
  // The notification is asynchronous; send only once the daemon holds the new set.
  const hasContext = () => session.editorTools().tools.some((tool) => tool.name === 'context')
  for (let i = 0; i < 100 && hasContext(); i++) await new Promise((r) => setTimeout(r, 20))
  assert.ok(!hasContext())
  from = peer.notifications.length
  await peer.request('session/send', { id: child, text: 'child' }); await idle(child, from)
  assert.equal((await requests()).filter((r) => r.session === child && r.type === 'get_available_models').length, 1)
  await peer.request('session/attach', { id })
  from = peer.notifications.length
  await peer.request('session/send', { id, text: 'new-tools' }); await idle(id, from)
  assert.equal((await requests()).filter((r) => r.session === id && r.type === 'get_available_models').length, 2)
  assert.equal((await requests()).filter((r) => r.session === id).at(-1).argv.includes('--session'), true)
})

test('fresh children use --no-session without suppressing fork history', async (t) => {
  const { requests } = await setup(t, { parent: 'parent' })
  assert.ok((await requests())[0].argv.includes('--no-session'))
})

test('installed skills replace discovery and images use Pi ImageContent', async (t) => {
  const { dir, requests, client, id, idle } = await setup(t, {
    skills: { skillsDir: '/tmp/pi-skills', supersededSkills: ['atomic-review'] } })
  const args = (await requests())[0].argv
  assert.ok(args.includes('--no-skills'))
  assert.equal(args[args.indexOf('--skill') + 1], '/tmp/pi-skills/.claude/skills')
  const path = join(dir, 'image.png'); await writeFile(path, 'fake image')
  const from = client.notifications.length
  await client.request('session/send', { id, text: 'image', images: [path] }); await idle(from)
  const prompt = (await requests()).find((r) => r.type === 'prompt')
  assert.deepEqual(prompt.images, [{ type: 'image', mimeType: 'image/png', data: Buffer.from('fake image').toString('base64') }])
})

test('bridge forwards all tools, blocks cancellations and plan denials, and never advertises readOnlyHint', async () => {
  const saved = Object.fromEntries(['EMX_PI_EMX', 'EMX_SESSION', 'EMX_DAEMON_SOCKET'].map((k) => [k, process.env[k]]))
  Object.assign(process.env, { EMX_PI_EMX: '/runtime/bin/emx', EMX_SESSION: 'test', EMX_DAEMON_SOCKET: '/socket' })
  try {
    let registration: any, handler: any
    const extensionUrl = new URL('../../lisp/agent/backend/pi/emacs-extension.js', import.meta.url).href
    const { default: extension } = await import(extensionUrl)
    extension({ registerMcpServer: (name: string, config: any) => { registration = { name, config } },
      on: (event: string, callback: any) => { assert.equal(event, 'tool_call'); handler = callback } } as any)
    assert.equal(registration.name, 'emacs')
    assert.equal(registration.config.command, process.execPath)
    assert.deepEqual(registration.config.args, ['/runtime/bin/emx', 'mcp'])
    assert.equal(registration.config.exposure, 'direct')
    assert.ok(!JSON.stringify(registration).includes('readOnlyHint'))
    for (const toolName of ['bash', 'write', 'mcp__emacs__context']) {
      for (const choice of ['allow', 'always', 'deny', 'deny-plan', undefined]) {
        const result = await handler({ toolName, toolCallId: 'call', input: { path: 'a' } }, { ui: {
          select: async (title: string, options: string[]) => {
            assert.deepEqual(JSON.parse(title.slice(13)), { tool: toolName, id: 'call', input: { path: 'a' } })
            assert.deepEqual(options, ['allow', 'always', 'deny', 'deny-plan']); return choice
          },
        } })
        if (choice === 'allow' || choice === 'always') assert.equal(result, undefined)
        else {
          assert.equal(result.block, true)
          assert.match(result.reason, choice === 'deny-plan' ? /plan mode/ : /The user declined this tool call\./)
        }
      }
    }
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value
    }
  }
})

test('model filter configuration validates regexes and tool views include all Pi edit replacements', async () => {
  const defaults = JSON.parse(await readFile(new URL('../../emx/config.json', import.meta.url), 'utf8'))
  for (const patch of [{ defaultModel: '' }, { models: { include: ['['], exclude: [] } },
    { models: { include: [1], exclude: [] } }, { models: { include: [], exclude: ['('] } }]) {
    assert.throws(() => validate(merge(defaults, { agents: { pi: patch } })), /config.agents.pi/)
  }
  assert.equal(allowedModel('opencode-go/kimi-k3'), true)
  assert.equal(allowedModel('opencode-go/FREE'), false)
  assert.equal(allowedModel('other/chat'), false)
  assert.equal(toolView('/root', 'edit', { path: '/root/a', edits: [
    { oldText: 'old', newText: 'new' }, { oldText: 'before', newText: 'after' },
  ] }).diff, '--- a\n+++ a\n-old\n+new\n--- a\n+++ a\n-before\n+after')
})
