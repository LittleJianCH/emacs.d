// Session profiles: caller policy, persisted identity and cross-provider choices.
import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import test, { type TestContext } from 'node:test'
import { mkdtemp, mkdir, readFile, writeFile, rm, realpath } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Session } from '../../emx/daemon/session.ts'
import { SocketClient } from './client.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import { validate } from '../../emx/config.ts'
import type { Config } from '../../emx/config.ts'
import { launchArgs } from '../../emx/backends/codex.ts'
import { backends } from '../../emx/backends/backend.ts'
import { mcpInstructions } from '../../emx/cli/main.ts'

const signal = () => new AbortController().signal
const tools = { tools: ['context', 'read_buffer', 'eval', 'render', 'reload', 'alert'].map((name) => ({
  name, description: name, inputSchema: { type: 'object' },
})), readOnly: ['context', 'read_buffer', 'eval', 'removed'] }
async function until(predicate: () => boolean | Promise<boolean>) {
  for (let i = 0; i < 500; i++) { if (await predicate()) return; await delay(10) }
  throw new Error('Timed out waiting for profile test')
}
async function setup(t: TestContext, change: (c: Config) => void = () => {}) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-session-profile-')))
  const config: Config = JSON.parse(await readFile(join(emxRoot, 'config.json'), 'utf8'))
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}
  config.usage.pollInterval = 0
  config.agents.echo = { title: 'Echo', executable: process.execPath }
  change(config)
  const configFile = join(dir, 'defaults.json')
  await writeFile(configFile, JSON.stringify(config))
  const saved = { ...process.env }
  process.env.EMX_CLAUDE_LOG = join(dir, 'claude.log')
  process.env.EMX_CODEX_LOG = join(dir, 'codex.log')
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  await mkdir(process.env.EMX_CLAUDE_PROJECTS_DIR)
  let daemon = new DaemonServer({ varDir: dir, configFile })
  await daemon.start()
  daemon.configuration.close()
  daemon.collab.host.view = async () => {}
  daemon.collab.host.visible = async () => false
  const client = await SocketClient.connect(daemon.socket)
  await client.request('hello', { client: 'test', version: '', tools })
  t.after(async () => {
    await daemon.stop(); await client.close()
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]
    Object.assign(process.env, saved)
    await rm(dir, { recursive: true, force: true })
  })
  const open = (extra: object = {}) => client.request('session/open', { root: dir, ...extra })
  const restart = async () => {
    await daemon.stop()
    daemon = new DaemonServer({ varDir: dir, configFile })
    await daemon.start(); daemon.configuration.close()
    return daemon
  }
  return { dir, config, get daemon() { return daemon }, client, open, restart }
}

test('default orchestrator candidates, schema and role policies are independent of models', async (t) => {
  const x = await setup(t)
  assert.deepEqual(x.config.profiles.orchestrator.candidates, [
    { agent: 'claude', model: 'opus', mode: 'auto', effort: 'high' },
    { agent: 'codex', model: 'gpt-6.1-sol', mode: 'auto', effort: 'xhigh' },
  ])
  assert.doesNotThrow(() => validate(x.config))
  const bad = structuredClone(x.config)
  bad.profiles.coder.tools!.delegate = ['missing']
  assert.throws(() => validate(bad), /configured profile/)
  bad.profiles.coder.tools = { allow: 42 as any }
  assert.throws(() => validate(bad), /string\[\]/)
})

test('new profile opens and legacy native resumes persist coherent identity', async (t) => {
  const x = await setup(t)
  const { id } = await x.open()
  const s = x.daemon.sessions.get(id)!
  assert.equal(s.agent, 'claude'); assert.equal(s.info.profile, 'orchestrator')
  assert.equal(s.settings.model, 'opus'); assert.equal(s.settings.effort, 'high')
  await assert.rejects(x.open({ settings: { model: 'not-a-profile-candidate' } }), /No selectable candidate/)
  const matched = await x.open({ settings: { model: 'gpt-6.1-sol' } })
  assert.equal(x.daemon.sessions.get(matched.id)!.agent, 'codex')
  const legacy = await x.open({ agent: 'echo', resume: 'legacy-native' })
  assert.equal(x.daemon.sessions.get(legacy.id)!.info.profile, undefined)
  const peer = await SocketClient.connect(x.daemon.socket)
  await peer.request('mcp/hello', { session: legacy.id })
  assert.ok((await peer.request('mcp/tools', {})).tools.some((t) => t.name === 'eval'))
  await peer.close()
  await x.daemon.persist()
  const restored = await x.restart()
  assert.equal(restored.sessions.get(id)!.info.profile, 'orchestrator')
  assert.equal(restored.sessions.get(id)!.agent, 'claude')
  assert.equal(restored.sessions.get(legacy.id)!.resumeId(), 'legacy-native')
  const attached = restored.sessions.get(id)!.attach().result
  assert.equal(attached.info.profile, 'orchestrator')
  assert.equal(attached.info.agent, 'claude', 'fresh profile opens expose actual provider before summary notifications')
})

