import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Session } from '../../emx/daemon/session.ts'
import { definitions, profileCandidates, profiles, startSummary } from '../../emx/daemon/collab.ts'
import { SocketClient } from './client.ts'
import { emxRoot } from '../../emx/daemon/paths.ts'
import type { Config, ProfileCandidate } from '../../emx/config.ts'
import type { QuotaEntry } from '../../emx/usage/types.ts'

const signal = () => new AbortController().signal
const defaults = (): Config => JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
const claude = { agent: 'claude', model: 'sonnet', mode: 'auto' }
const codex = { agent: 'codex', model: 'gpt-6.1-sol', mode: 'auto' }
const pi = { agent: 'pi', model: 'opencode-go/kimi-k3', mode: 'auto' }
async function setup(t: TestContext, candidates: ProfileCandidate[] = [claude, codex, pi], quotas: QuotaEntry[] = [], caller = 'echo') {
  const dir = mkdtempSync(join(tmpdir(), 'emx-candidates-'))
  const oldLog = process.env.EMX_CLAUDE_LOG
  process.env.EMX_CLAUDE_LOG = join(dir, 'claude.jsonl')
  const config = defaults()
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}
  config.collab.closeFinished = false; config.usage.pollInterval = 0
  config.profiles.worker = { cost: 'medium', description: 'Test role', candidates }
  const file = join(dir, 'defaults.json')
  writeFileSync(file, JSON.stringify(config))
  writeFileSync(join(dir, 'agent-quota.json'), JSON.stringify(quotas))
  const daemon = new DaemonServer({ varDir: dir, configFile: file })
  t.after(async () => {
    await daemon.stop(); rmSync(dir, { recursive: true, force: true })
    if (oldLog === undefined) delete process.env.EMX_CLAUDE_LOG
    else process.env.EMX_CLAUDE_LOG = oldLog
  })
  await daemon.start()
  // Exercise candidate/quota policy independently of account evidence probes.
  t.mock.method(daemon.usage, 'candidateAvailability', () => undefined)
  // These tests mutate effective policy directly; file watching is tested elsewhere.
  daemon.configuration.close()
  const parent = new Session({ id: 'parent', agent: caller, root: dir, settings: { mode: 'auto' }, info: { handle: 'parent' },
    editorTools: () => daemon.collab.tools(daemon.editor.tools, dir, parent) })
  parent.setStatus('running'); daemon.sessions.set(parent.id, parent)
  const start = async (profile = 'worker') => {
    const receipt = String(await daemon.collab.call(parent, 'session_start', { profile, prompt: 'hold' }, signal()))
    const child = [...daemon.sessions.values()].filter((s) => s.info.parent === parent.id).at(-1)!
    return { receipt, child }
  }
  return { dir, daemon, config: daemon.configuration.value, parent, start }
}

test('roles are listed while any agent is available, independently of quotas or caller, respecting the Pi filter', () => {
  const c = defaults(), env = { PATH: '', EMX_CODEX_EXECUTABLE: process.execPath }
  assert.equal(profiles(c, ['codex'], env).length, 7)
  assert.deepEqual(profiles(c, [], env), [])
  assert.deepEqual(profiles(c, ['claude'], env), [])
  c.profiles.onlyPi = { candidates: [{ agent: 'pi', model: 'other-provider/other' }] }
  const piEnv = { PATH: '', EMX_PI_EXECUTABLE: process.execPath }
  assert.ok(!profiles(c, ['pi'], piEnv).some(([name]) => name === 'onlyPi'))
  assert.deepEqual(profileCandidates({ agent: 'claude', model: 'haiku', candidates: [codex] }),
    [{ agent: 'claude', model: 'haiku', mode: undefined, effort: undefined }])
})

