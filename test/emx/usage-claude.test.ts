import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import {mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, mkdirSync, symlinkSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {test} from 'node:test'
import type {TestContext} from 'node:test'
import type {Config} from '../../emx/config.ts'
import {UsageService} from '../../emx/usage/service.ts'
import {Collaboration} from '../../emx/daemon/collab.ts'
import {Session} from '../../emx/daemon/session.ts'
import {emxRoot} from '../../emx/daemon/paths.ts'

// This test file runs in its own process; inherited auth must not select a route.
for (const key of ['ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
  'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
  'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN']) delete process.env[key]

const NOW = Date.now() / 1000
const subscriber = {loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty', subscriptionType: 'max'}
const signedOut = {loggedIn: false, authMethod: 'none', apiProvider: 'firstParty'}
const usage = (used = 0) => ({result: `Current session: ${used}% used`})

function setup(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), 'emx-claude-quota-'))
  const file = join(dir, 'peer.json')
  const command = [process.execPath, new URL('./fixtures/claude-quota.mjs', import.meta.url).pathname, file]
  const calls = (): string[][] => existsSync(file + '.calls')
    ? readFileSync(file + '.calls', 'utf8').trim().split('\n').map((line) => JSON.parse(line)) : []
  const logs: string[] = []
  const messages: any[] = []
  let now = NOW
  const service = new UsageService({now: () => now, log: (m) => logs.push(m), send: (m) => messages.push(m)})
  service.initialize({usageFile: join(dir, 'usage.jsonl'), quotaFile: join(dir, 'quota.json'),
    pollInterval: 0, agents: ['claude'], pollers: {claude: {command}}})
  service.pollInterval = 900
  const config: Config = JSON.parse(readFileSync(join(emxRoot, 'config.json'), 'utf8'))
  config.collab.handleCommand = []; config.collab.agentHandleCommands = {}; config.collab.confirm = false
  config.agents.claude.executable = process.execPath
  config.agents.echo = {title: 'Echo', executable: process.execPath}
  config.profiles = {probe: {candidates: [{agent: 'claude', model: 'opus'}, {agent: 'echo'}]},
    only: {agent: 'claude'}}
  const sessions = new Map<string, Session>()
  const chosen: string[] = []
  let environment = process.env
  const create = (agent: string, root: string, settings: any, info: any) => {
    chosen.push(agent)
    // Exercise real selection/start while every child runs the fake echo backend.
    const session = new Session({id: 's-' + sessions.size, agent: 'echo', root, settings, info})
    sessions.set(session.id, session)
    return session
  }
  const parent = create('echo', dir, {mode: 'full'}, {handle: 'parent'})
  chosen.length = 0
  const collab = new Collaboration({sessions, varDir: dir, config: () => config, usage: service, create,
    environment: () => environment,
    close: async (s) => {await s.stop(); sessions.delete(s.id)},
    view: async () => {}, visible: async () => true, changed: () => {}})
  t.after(async () => {collab.stop(); service.stop(); for (const s of sessions.values()) await s.stop()
    rmSync(dir, {recursive: true, force: true})})
  const state = (auth: any, quota?: any, authCode = 0, quotaCode = 0) =>
    writeFileSync(file, JSON.stringify({auth: {out: auth, code: authCode}, usage: {out: quota, code: quotaCode}}))
  const candidate = () => collab.profiles([], dir).profiles[0].candidates[0]
  const start = (profile = 'probe') => collab.call(parent, 'session_start', {profile, prompt: 'test'}, new AbortController().signal)
  return {dir, file, command, service, logs, messages, calls, config, collab, candidate, start, state, chosen,
    setEnvironment: (env: NodeJS.ProcessEnv) => {environment = env},
    advance: (seconds: number) => {now += seconds}}
}

test('signed-out status with exit 1 excludes every Claude candidate and actual selection', async (t) => {
  const x = setup(t)
  x.state({...signedOut, email: 'private@example.invalid'}, undefined, 1)
  await x.service.pollAll(true)
  assert.deepEqual(x.calls(), [['auth', 'status', '--json']], 'no /usage while signed out')
  for (const profile of x.collab.profiles().profiles) {
    const c = profile.candidates[0]
    assert.equal(c.available, false)
    assert.equal(c.availability?.reason, 'unauthenticated')
    assert.match(c.unavailable!, /not logged in/)
  }
  const count = x.calls().length
  await x.start()
  assert.deepEqual(x.chosen, ['echo'])
  await assert.rejects(x.start('only'), /not logged in/)
  assert.equal(x.calls().length, count, 'catalog and selection only read cached evidence')
  assert.ok(!readFileSync(x.service.quotaFile, 'utf8').includes('private@'))
})