test('profile MCP lists, direct calls, instructions and approval flags use the actual role', async (t) => {
  const x = await setup(t, (c) => {
    c.profiles['explorer-flash'].candidates = [{ agent: 'echo', model: 'read', mode: 'plan' }]
    c.profiles.coder.candidates = [{ agent: 'echo', model: 'write', mode: 'auto' }]
  })
  const ro = await x.open({ profile: 'explorer-flash' })
  const writer = await x.open({ profile: 'coder' })
  for (const [id, readonly] of [[ro.id, true], [writer.id, false]] as const) {
    const peer = await SocketClient.connect(x.daemon.socket)
    try {
      const hello = await peer.request('mcp/hello', { session: id })
      const names = (await peer.request('mcp/tools', {})).tools.map((t) => t.name)
      assert.equal(names.includes('eval'), !readonly)
      assert.equal(names.includes('session_start'), !readonly)
      assert.equal(names.includes('session_ask'), !readonly)
      const s = x.daemon.sessions.get(id)!
      const args = launchArgs(s).join(' ')
      assert.equal(args.includes('tools.eval.approval_mode'), !readonly)
      assert.ok(!args.includes('readOnlyHint'))
      if (readonly) {
        assert.doesNotMatch(hello.instructions, /start them|delegate it|call eval/)
        assert.doesNotMatch(mcpInstructions(names), /call alert|call reload|operations: eval/)
        for (const name of ['eval', 'render', 'reload', 'session_start', 'session_ask', '_session_open']) {
          await assert.rejects(peer.request('mcp/call', { name, arguments: {} }), /not allowed/)
        }
      } else {
        const description = (await peer.request('mcp/tools', {})).tools.find((t) => t.name === 'session_start')!.description
        assert.match(description, /coder-flash/); assert.match(description, /explorer-flash/)
        assert.doesNotMatch(description, /- expert:|- researcher:/)
      }
    } finally { await peer.close() }
  }
  // Role changes on the same adapter replace actual MCP and approval policy.
  await x.client.request('session/select', { id: writer.id, profile: 'explorer-flash', agent: 'echo', model: 'read' })
  assert.deepEqual(x.daemon.sessions.get(writer.id)!.editorTools().tools.map((t) => t.name),
    x.daemon.sessions.get(ro.id)!.editorTools().tools.map((t) => t.name))
})

test('project availability, disabled candidates and quota constrain lists, open and selection', async (t) => {
  const x = await setup(t)
  const { id } = await x.open({ agent: 'echo' })
  x.daemon.sessions.get(id)!.setInfo({ profile: 'orchestrator' })
  x.daemon.collab.enabled = ['codex', 'claude', 'echo']
  x.daemon.collab.host.environment = () => ({ ...process.env, EMX_CLAUDE_EXECUTABLE: '/missing' })
  let list = await x.client.request('session/models', { id })
  assert.equal(list.profile, 'orchestrator')
  assert.deepEqual(list.models.map((m) => m.agent), ['claude', 'codex'])
  assert.equal(list.models[0].selectable, false)
  assert.equal(list.models[1].selectable, true)
  await assert.rejects(x.client.request('session/select', { id, agent: 'claude', model: 'opus' }), /No selectable candidate/)
  await assert.rejects(x.client.request('session/select', { id, agent: 'codex', model: 'not-in-profile' }), /No selectable candidate/)
  await assert.rejects(x.client.request('session/configure', { id, model: 'not-in-profile' }), /No selectable candidate/)
  const opened = await x.open()
  assert.equal(x.daemon.sessions.get(opened.id)!.agent, 'codex')
  x.daemon.configuration.value.collab.disabled.push('orchestrator:codex/gpt-6.1-sol')
  list = await x.client.request('session/models', { id })
  assert.equal(list.models[1].disabled, true); assert.equal(list.models[1].selectable, false)
  await assert.rejects(x.open(), /No selectable candidate/)
  x.daemon.configuration.value.collab.disabled = []
  x.daemon.usage.quota({ agent: 'codex', windows: [{ id: '5h', used: 0.99 }] })
  list = await x.client.request('session/models', { id })
  assert.match(list.models[1].strained!, /quota/)
  assert.equal(list.models[1].selectable, false)
  await assert.rejects(x.client.request('session/select', { id, agent: 'codex', model: 'gpt-6.1-sol' }), /No selectable candidate/)
})