test('session_start follows candidate order and preserves role, model, effort and permission cap', async (t) => {
  const x = await setup(t, [{ ...claude, effort: 'high', mode: 'full' }, codex])
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'claude'); assert.equal(child.settings.model, 'sonnet')
  assert.equal(child.settings.effort, 'high'); assert.equal(child.settings.mode, 'auto')
  assert.equal(child.info.profile, 'worker')
  assert.match(receipt, /Started @worker \(Claude sonnet, fresh\)/)
  assert.doesNotMatch(receipt, /Skipped candidates/)
  x.config.profiles.worker.candidates = [codex, claude]
  const next = await x.start()
  assert.equal(next.child.agent, 'codex'); assert.equal(next.child.settings.model, 'gpt-6.1-sol')
})

test('session_start checks enabled agents and executable availability in the caller root every call', async (t) => {
  const x = await setup(t)
  x.daemon.collab.enabled = ['codex', 'pi']
  const first = await x.start()
  assert.equal(first.child.agent, 'codex')
  assert.match(first.receipt, /Claude sonnet: unavailable here/)
  const roots: string[] = []
  let environment = { ...process.env, EMX_CODEX_EXECUTABLE: '/does/not/exist' }
  x.daemon.collab.host.environment = (root) => { roots.push(root); return environment }
  const next = await x.start()
  assert.equal(next.child.agent, 'pi')
  assert.match(next.receipt, /Claude sonnet: unavailable here; Codex gpt-6.1-sol: unavailable here/)
  environment = { ...process.env, EMX_CODEX_EXECUTABLE: process.execPath }
  assert.equal((await x.start()).child.agent, 'codex')
  assert.ok(roots.every((root) => root === x.dir))
})

test('collab/profiles, guidance and selection share root-specific executable and Pi availability', async (t) => {
  const x = await setup(t, [claude, codex, { ...pi, model: 'other-provider/other' }])
  x.config.profiles.onlyPi = { candidates: [{ agent: 'pi', model: 'other-provider/other' }] }
  const otherRoot = join(x.dir, 'other'), roots: string[] = []
  mkdirSync(otherRoot)
  // This socket peer tests the catalog, not the editor's child-view RPC.
  x.daemon.collab.host.view = async () => {}
  let environment: NodeJS.ProcessEnv = { ...process.env, EMX_CLAUDE_EXECUTABLE: '/missing-claude' }
  x.daemon.collab.host.environment = (root) => {
    roots.push(root)
    return root === otherRoot ? { ...process.env, EMX_CODEX_EXECUTABLE: '/missing-codex' } : environment
  }
  const client = await SocketClient.connect(x.daemon.socket)
  try {
    await client.request('hello', { client: 'test', version: '' })
    const catalog = async (root?: string) => (await client.request('collab/profiles', root === undefined ? {} : { root }))
      .profiles.find((p) => p.name === 'worker')!
    assert.deepEqual((await catalog()).candidates.map((c) => c.available), [true, true, false])
    assert.equal(roots.length, 0, 'omitting root retains the process environment fallback')
    assert.deepEqual((await catalog(x.dir)).candidates.map((c) => c.available), [false, true, false])
    assert.equal((await x.start()).child.agent, 'codex')
    assert.deepEqual((await catalog(otherRoot)).candidates.map((c) => c.available), [true, false, false])
    const otherParent = new Session({ id: 'other-parent', agent: 'echo', root: otherRoot, settings: { mode: 'auto' } })
    x.daemon.sessions.set(otherParent.id, otherParent)
    await x.daemon.collab.call(otherParent, 'session_start', { profile: 'worker', prompt: 'hold' }, signal())
    assert.equal([...x.daemon.sessions.values()].find((s) => s.info.parent === otherParent.id)!.agent, 'claude')
    assert.ok(roots.includes(x.dir) && roots.includes(otherRoot))
    assert.doesNotMatch(x.daemon.collab.startSummary(x.dir), /onlyPi/)
    assert.doesNotMatch(x.daemon.collab.tools({ tools: [], readOnly: [] }, x.dir).tools
      .find((tool) => tool.name === 'session_start')!.description, /onlyPi/)
    environment = { ...process.env, EMX_CODEX_EXECUTABLE: '/missing-codex' }
    assert.deepEqual((await catalog(x.dir)).candidates.map((c) => c.available), [true, false, false])
    assert.equal((await x.start()).child.agent, 'claude', 'each call uses the current root environment')
    await assert.rejects(client.request('collab/profiles', { root: 42 } as any), /root/)
  } finally { await client.close() }
})