test('zero and exhausted quota both prove an account; exhaustion remains a soft quota preference', async (t) => {
  const x = setup(t)
  for (const used of [0, 100]) {
    x.state(subscriber, usage(used))
    await x.service.pollAll(true)
    const c = x.candidate()
    assert.equal(c.available, true)
    assert.equal(c.availability?.state, 'available')
    assert.equal(Boolean(c.strained), used === 100)
    await x.start()
    assert.equal(x.chosen.at(-1), used === 100 ? 'echo' : 'claude')
  }
})

test('explicit unsupported subscription differs from a missing quota or a network failure', async (t) => {
  const x = setup(t)
  for (const body of [{error: {type: 'unsupported_subscription'}},
    {result: 'Usage is only available for subscription plans.', is_error: true}]) {
    x.state(subscriber, body, 0, 1)
    await x.service.pollAll(true)
    assert.equal(x.candidate().available, false)
    assert.equal(x.candidate().availability?.reason, 'unsupported-subscription')
    await x.start()
    assert.equal(x.chosen.at(-1), 'echo')
  }
  for (const body of [{result: 'network unavailable'}, {}, {error: {type: 'permission_error', message: 'HTTP 403'}},
    {result: 'API Error: HTTP 401'}, 'malformed private-response']) {
    x.state(subscriber, body)
    await x.service.pollAll(true)
    assert.equal(x.candidate().available, true, 'unknown is not confirmed unavailable')
    assert.equal(x.candidate().availability?.state, 'unknown')
    assert.equal(x.candidate().availability?.reason, 'probe-failed')
    assert.ok(x.service.retryAt.claude > NOW)
  }
  assert.ok(x.logs.every((line) => line === 'polling claude failed: Claude usage unavailable'))
  assert.ok(!JSON.stringify(x.messages).includes('private-response'))
})

test('successful general auth alone never claims a verified subscription; legacy auth can fall back to quota', async (t) => {
  const x = setup(t)
  for (const auth of [{loggedIn: true}, {...subscriber, subscriptionType: null}]) {
    x.state(auth, {result: 'no usage'})
    await x.service.pollAll(true)
    assert.equal(x.candidate().availability?.state, 'unknown')
  }
  // Cached plan metadata must not override valid quota, including trial access.
  x.state({...subscriber, subscriptionType: 'free'}, usage(0))
  await x.service.pollAll(true)
  assert.equal(x.candidate().availability?.state, 'available')
  x.state('unknown command auth', usage(0), 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().availability?.state, 'available')
  x.state('unknown command auth', {result: 'Usage is only available for subscription plans.'}, 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().availability?.state, 'unknown', 'unsupported quota cannot exclude an unknown API route')
  x.state('unknown command auth', {error: {type: 'authentication_error'}}, 1, 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().availability?.reason, 'unauthenticated')
})

test('logout invalidates old successful quota and forced refresh recovers after login', async (t) => {
  const x = setup(t)
  x.state(subscriber, usage(100))
  await x.service.pollAll(true)
  assert.ok(x.candidate().strained)
  x.service.quota({agent: 'claude', plan: 'max', credits: 10, balance: [{amount: 1, currency: 'USD'}]})
  x.state(signedOut, undefined, 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().available, false)
  assert.deepEqual(x.service.loadQuotas()[0].windows, [], 'old account windows are removed')
  for (const key of ['plan', 'credits', 'balance']) assert.equal(x.service.quotas[0][key], undefined)
  assert.equal(x.candidate().strained, undefined)
  x.state(subscriber, usage(0))
  await x.service.pollAll(false)
  assert.equal(x.candidate().available, false, 'normal polling honors cadence')
  x.service.refresh({force: true})
  // refresh is intentionally asynchronous, just like the existing usage UI.
  while (x.service.busy.size) await new Promise((resolve) => setTimeout(resolve, 10))
  assert.equal(x.candidate().available, true)
  assert.equal(x.candidate().availability?.state, 'available')
  assert.equal(x.candidate().strained, undefined)
  assert.equal(existsSync(x.service.usageFile), false, 'status/quota probes record no model usage')
})