test('cross-provider selection preserves transcript, bounds hidden handoff and never reuses native resume', async (t) => {
  const x = await setup(t)
  const { id } = await x.open()
  const s = x.daemon.sessions.get(id)!
  await x.client.request('session/send', { id, text: 'remember alpha', block: 'first' })
  await until(() => !s.busy() && !s.operating && s.blocks.some((b) => b.type === 'text' && b.done))
  await s.configure({ mode: 'plan' })
  const before = structuredClone(s.blocks), previousResume = s.resumeId()
  assert.ok(previousResume)
  x.daemon.configuration.value.collab.handoffLimit = 40
  const result = await x.client.request('session/select', { id, agent: 'codex', model: 'gpt-6.1-sol' })
  assert.equal(result.id, id); assert.equal(result.agent, 'codex'); assert.equal(result.profile, 'orchestrator')
  assert.equal(result.settings.mode, 'auto', 'model selection applies the configured profile mode')
  assert.deepEqual(s.blocks, before)
  const log = (await readFile(join(x.dir, 'codex.log'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  assert.ok(log.some((r) => r.method === 'thread/start'))
  assert.ok(!log.some((r) => r.method === 'thread/resume' || r.method === 'thread/fork'))
  assert.ok((s.info.providerHistory as any[]).some((h) => h.agent === 'claude' && h.resume === previousResume))
  assert.ok(s.transcript().handoff)
  assert.ok(s.transcript().handoff!.split('\n').slice(1).join('\n').length <= 40)
  await x.daemon.persist()
  const saved = JSON.parse(await readFile(join(x.dir, 'emx/sessions', id + '.json'), 'utf8'))
  assert.equal(saved.handoff, s.transcript().handoff)
  await x.client.request('session/send', { id, text: 'continue beta', block: 'second' })
  await until(() => !s.busy() && !s.operating && s.index.has('second'))
  assert.equal((s.index.get('second') as any).text, 'continue beta')
  assert.equal(s.transcript().handoff, undefined)
  const nextLog = (await readFile(join(x.dir, 'codex.log'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  assert.ok(nextLog.some((r) => r.method === 'turn/start' && JSON.stringify(r.params).includes('Previous conversation for context only')))
})

test('same-provider selection configures model; unrestricted picker defaults MCP profile to orchestrator', async (t) => {
  const x = await setup(t, (c) => {
    c.profiles.coder.candidates = [{ agent: 'echo', model: 'a' }, { agent: 'echo', model: 'b' }]
  })
  const { id } = await x.open({ profile: 'coder' }), s = x.daemon.sessions.get(id)!
  const backend = s.backend
  await x.client.request('session/select', { id, agent: 'echo', model: 'b' })
  assert.equal(s.backend, backend); assert.equal(s.settings.model, 'b'); assert.equal(s.info.profile, 'coder')
  const all = await x.client.request('session/models', { id, scope: 'all' })
  assert.ok(all.models.some((m) => m.agent === 'claude' && m.model === 'haiku'))
  s.setInfo({ profile: 'removed-role' })
  assert.deepEqual(s.editorTools().tools, [], 'unknown persisted roles fail closed')
  await x.client.request('session/select', { id, agent: 'echo', model: null, unrestricted: true })
  assert.equal(s.info.profile, 'orchestrator')
  assert.ok(s.editorTools().tools.some((t) => t.name === 'session_ask'))
  await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'invented', unrestricted: true }), /unavailable/)
  s.setStatus('running')
  await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'a', profile: 'coder' }), /pending work/)
  s.setStatus('idle')
  const ask = s.ask({ type: 'approval', choices: ['allow', 'deny'] })
  await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'a', profile: 'coder' }), /pending work/)
  s.answer([...s.asks.keys()][0], {}); await ask
})

function hold(s: Session) {
  s.backend.send = (text, _images, block) => {
    s.setStatus('running'); s.addBlock({ id: block!, type: 'user', text })
  }
}
function finish(s: Session, text: string) {
  s.addBlock({ id: s.newId('reply'), type: 'text', kind: 'assistant', text, done: true })
  s.setStatus('idle')
}