for (const model of ['other-provider/other', 'opencode-go/model-free']) test(`Pi filter skips ${model}`, async (t) => {
  const x = await setup(t, [{ ...pi, model }, codex])
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'codex')
  assert.ok(receipt.includes(`Pi ${model}: model excluded by agents.pi.models`))
})
test('Pi filtering also checks the default model when a candidate omits its model', async (t) => {
  const x = await setup(t, [{ agent: 'pi' }, codex])
  x.config.agents.pi.defaultModel = 'other-provider/other'
  assert.match((await x.start()).receipt, /Pi: model excluded by agents.pi.models/)
})

const strainedCases: { name: string, quota: QuotaEntry, reason: string }[] = [
  { name: 'used threshold', quota: { agent: 'claude', host: null, windows: [{ id: '5h', used: 0.93 }] }, reason: '5h quota 93% used' },
  { name: 'exact threshold', quota: { agent: 'claude', windows: [{ id: 'weekly', used: 0.9 }] }, reason: 'weekly quota 90% used' },
  { name: 'limited despite low usage', quota: { agent: 'claude', windows: [{ id: '5h', label: '五小时', used: 0.1, limited: true }] }, reason: '5h quota limited' },
  { name: 'all balances exhausted', quota: { agent: 'claude', windows: [], balance: [{ amount: 0, currency: 'USD' }, { amount: -1, currency: 'CNY' }] }, reason: 'balance exhausted' },
]
for (const { name, quota, reason } of strainedCases) test(`seeded UsageService snapshot skips ${name}`, async (t) => {
  const x = await setup(t, [claude, codex], [quota])
  assert.equal(x.daemon.collab.profiles().profiles.find((p) => p.name === 'worker')!.candidates[0].strained, reason)
  const before = definitions(x.config)
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'codex'); assert.ok(receipt.includes(`Claude sonnet: ${reason}`))
  assert.deepEqual(definitions(x.config), before)
})
test('per-agent quota threshold overrides global policy in both directions, including zero', async (t) => {
  const x = await setup(t, [claude, codex], [{ agent: 'claude', windows: [{ id: '5h', used: 0.85 }] }])
  x.config.agents.claude.quotaSkip = 0.8
  assert.equal((await x.start()).child.agent, 'codex', 'agent threshold can be lower than global')
  x.config.collab.quotaSkip = 0.8; x.config.agents.claude.quotaSkip = 0.95
  assert.equal((await x.start()).child.agent, 'claude', 'agent threshold can be higher than global')
  x.config.collab.quotaSkip = 1
  x.config.agents.claude.quotaSkip = 0
  assert.equal((await x.start()).child.agent, 'codex', 'zero is an override, not a missing value')
  delete x.config.agents.claude.quotaSkip
  assert.equal((await x.start()).child.agent, 'claude', 'deleting override restores global policy')
})

for (const disabled of [['worker'], ['worker:claude', 'worker:codex']]) {
  test(`disabled profile ${JSON.stringify(disabled)} disappears from all guidance and errors on start`, async (t) => {
    const x = await setup(t, [claude, codex])
    x.config.collab.disabled = disabled
    assert.ok(!profiles(x.config).some(([name]) => name === 'worker'))
    assert.doesNotMatch(definitions(x.config).find((tool) => tool.name === 'session_start')!.description, /worker/)
    assert.doesNotMatch(startSummary(x.config), /worker/)
    const client = await SocketClient.connect(x.daemon.socket), mcp = await SocketClient.connect(x.daemon.socket)
    try {
      await client.request('hello', { client: 'test', version: '' })
      const hello = await mcp.request('mcp/hello', { session: x.parent.id })
      assert.doesNotMatch(hello.instructions, /worker/)
      const catalog = await client.request('collab/profiles', {})
      const worker = catalog.profiles.find((p) => p.name === 'worker')!
      assert.equal(worker.disabled, true)
      assert.ok(worker.candidates.every((candidate) => candidate.disabled && candidate.available))
      await assert.rejects(mcp.request('mcp/call', { name: 'session_start', arguments: { profile: 'worker', prompt: 'hold' } }), {
        message: 'Profile worker is disabled',
      })
      assert.equal(x.daemon.sessions.size, 1)
    } finally { await mcp.close(); await client.close() }
  })
}