test('network errors replace stale success with unknown and use existing backoff', async (t) => {
  const x = setup(t)
  x.state(subscriber, usage(100))
  await x.service.pollAll(true)
  x.state(subscriber, 'invalid JSON containing private-response')
  await x.service.pollAll(true)
  assert.equal(x.candidate().availability?.state, 'unknown')
  assert.equal(x.candidate().strained, undefined, 'historical quota cannot decide current availability')
  const count = x.calls().length
  await x.service.pollAll(false)
  assert.equal(x.calls().length, count)
  x.advance(1900)
  x.state(subscriber, usage(0))
  await x.service.pollAll(false)
  assert.equal(x.candidate().availability?.state, 'available')
  assert.equal(x.service.failures.claude, 0)
})

test('API key and custom providers remain selectable without claiming subscription quota', async (t) => {
  const x = setup(t)
  for (const auth of [{loggedIn: true, authMethod: 'api_key', apiProvider: 'firstParty'},
    {...signedOut, apiProvider: 'bedrock'}, {...signedOut, apiProvider: 'gateway'}]) {
    x.state(auth)
    const count = x.calls().length
    await x.service.pollAll(true)
    assert.equal(x.calls().length, count + 1, 'external routes never invoke /usage')
    assert.equal(x.candidate().available, true)
    assert.equal(x.candidate().availability?.state, 'external')
    await x.start()
    assert.equal(x.chosen.at(-1), 'claude')
  }
  x.state(signedOut, undefined, 1)
  await x.service.pollAll(true)
  const status = (env: NodeJS.ProcessEnv) => x.service.candidateAvailability('claude', process.execPath, env)!
  assert.equal(status({...process.env, ANTHROPIC_API_KEY: 'fake'}).state, 'external')
  assert.equal(status({...process.env, ANTHROPIC_AUTH_TOKEN: 'fake'}).state, 'external')
  assert.equal(status({...process.env, ANTHROPIC_BASE_URL: 'https://example.invalid'}).state, 'external')
  assert.equal(status({...process.env, CLAUDE_CODE_USE_VERTEX: '1'}).state, 'external')
  assert.equal(status({...process.env, CLAUDE_CONFIG_DIR: '/different'}).reason, 'different-environment')
  assert.equal(status({...process.env, CLAUDE_CODE_OAUTH_TOKEN: 'fake'}).state, 'unknown')
  assert.equal(x.service.candidateAvailability('claude', '/other/claude')?.state, 'unknown')
  x.setEnvironment({...process.env, ANTHROPIC_BASE_URL: 'https://example.invalid'})
  assert.equal(x.candidate().available, true, 'host logout does not exclude a project custom route')
  assert.equal(x.candidate().availability?.state, 'external')
  await x.start()
  assert.equal(x.chosen.at(-1), 'claude')
})

test('a restarted service checks auth even when the disk cache contains fresh successful quota', async (t) => {
  const x = setup(t)
  x.state(subscriber, usage(0))
  await x.service.pollAll(true)
  assert.equal(JSON.parse(readFileSync(x.service.quotaFile, 'utf8'))[0].availability, undefined)
  x.service.stop()
  const restarted = new UsageService({log: () => {}})
  t.after(() => restarted.stop())
  restarted.initialize({usageFile: x.service.usageFile, quotaFile: x.service.quotaFile, pollInterval: 0,
    pollers: {claude: {command: x.command}}})
  assert.equal(restarted.candidateAvailability('claude', process.execPath)?.state, 'unknown')
  x.state(signedOut, undefined, 1)
  restarted.pollInterval = 900
  await restarted.pollAll(false)
  assert.equal(restarted.candidateAvailability('claude', process.execPath)?.reason, 'unauthenticated')
  assert.deepEqual(restarted.quotas[0].windows, [])
})

test('changing the quota command invalidates account evidence and rechecks even a fresh cache', async (t) => {
  const x = setup(t)
  x.state(signedOut, undefined, 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().available, false)
  const other = join(x.dir, 'other-peer.json')
  writeFileSync(other, JSON.stringify({auth: {out: subscriber}, usage: {out: usage(0)}}))
  x.service.configure({pollInterval: 0, pollers: {claude: {command: [...x.command.slice(0, -1), other]}}})
  assert.equal(x.candidate().availability?.state, 'unknown')
  x.service.pollInterval = 900
  await x.service.pollAll(false)
  assert.equal(x.candidate().availability?.state, 'available')
})

test('a stopped failed probe cannot publish new unknown evidence or retry state', async (t) => {
  const x = setup(t)
  let fail!: (err: Error) => void
  x.service.fetchers.claude = () => new Promise((_resolve, reject) => {fail = reject})
  const pending = x.service.pollAll(true)
  x.service.stop()
  fail(new Error('fake failure'))
  await pending
  assert.deepEqual(x.messages, [])
  assert.deepEqual(x.logs, [])
  assert.equal(x.service.retryAt.claude, undefined)
  assert.equal(x.candidate().availability?.state, 'unknown')
})