test('nested helpers share root slots, inherit permissions and block early completion until results are consumed', async (t) => {
  const x = await setup(t, (c) => {
    c.collab.maxActive = 2
    for (const name of ['coder', 'coder-flash', 'explorer-flash']) {
      c.profiles[name].candidates = [{ agent: 'echo', model: name, mode: 'full' }]
    }
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'plan' } })
  const root = x.daemon.sessions.get(id)!
  root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => coder.blocks.length > 0 && !coder.operating)
  assert.equal(coder.settings.mode, 'plan')
  await x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'helper' }, signal())
  const helper = [...x.daemon.sessions.values()].find((s) => s.info.parent === coder.id)!
  await until(() => helper.blocks.length > 0 && !helper.operating)
  assert.equal(helper.settings.mode, 'plan')
  await assert.rejects(x.daemon.collab.call(coder, 'session_start', { profile: 'coder', prompt: 'no' }, signal()), /allowed delegation target/)
  await assert.rejects(x.daemon.collab.call(coder, 'session_start', { context: 'fork', prompt: 'no' }, signal()), /cannot fork/)
  await assert.rejects(x.daemon.collab.call(helper, 'session_start', { profile: 'coder-flash', prompt: 'no' }, signal()), /not allowed/)
  await assert.rejects(x.daemon.collab.call(root, 'session_start', { profile: 'coder-flash', prompt: 'overflow' }, signal()), /most at once/)
  await assert.rejects(x.daemon.collab.call(coder, 'session_start', { profile: 'explorer-flash', prompt: 'overflow' }, signal()), /most at once/)
  finish(coder, 'premature')
  await x.daemon.collab.settle()
  assert.ok(x.daemon.sessions.has(coder.id))
  assert.ok(x.daemon.collab.pending.some((p) => p.target === coder.id))
  assert.equal(x.daemon.collab.mailbox.get(root.id), undefined)
  assert.ok(x.daemon.collab.hasDependencies(coder))
  await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'coder', profile: 'coder' }), /pending work/)
  finish(helper, 'helper-result')
  await until(() => coder.blocks.some((b) => b.type === 'user' && b.text.includes('helper-result')))
  assert.equal(coder.status, 'running', 'result consumption starts another coder turn')
  assert.ok(x.daemon.sessions.has(coder.id))
  finish(coder, 'integrated-result')
  await until(() => !!x.daemon.collab.mailbox.get(root.id)?.length)
  const mail = x.daemon.collab.mailbox.get(root.id)!
  assert.equal(mail.length, 1); assert.match(mail[0].text, /integrated-result/)
  assert.doesNotMatch(mail[0].text, /premature/)
})

test('stopping a coder cancels its helper subtree and pending helper creation', async (t) => {
  const x = await setup(t, (c) => {
    for (const name of ['coder', 'coder-flash']) c.profiles[name].candidates = [{ agent: 'echo', mode: 'auto' }]
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'auto' } })
  const root = x.daemon.sessions.get(id)!; root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => !coder.operating)
  let release!: () => void, entered = false
  const gate = new Promise<void>((resolve) => { release = resolve })
  x.daemon.collab.host.view = async (s) => { hold(s); entered = true; await gate }
  const start = x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'work' }, signal())
  const rejected = assert.rejects(start, /closing|closed/)
  await until(() => entered)
  const stop = x.daemon.collab.call(root, 'session_stop', { session: coder.id }, signal())
  release()
  await rejected; await stop
  assert.equal(x.daemon.sessions.size, 1)
  await x.daemon.collab.settle()
  assert.equal(x.daemon.collab.mailbox.get(root.id), undefined)
})