test('agent disabling removes all its candidates; unknown entries do not affect selection', async (t) => {
  const x = await setup(t, [claude, { ...claude, model: 'opus' }, codex])
  x.config.collab.disabled = ['worker:claude', 'unknown', 'worker:missing', 'worker:codex/not-the-model']
  assert.equal((await x.start()).child.agent, 'codex')
  assert.ok(profiles(x.config).some(([name]) => name === 'worker'))
  const worker = x.daemon.collab.profiles().profiles.find((p) => p.name === 'worker')!
  assert.equal(worker.disabled, false)
  assert.deepEqual(worker.candidates.map((candidate) => candidate.disabled), [true, true, false])
})

test('model disabling compares the full exact string, including provider slashes', async (t) => {
  const x = await setup(t, [pi, { ...pi, model: 'opencode-go/glm-5.3-flash' }, codex])
  x.config.collab.disabled = ['worker:pi/kimi-k3', 'worker:pi/opencode-go/KIMI-K3']
  assert.equal((await x.start()).child.settings.model, 'opencode-go/kimi-k3')
  x.config.collab.disabled.push('worker:pi/opencode-go/kimi-k3')
  const { child } = await x.start()
  assert.equal(child.agent, 'pi'); assert.equal(child.settings.model, 'opencode-go/glm-5.3-flash')
})

test('exact default and colon/slash model entries affect selection without disabling same-agent siblings', async (t) => {
  const model = 'provider/model:version/variant'
  const x = await setup(t, [{ agent: 'codex' }, { ...codex, model }, codex])
  x.config.collab.disabled = ['worker:codex/']
  assert.equal((await x.start()).child.settings.model, model)
  x.config.collab.disabled.push(`worker:codex/${model}`)
  assert.equal((await x.start()).child.settings.model, codex.model)
  x.config.collab.disabled = [`worker:codex/${model}`]
  assert.equal((await x.start()).child.settings.model, undefined)
  x.config.profiles.worker = { agent: 'codex' }
  x.config.collab.disabled = ['worker:codex/']
  assert.ok(!profiles(x.config).some(([name]) => name === 'worker'))
  await assert.rejects(x.start(), /Profile worker is disabled/)
})

test('legacy top-level agent and model form one disableable candidate', async (t) => {
  const x = await setup(t)
  x.config.profiles.worker = { ...claude, candidates: [codex] }
  x.config.collab.disabled = ['worker:claude/sonnet']
  assert.ok(!profiles(x.config).some(([name]) => name === 'worker'))
  const worker = x.daemon.collab.profiles().profiles.find((p) => p.name === 'worker')!
  assert.equal(worker.candidates.length, 1)
  assert.equal(worker.candidates[0].agent, 'claude'); assert.equal(worker.disabled, true)
  await assert.rejects(x.start(), { message: 'Profile worker is disabled' })
})

for (const disabled of ['worker:claude', 'worker:claude/sonnet']) {
  test(`strained fallback never picks disabled candidate ${disabled}`, async (t) => {
    const x = await setup(t, [claude, codex], [
      { agent: 'claude', windows: [{ id: '5h', used: 1 }] },
      { agent: 'codex', windows: [{ id: 'weekly', limited: true }] },
    ])
    x.config.collab.disabled = [disabled]
    assert.equal((await x.start()).child.agent, 'codex')
  })
}