test('project PATH resolves a different Claude wrapper without inheriting host logout', async (t) => {
  const x = setup(t)
  const host = join(x.dir, 'host-bin')
  const project = join(x.dir, 'project-bin')
  mkdirSync(host); mkdirSync(project)
  const peer = readFileSync(x.command[1], 'utf8').replace(/^#!.*\n/, '')
  for (const dir of [host, project]) {
    writeFileSync(join(dir, 'claude'), `#!${process.execPath}\n${peer}`, {mode: 0o700})
  }
  const alias = join(project, 'host-claude')
  symlinkSync(join(host, 'claude'), alias)
  const previousPath = process.env.PATH
  t.after(() => {
    if (previousPath === undefined) delete process.env.PATH
    else process.env.PATH = previousPath
  })
  process.env.PATH = host
  x.config.agents.claude.executable = 'claude'
  x.service.configure({pollInterval: 0, pollers: {claude: {command: ['claude', x.file]}}})
  x.service.pollInterval = 900
  x.state(signedOut, undefined, 1)
  await x.service.pollAll(true)
  assert.equal(x.candidate().available, false)
  const status = (executable: string, env: NodeJS.ProcessEnv) =>
    x.service.candidateAvailability('claude', executable, env)!
  assert.equal(status('claude', {...process.env, PATH: host + ':' + project}).state, 'unavailable',
    'a PATH change that still resolves the same file retains evidence')
  assert.equal(status(alias, {...process.env, PATH: project}).state, 'unavailable',
    'an absolute symlink to the probed installation retains evidence')
  assert.equal(status(join(host, 'claude'), {...process.env, PATH: project}).state, 'unavailable',
    'an absolute installation is independent of PATH')
  assert.equal(status(alias, {...process.env, HOME: join(x.dir, 'other-home')}).reason, 'different-environment')
  x.setEnvironment({...process.env, PATH: project})
  assert.equal(x.candidate().available, true)
  assert.equal(x.candidate().availability?.state, 'unknown')
  await x.start()
  assert.equal(x.chosen.at(-1), 'claude')
  assert.equal(x.calls().length, 1, 'catalog and selection never probe project wrappers')
  process.env.PATH = project
  assert.equal(status('claude', process.env).state, 'unknown',
    'changing the host PATH cannot relabel already cached evidence')
  x.config.agents.claude.executable = alias
  assert.equal(x.candidate().available, false)
  for (const executable of [join(host, 'claude'), alias]) {
    x.service.configure({pollInterval: 0, pollers: {claude: {command: [executable, x.file]}}})
    x.service.pollInterval = 900
    await x.service.pollAll(true)
    assert.equal(status(join(host, 'claude'), process.env).state, 'unavailable',
      'absolute and symlink poller commands share their resolved installation')
    assert.equal(status('claude', process.env).state, 'unknown',
      'a configured absolute poller cannot exclude a different PATH installation')
  }
})

test('cached auth evidence cannot cross a changed host account environment', async (t) => {
  const x = setup(t)
  x.state(signedOut, undefined, 1)
  await x.service.pollAll(true)
  const original = process.env.CLAUDE_CONFIG_DIR
  t.after(() => {
    if (original === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = original
  })
  process.env.CLAUDE_CONFIG_DIR = join(x.dir, 'new-account')
  assert.equal(x.candidate().available, true)
  assert.equal(x.candidate().availability?.reason, 'different-environment')
})

test('stopping during delayed auth settles the child without spawning quota', {timeout: 5000}, async (t) => {
  const x = setup(t)
  writeFileSync(x.file, JSON.stringify({
    auth: {out: subscriber, delay: 30000}, usage: {out: usage(0)},
  }))
  const pending = x.service.pollAll(true)
  const deadline = Date.now() + 2000
  while (!x.calls().length && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10))
  assert.deepEqual(x.calls(), [['auth', 'status', '--json']], 'auth child has started')
  assert.ok(x.service.busy.has('claude'))
  x.service.stop()
  await pending
  assert.deepEqual(x.calls(), [['auth', 'status', '--json']], 'no post-stop /usage child')
  assert.equal(x.service.busy.size, 0)
  assert.deepEqual(x.messages, [])
  assert.deepEqual(x.logs, [])
  assert.equal(x.service.retryAt.claude, undefined)
  assert.equal(existsSync(x.service.quotaFile), false)
  assert.equal(x.candidate().availability?.state, 'unknown')
})