test('same-provider profile changes retain native resume and regenerate Claude approval flags', async (t) => {
  const x = await setup(t)
  const { id } = await x.open(), s = x.daemon.sessions.get(id)!
  const resume = s.resumeId()
  await x.client.request('session/select', { id, profile: 'reviewer', agent: 'claude', model: 'opus' })
  assert.equal(s.resumeId(), resume)
  assert.equal(s.info.profile, 'reviewer')
  const calls = (await readFile(join(x.dir, 'claude.log'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  const argv = calls.filter((c) => c.type === 'spawn').at(-1).argv as string[]
  assert.equal(argv[argv.indexOf('--resume') + 1], resume)
  const approved = argv[argv.indexOf('--allowedTools') + 1]
  assert.match(approved, /mcp__emacs__context/)
  assert.doesNotMatch(approved, /__eval|__session_start/)
  assert.doesNotMatch(JSON.stringify(s.editorTools()), /readOnlyHint/)
})

test('failed provider switch restores native provider, settings, capabilities and resumability', async (t) => {
  const x = await setup(t)
  const { id } = await x.open(), s = x.daemon.sessions.get(id)!
  const resume = s.resumeId(), backend = s.backend, settings = { ...s.settings }, capabilities = structuredClone(s.capabilities)
  const info = structuredClone(s.info)
  const factory = backends.codex
  t.mock.method(backends, 'codex', (host: import('../../emx/backends/backend.ts').SessionHost) => {
    const backend = factory(host)
    backend.start = () => {
      host.emit({ type: 'capabilities', capabilities: { models: [], modes: [], commands: [] } })
      host.setInfo({ sessionId: 'uncommitted-provider-id' })
      throw new Error('fixture startup failed')
    }
    return backend
  })
  await assert.rejects(x.client.request('session/select', { id, agent: 'codex', model: 'gpt-6.1-sol' }), /fixture startup failed/)
  assert.equal(s.agent, 'claude'); assert.equal(s.backend, backend)
  assert.equal(s.resumeId(), resume); assert.equal(s.info.profile, 'orchestrator')
  for (const [key, value] of Object.entries(settings)) assert.equal((s.settings as any)[key], value)
  assert.deepEqual(s.capabilities, capabilities)
  assert.deepEqual(s.info, info)
  await x.client.request('session/send', { id, text: 'after failure' })
  await until(() => !s.busy() && !s.operating)
  assert.ok(s.blocks.some((b) => b.type === 'user' && b.text === 'after failure'))
})

test('persisted handoff survives process loss and stays hidden in resumed transcript', async () => {
  const s = new Session({ id: 'handoff', agent: 'echo', root: '', restored: true,
    transcript: { blocks: [], queue: [], handoff: 'bounded previous context' } })
  try {
    await s.start()
    s.send('visible request', undefined, 'visible')
    await until(() => !s.busy() && !s.operating)
    assert.equal((s.index.get('visible') as any).text, 'visible request')
    assert.ok(s.blocks.some((b) => b.type === 'text' && b.text.includes('bounded previous context')))
    assert.equal(s.transcript().handoff, undefined)
    const restored = new Session({ id: s.id, agent: 'echo', root: '', restored: true, transcript: s.transcript() })
    restored.update('visible', { text: 'bounded previous context\n\nCurrent request:\nvisible request' })
    assert.equal((restored.index.get('visible') as any).text, 'visible request')
    await restored.stop()
  } finally { await s.stop() }
})

test('inflight nested approval reserves the shared root slot and cancellation releases it', async (t) => {
  const x = await setup(t, (c) => {
    c.collab.maxActive = 2
    for (const name of ['coder', 'coder-flash', 'explorer-flash']) c.profiles[name].candidates = [{ agent: 'echo', mode: 'auto' }]
    c.profiles['coder-flash'].confirm = true
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'auto' } })
  const root = x.daemon.sessions.get(id)!; root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => !coder.operating)
  const controller = new AbortController()
  const start = x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'approval' }, controller.signal)
  const rejected = assert.rejects(start, /aborted|Cancelled/)
  await until(() => coder.asks.size === 1)
  await assert.rejects(x.daemon.collab.call(root, 'session_start', { profile: 'explorer-flash', prompt: 'overflow' }, signal()), /most at once/)
  assert.equal(x.daemon.sessions.size, 2, 'inflight creation reserves a slot before child registration')
  controller.abort(); await rejected
  await x.daemon.collab.call(coder, 'session_start', { profile: 'explorer-flash', prompt: 'released' }, signal())
  assert.equal(x.daemon.sessions.size, 3)
})