test('collab/profiles wire includes every profile in config order with candidate state and effective thresholds', async (t) => {
  const x = await setup(t, [{ ...claude, effort: 'high' }, codex, { ...pi, model: 'other-provider/other' }, { agent: 'dsh' }], [
    { agent: 'claude', windows: [{ id: '5h', used: 0.92 }] },
  ])
  x.config.collab.disabled = ['worker:claude/sonnet', 'coder']
  x.config.agents.claude.quotaSkip = 0.8
  x.daemon.collab.enabled = ['claude', 'pi', 'dsh']
  const client = await SocketClient.connect(x.daemon.socket)
  try {
    await client.request('hello', { client: 'test', version: '' })
    const result = await client.request('collab/profiles', {})
    assert.deepEqual(Object.keys(result).sort(), ['profiles', 'quotaSkip'])
    assert.equal(result.quotaSkip, 0.9)
    assert.deepEqual(result.profiles.map((p) => p.name), Object.keys(x.config.profiles))
    assert.equal(result.profiles.find((p) => p.name === 'coder')!.disabled, true)
    assert.deepEqual(result.profiles.find((p) => p.name === 'worker'), {
      name: 'worker', cost: 'medium', description: 'Test role', disabled: false, overridden: false,
      candidates: [
        { agent: 'claude', model: 'sonnet', effort: 'high', mode: 'auto', disabled: true, disabledBy: ['worker:claude/sonnet'], available: true, strained: '5h quota 92% used', quotaSkip: 0.8 },
        { agent: 'codex', model: 'gpt-6.1-sol', mode: 'auto', disabled: false, disabledBy: [], available: false, unavailable: 'unavailable here', quotaSkip: 0.9 },
        { agent: 'pi', model: 'other-provider/other', mode: 'auto', disabled: false, disabledBy: [], available: false, unavailable: 'model excluded by agents.pi.models', quotaSkip: 0.9 },
        { agent: 'dsh', model: null, disabled: false, disabledBy: [], available: true, quotaSkip: 0.9 },
      ],
    })
    await client.close()
    x.config.collab.disabled = []
    const { receipt, child } = await x.start()
    assert.equal(child.agent, 'dsh')
    assert.ok(receipt.includes(result.profiles.at(-1)!.candidates[0].strained!))
  } finally { await client.close() }
})
for (const quota of [
  { agent: 'claude', host: 'other-host', windows: [{ id: '5h', used: 1 }] },
  { agent: 'claude', host: null, duplicate: true, windows: [{ id: '5h', used: 1 }] },
  { agent: 'claude', windows: [{ id: '5h', used: 0.89 }], balance: [] },
  { agent: 'claude', windows: [], balance: [{ amount: 0, currency: 'USD' }, { amount: 1, currency: 'CNY' }] },
]) test(`quota does not strain local candidate: ${JSON.stringify(quota)}`, async (t) => {
  const x = await setup(t, [claude, codex], [quota])
  assert.equal((await x.start()).child.agent, 'claude')
})
test('selection reads current quota state and configured threshold on each call', async (t) => {
  const x = await setup(t, [claude, codex], [{ agent: 'claude', host: null, windows: [{ id: '5h', used: 0.85 }] }])
  assert.equal((await x.start()).child.agent, 'claude')
  x.config.collab.quotaSkip = 0.8
  assert.equal((await x.start()).child.agent, 'codex')
  x.daemon.usage.quotas[0].windows[0].used = 0.2
  assert.equal((await x.start()).child.agent, 'claude')
})
test('stale, overage and other-model quota windows do not strain a candidate', async (t) => {
  const future = Date.now() / 1000 + 3600, past = Date.now() / 1000 - 60
  const x = await setup(t, [claude, codex], [{ agent: 'claude', host: null, windows: [
    { id: 'five_hour', used: 0.97, resets: past },
    { id: 'seven_day_overage_included', used: 1, resets: future },
    { id: 'seven_day_fable', used: 0.99, limited: true, resets: future },
    { id: 'seven_day', used: 0.3, resets: future },
  ] }])
  assert.equal((await x.start()).child.agent, 'claude', 'sonnet ignores fable, overage and reset windows')
  x.daemon.usage.quotas[0].windows[3].used = 0.95
  const { receipt, child } = await x.start()
  assert.equal(child.agent, 'codex')
  assert.match(receipt, /Claude sonnet: seven_day quota 95% used/)
})
test('when all available candidates are strained the first available still runs', async (t) => {
  const x = await setup(t, [pi, claude, codex], [
    { agent: 'claude', windows: [{ id: '5h', used: 1 }] },
    { agent: 'codex', windows: [{ id: 'weekly', limited: true }] },
  ], 'claude')
  x.daemon.collab.enabled = ['claude', 'codex']
  x.config.profiles.worker.preferOtherAgent = true
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'claude')
  assert.match(receipt, /Pi opencode-go\/kimi-k3: unavailable here/)
  assert.doesNotMatch(receipt, /Claude sonnet:|Codex gpt/)
})
for (const [caller, agent, model] of [['codex', 'claude', 'opus'], ['claude', 'codex', 'gpt-6-astra']]) {
  test(`reviewer prefers a different agent for a ${caller} caller`, async (t) => {
    const x = await setup(t, undefined, [], caller)
    const { child, receipt } = await x.start('reviewer')
    assert.equal(child.agent, agent); assert.equal(child.settings.model, model)
    assert.equal(child.info.profile, 'reviewer'); assert.equal(child.settings.mode, 'plan')
    if (caller === 'codex') assert.match(receipt, /Codex gpt-6-astra: same agent as caller; preferring another vendor/)
    else assert.doesNotMatch(receipt, /Skipped candidates/)
  })
}
test('another agent preference never outranks quota health', async (t) => {
  const x = await setup(t, undefined, [
    { agent: 'claude', windows: [{ id: '5h', used: 1 }] },
    { agent: 'pi', windows: [{ id: 'weekly', used: 1 }] },
  ], 'codex')
  assert.equal((await x.start('reviewer')).child.agent, 'codex')
})
test('receipt explains unavailable, strained and exhausted candidates in order with configurable prompts', async (t) => {
  const x = await setup(t, [claude, { agent: 'dsh' }, codex, pi], [
    { agent: 'claude', windows: [{ id: '5h', used: 0.93 }] },
    { agent: 'dsh', windows: [], balance: [{ amount: 0, currency: 'USD' }] },
  ])
  x.daemon.collab.enabled = ['claude', 'dsh', 'pi']
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'pi')
  assert.match(receipt, /Skipped candidates: Claude sonnet: 5h quota 93% used; DeepSeek: balance exhausted; Codex gpt-6.1-sol: unavailable here\./)
  Object.assign(x.config.collab.prompts, { candidateSkipped: '[%s -> %s]', candidatesSkipped: ' CHOICES %s',
    candidateQuotaUsed: 'WINDOW %s %s', candidateBalanceExhausted: 'EMPTY', candidateUnavailable: 'MISSING' })
  assert.match((await x.start()).receipt, /CHOICES \[Claude sonnet -> WINDOW 5h 93\]; \[DeepSeek -> EMPTY\]; \[Codex gpt-6.1-sol -> MISSING\]/)
})
test('a configured role with no candidate available reports every candidate and reason', async (t) => {
  const x = await setup(t, [claude, { ...pi, model: 'other-provider/other' }, codex])
  x.daemon.collab.enabled = ['pi']
  await assert.rejects(x.start(), { message: 'No candidate available for profile worker: Claude sonnet: unavailable here; Pi other-provider/other: model excluded by agents.pi.models; Codex gpt-6.1-sol: unavailable here' })
  assert.equal(x.daemon.sessions.size, 1)
})
test('role confirmation applies after a fallback candidate is selected', async (t) => {
  const x = await setup(t, [claude, codex])
  x.config.profiles.worker.confirm = true
  x.daemon.collab.enabled = ['codex']
  const starting = x.start()
  assert.equal(x.parent.asks.size, 1)
  x.parent.answer([...x.parent.asks.keys()][0], { choice: 'deny' })
  await assert.rejects(starting, /user declined/)
  assert.equal(x.daemon.sessions.size, 1)
})
