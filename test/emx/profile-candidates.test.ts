import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DaemonServer } from '../../emx/daemon/server.ts'
import { Session } from '../../emx/daemon/session.ts'
import { definitions, profileCandidates, profiles } from '../../emx/daemon/collab.ts'
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
  // These tests mutate effective policy directly; file watching is tested elsewhere.
  daemon.configuration.close()
  const parent = new Session({ id: 'parent', agent: caller, root: dir, settings: { mode: 'auto' }, info: { handle: 'parent' } })
  parent.setStatus('running'); daemon.sessions.set(parent.id, parent)
  const start = async (profile = 'worker') => {
    const receipt = String(await daemon.collab.call(parent, 'session_start', { profile, prompt: 'hold' }, signal()))
    const child = [...daemon.sessions.values()].filter((s) => s.info.parent === parent.id).at(-1)!
    return { receipt, child }
  }
  return { dir, daemon, config: daemon.configuration.value, parent, start }
}

test('roles are listed while any agent is available, independently of quotas, caller or Pi filter', () => {
  const c = defaults(), env = { PATH: '', EMX_CODEX_EXECUTABLE: process.execPath }
  assert.equal(profiles(c, ['codex'], env).length, 7)
  assert.deepEqual(profiles(c, [], env), [])
  assert.deepEqual(profiles(c, ['claude'], env), [])
  c.profiles.onlyPi = { candidates: [{ agent: 'pi', model: 'other-provider/other' }] }
  const piEnv = { PATH: '', EMX_PI_EXECUTABLE: process.execPath }
  assert.ok(profiles(c, ['pi'], piEnv).some(([name]) => name === 'onlyPi'))
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
  const before = definitions(x.config)
  const { child, receipt } = await x.start()
  assert.equal(child.agent, 'codex'); assert.ok(receipt.includes(`Claude sonnet: ${reason}`))
  assert.deepEqual(definitions(x.config), before)
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