test('Codex to Claude constructs a fresh native identity before launching', async (t) => {
  const x = await setup(t)
  const { id } = await x.open({ profile: 'orchestrator', agent: 'codex' })
  const s = x.daemon.sessions.get(id)!, resume = s.resumeId()
  assert.equal(resume, 'fake-thread')
  s.setInfo({ forkFrom: 'old-fork', parentSession: 'old-parent', claudeSyncOffset: 123 })
  await x.client.request('session/select', { id, agent: 'claude', model: 'opus' })
  const calls = (await readFile(join(x.dir, 'claude.log'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  const argv = calls.find((c) => c.type === 'spawn').argv as string[]
  assert.ok(!argv.includes('--resume')); assert.ok(!argv.includes('--fork-session'))
  assert.equal(s.resumeId(), 'fixture-native')
  assert.equal(s.info.forkFrom, null); assert.equal(s.info.parentSession, null)
  assert.ok((s.info.providerHistory as any[]).some((h) => h.agent === 'codex' && h.resume === resume))
})

test('provider factories and validation see only staged identity, and rejection leaves old process intact', async (t) => {
  const s = new Session({ id: 'constructor', agent: 'echo', root: '', restored: true,
    info: { profile: 'old', sessionId: 'old-native', forkFrom: 'old-fork' },
    settings: { model: 'old-model', mode: 'plan' } })
  await s.start(); t.after(() => s.stop())
  const old = s.backend, info = structuredClone(s.info), settings = { ...s.settings }
  for (const agent of ['claude', 'codex', 'dsh', 'pi']) {
    const factory = t.mock.method(backends, agent, (host: import('../../emx/backends/backend.ts').SessionHost) => {
      const cached = host.info.sessionId
      assert.equal(cached, null); assert.equal(host.info.forkFrom, null)
      assert.equal(host.info.profile, 'new'); assert.equal(host.settings.model, 'new-model')
      return { ...old, validateSettings() { throw new Error('fixture validation rejected') } }
    })
    await assert.rejects(s.select(agent, { model: 'new-model' }, 'new', 100, () => true), /validation rejected/)
    assert.equal(s.backend, old); assert.equal(old.alive(), true)
    assert.deepEqual(s.info, info); assert.deepEqual(s.settings, settings)
    factory.mock.restore()
  }
})

test('same-provider partial configure failure rolls back UI and restarts native tuple', async (t) => {
  const x = await setup(t, (c) => {
    c.agents.claude.extraArgs = ['--fixture-reject-mode']
    c.profiles.orchestrator.candidates!.push({ agent: 'claude', model: 'sonnet', effort: 'low', mode: 'ask' })
  })
  const { id } = await x.open(), s = x.daemon.sessions.get(id)!
  const old = { settings: { ...s.settings }, info: structuredClone(s.info), resume: s.resumeId() }
  const seq = s.seq
  await assert.rejects(x.client.request('session/select', { id, agent: 'claude', model: 'sonnet' }), /fixture mode rejected/)
  assert.equal(s.settings.model, 'opus'); assert.equal(s.settings.effort, 'high'); assert.equal(s.settings.mode, 'auto')
  assert.equal(s.info.model, old.info.model); assert.equal(s.info.profile, old.info.profile)
  assert.equal(s.resumeId(), old.resume); assert.equal(s.status, 'idle'); assert.equal(s.backend.alive(), true)
  const events = s.log.filter((e) => e.seq > seq)
  const restored = events.findLast((e) => e.type === 'settings')!
  assert.equal(restored.type, 'settings')
  if (restored.type === 'settings') assert.deepEqual(restored.settings, { model: null, effort: null, mode: null, beforePlan: null, ...old.settings })
  const calls = (await readFile(join(x.dir, 'claude.log'), 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  assert.ok(calls.some((c) => c.request?.subtype === 'set_model' && c.request.model === 'sonnet'), 'failure follows a native partial update')
  const spawns = calls.filter((c) => c.type === 'spawn'), argv = spawns.at(-1).argv as string[]
  assert.equal(spawns.length, 2)
  for (const [flag, value] of [['--model', 'opus'], ['--effort', 'high'], ['--permission-mode', 'auto'], ['--resume', old.resume]]) {
    assert.equal(argv[argv.indexOf(flag!) + 1], value)
  }
  await x.client.request('session/send', { id, text: 'after rollback' })
  await until(() => !s.busy() && !s.operating)
  assert.ok(s.blocks.some((b) => b.type === 'user' && b.text === 'after rollback'))
})

test('failed native rollback is exited rather than falsely idle', async (t) => {
  const x = await setup(t, (c) => {
    c.agents.claude.extraArgs = ['--fixture-reject-mode']
    c.profiles.orchestrator.candidates!.push({ agent: 'claude', model: 'sonnet', mode: 'ask', effort: 'low' })
  })
  const { id } = await x.open(), s = x.daemon.sessions.get(id)!
  const info = structuredClone(s.info), capabilities = structuredClone(s.capabilities)
  t.mock.method(s.backend, 'start', () => {
    s.setInfo({ sessionId: 'failed-recovery', model: 'failed-model' })
    s.emit({ type: 'capabilities', capabilities: { models: [], modes: [], commands: [] } })
    throw new Error('fixture recovery failed')
  })
  await assert.rejects(x.client.request('session/select', { id, agent: 'claude', model: 'sonnet' }), /could not be restored/)
  assert.equal(s.status, 'exited'); assert.equal(s.backend.alive(), false)
  assert.equal(s.settings.model, 'opus'); assert.equal(s.settings.mode, 'auto')
  assert.deepEqual(s.info, info); assert.deepEqual(s.capabilities, capabilities)
})

test('restricted selection matches configured tuples including duplicate models; settings API stays independent', async (t) => {
  const x = await setup(t, (c) => {
    c.profiles.orchestrator.candidates = [
      { agent: 'echo', model: 'same', effort: 'high', mode: 'auto' },
      { agent: 'echo', model: 'same', effort: 'low', mode: 'plan' },
      { agent: 'echo', model: 'other', effort: 'low' },
    ]
  })
  const { id } = await x.open(), s = x.daemon.sessions.get(id)!
  for (const injected of [{ effort: 'xhigh' }, { mode: 'full' }, { effort: 'high', mode: 'plan' }, { effort: null }]) {
    await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'same', ...injected }), /No selectable candidate/)
    assert.equal(s.settings.effort, 'high'); assert.equal(s.settings.mode, 'auto')
  }
  await x.client.request('session/select', { id, agent: 'echo', model: 'same', effort: 'low', mode: 'plan' })
  assert.equal(s.settings.mode, 'plan'); assert.equal(s.settings.effort, 'low')
  await x.client.request('session/select', { id, agent: 'echo', model: 'same' })
  assert.equal(s.settings.mode, 'auto'); assert.equal(s.settings.effort, 'high')
  await x.client.request('session/configure', { id, mode: 'ask', effort: 'arbitrary-provider-supported' })
  assert.equal(s.settings.mode, 'ask'); assert.equal(s.settings.effort, 'arbitrary-provider-supported')
  await x.client.request('session/select', { id, agent: 'echo', model: 'other' })
  assert.equal(s.settings.mode, 'ask'); assert.equal(s.settings.effort, 'low')
  await x.client.request('session/select', { id, agent: 'echo', model: 'same', effort: 'arbitrary', mode: 'full', unrestricted: true })
  assert.equal(s.settings.mode, 'full'); assert.equal(s.settings.effort, 'arbitrary')
  await assert.rejects(x.client.request('session/select', { id, agent: 'echo', model: 'same', effort: 'arbitrary', profile: 'orchestrator', unrestricted: true }), /No selectable candidate/)
  const child = await x.open({ agent: 'echo', parent: id, settings: { mode: 'plan' } })
  await x.client.request('session/select', { id: child.id, agent: 'echo', model: 'same', effort: 'high', mode: 'auto' })
  assert.equal(x.daemon.sessions.get(child.id)!.settings.mode, 'plan', 'configured mode cannot raise a task permission cap')
})

test('closing coder revokes helper pending, mail and continuations before helper deletion persists', async (t) => {
  const x = await setup(t, (c) => {
    for (const name of ['coder', 'coder-flash']) c.profiles[name].candidates = [{ agent: 'echo', mode: 'auto' }]
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'auto' } })
  const root = x.daemon.sessions.get(id)!; root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => !coder.operating)
  await x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'help' }, signal())
  const helper = [...x.daemon.sessions.values()].find((s) => s.info.parent === coder.id)!
  await until(() => !helper.operating)
  finish(coder, 'waiting')
  const send = t.mock.method(coder.backend, 'send', () => { throw new Error('closing coder woke') })
  let release!: () => void, entered = false, calls = 0
  const gate = new Promise<void>((resolve) => { release = resolve })
  const persist = x.daemon.persist.bind(x.daemon)
  t.mock.method(x.daemon, 'persist', async () => { if (++calls === 2) { entered = true; await gate }; await persist() })
  const stop = x.daemon.collab.call(root, 'session_stop', { session: coder.id }, signal())
  await until(() => entered)
  finish(helper, 'cancelled helper result')
  await x.daemon.collab.settle()
  assert.equal(send.mock.callCount(), 0)
  assert.deepEqual(x.daemon.collab.pending, []); assert.equal(x.daemon.collab.mailbox.size, 0)
  release(); await stop
  assert.equal(x.daemon.sessions.size, 1)
  assert.equal(x.daemon.collab.starting, false); assert.deepEqual(x.daemon.collab.outgoing, [])
  const saved = JSON.parse(await readFile(join(x.dir, 'emx/collab.json'), 'utf8'))
  assert.deepEqual(saved.pending, []); assert.deepEqual(saved.mailbox, []); assert.deepEqual(saved.outgoing, [])
})

test('visibility await cannot deliver a helper result after coder beginClose', async (t) => {
  const x = await setup(t, (c) => {
    for (const name of ['coder', 'coder-flash']) c.profiles[name].candidates = [{ agent: 'echo', mode: 'auto' }]
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'auto' } })
  const root = x.daemon.sessions.get(id)!; root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => !coder.operating)
  await x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'help' }, signal())
  const helper = [...x.daemon.sessions.values()].find((s) => s.info.parent === coder.id)!
  await until(() => !helper.operating)
  finish(coder, 'waiting')
  let release!: () => void, entered = false
  const gate = new Promise<void>((resolve) => { release = resolve })
  x.daemon.collab.host.visible = async () => { entered = true; await gate; return false }
  finish(helper, 'helper result')
  const settling = x.daemon.collab.settle()
  await until(() => entered)
  const send = t.mock.method(coder.backend, 'send', () => { throw new Error('closing coder woke') })
  const stop = x.daemon.collab.call(root, 'session_stop', { session: coder.id }, signal())
  release(); await settling; await stop; await x.daemon.collab.settle()
  assert.equal(send.mock.callCount(), 0); assert.equal(x.daemon.sessions.size, 1)
  assert.deepEqual(x.daemon.collab.pending, []); assert.equal(x.daemon.collab.mailbox.size, 0)
  assert.deepEqual(x.daemon.collab.outgoing, [])
})

test('beginClose revokes an already preparing continuation before backend send', async (t) => {
  const s = new Session({ id: 'preparing-close', agent: 'echo', root: '', restored: true })
  const gate = Promise.withResolvers<void>(), entered = Promise.withResolvers<void>()
  t.after(async () => { gate.resolve(); await s.stop() })
  await s.start()
  s.backend.prepare = async () => { entered.resolve(); await gate.promise }
  const send = t.mock.method(s.backend, 'send', () => { throw new Error('cancelled continuation sent') })
  s.sendMessage('helper reply', '@helper', 'hidden')
  await entered.promise
  s.beginClose()
  assert.throws(() => s.send('late mail'), /closed/)
  gate.resolve()
  await s.stop()
  assert.equal(send.mock.callCount(), 0); assert.equal(s.status, 'exited'); assert.deepEqual(s.queue, [])
})

test('closing coder cancels nested approval and releases reserved work without external signal', async (t) => {
  const x = await setup(t, (c) => {
    c.collab.maxActive = 2
    for (const name of ['coder', 'coder-flash']) c.profiles[name].candidates = [{ agent: 'echo', mode: 'auto' }]
    c.profiles['coder-flash'].confirm = true
  })
  const { id } = await x.open({ agent: 'echo', settings: { mode: 'auto' } })
  const root = x.daemon.sessions.get(id)!; root.setStatus('running')
  x.daemon.collab.host.view = async (s) => { hold(s) }
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'work' }, signal())
  const coder = [...x.daemon.sessions.values()].find((s) => s.info.parent === id)!
  await until(() => !coder.operating)
  const start = x.daemon.collab.call(coder, 'session_start', { profile: 'coder-flash', prompt: 'approval' }, signal())
  const rejected = assert.rejects(start, /closing/)
  await until(() => coder.asks.size === 1)
  await x.daemon.collab.call(root, 'session_stop', { session: coder.id }, signal())
  await rejected
  assert.equal(coder.asks.size, 0); assert.equal(x.daemon.sessions.size, 1)
  assert.equal(x.daemon.collab.starting, false); assert.deepEqual(x.daemon.collab.pending, [])
  await x.daemon.collab.call(root, 'session_start', { profile: 'coder', prompt: 'slot released' }, signal())
  assert.equal(x.daemon.sessions.size, 2)
})

test('beginClose revokes queued and in-flight outgoing results and rejects late remote mail', async (t) => {
  const x = await setup(t)
  const { id } = await x.open({ agent: 'echo' }), s = x.daemon.sessions.get(id)!
  const collab = x.daemon.collab, entered = Promise.withResolvers<void>()
  let deliveries = 0, aborted = false
  collab.host.hub = async (_caller, _method, _params, signal) => {
    deliveries++; entered.resolve()
    await new Promise<void>((resolve) => signal.addEventListener('abort', () => { aborted = true; resolve() }, { once: true }))
    signal.throwIfAborted()
  }
  const route = { daemon: 'remote-fixture', session: 'remote-asker' }
  for (const item of ['one', 'two']) collab.outgoing.push({ id: item, route, mail: { handle: item, text: item, source: id } })
  collab.mailbox.set(id, [{ handle: 'helper', text: 'queued' }])
  const settling = collab.settle()
  await entered.promise
  await collab.beginClose(s)
  collab.receive('late', { daemon: 'fixture', session: id }, { handle: 'late', text: 'late mail' })
  await settling
  assert.equal(deliveries, 1); assert.equal(aborted, true)
  assert.deepEqual(collab.outgoing, []); assert.equal(collab.mailbox.size, 0)
  await x.client.request('session/stop', { id })
})
