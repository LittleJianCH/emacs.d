import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { UsageService } from '../../emx/usage/service.ts'
import { PI_USAGE, piUsageServer } from './fixtures/pi-usage.ts'

const command = [process.execPath, new URL('./fixtures/usage-poller.mjs', import.meta.url).pathname, 'pi']
const NOW = Date.parse('2026-10-21T04:00:00.000Z') / 1000
const key = 'fake-go-key'

function serviceFor(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), 'emx-pi-quota-'))
  const messages: unknown[] = []
  const logs: string[] = []
  const service = new UsageService({now: () => NOW, send: (m) => messages.push(m), log: (m) => logs.push(m)})
  service.initialize({usageFile: join(dir, 'usage.jsonl'), quotaFile: join(dir, 'quota.json'), agents: ['pi'],
    pollInterval: 0, pollers: {pi: {command}}})
  // Poll explicitly so each test can inspect the completed attempt.
  service.pollInterval = 900
  t.after(() => { service.stop(); rmSync(dir, {recursive: true, force: true}) })
  return {service, logs, messages}
}

test('Pi auth uses the fake CLI, trims the key and maps all Go windows', async (t) => {
  const {requests} = await piUsageServer(t)
  const {service} = serviceFor(t)
  const reading = await service.fetchers.pi(command, {spawn, now: () => NOW})
  assert.deepEqual(requests, [{method: 'GET', url: '/zen/go/v1/usage', authorization: `Bearer ${key}`}])
  assert.deepEqual(reading, {agent: 'pi', host: null, plan: 'OpenCode Go', windows: [
    {id: '300', label: '5h', minutes: 300, used: 0, resets: 1792584336, limited: false},
    {id: '10080', label: '周', minutes: 10080, used: 0, resets: 1792972800, limited: false},
    {id: 'monthly', label: '月', minutes: null, used: 0, resets: 1795197776, limited: false},
  ]})
  service.quota(reading)
  assert.ok(!readFileSync(service.quotaFile, 'utf8').includes(key))
})

test('Pi keeps percent for non-ok states and forecasts only fixed durations', async (t) => {
  const {response} = await piUsageServer(t)
  const {service} = serviceFor(t)
  const reading = await service.fetchers.pi(command, {spawn, now: () => NOW})
  service.quota({...reading, time: NOW - 43200})
  const body = structuredClone(PI_USAGE)
  body.usage.rolling.percent = 25
  body.usage.weekly.percent = 42
  body.usage.monthly.percent = 100
  body.usage.weekly.status = 'unknown-limit'
  response.body = body
  await service.pollAll(true)
  const windows = service.report({range: 'all', now: NOW}).quotas[0].windows
  assert.deepEqual(windows.map((w: any) => [w.used, w.limited]), [[0.25, false], [0.42, true], [1, false]])
  for (const w of windows.slice(0, 2)) assert.ok(w.forecast)
  assert.equal(windows[2].forecast, null)
  assert.equal(windows[2].wait, null)
})

test('Pi HTTP and malformed responses fail safely and use existing backoff', async (t) => {
  const {response, requests} = await piUsageServer(t)
  const {service, logs, messages} = serviceFor(t)
  for (const [status, body] of [
    [401, `Bearer ${key}`], [200, `invalid JSON ${key}`], [200, {error: key}],
    [200, null], [200, {usage: {...PI_USAGE.usage, rolling: {...PI_USAGE.usage.rolling, percent: 101}}}],
    [200, {usage: {...PI_USAGE.usage, weekly: {...PI_USAGE.usage.weekly, resetsAt: key}}}],
  ] as const) {
    response.status = status
    response.body = body
    await service.pollAll(true)
    assert.ok(service.failures.pi > 0)
    assert.ok(service.retryAt.pi > NOW)
    assert.deepEqual(service.loadQuotas(), [])
    assert.deepEqual(messages, [], 'failures never push UI errors or quota entries')
    const before = requests.length
    await service.pollAll(false)
    assert.equal(requests.length, before, 'ordinary polls honor backoff')
    assert.ok(!logs.join('\n').includes(key))
  }
  assert.match(logs[0], /Pi usage HTTP 401$/)
  assert.ok(logs.slice(1).every((log) => log.endsWith('Invalid Pi usage response')))
  response.status = 200
  response.body = PI_USAGE
  await service.pollAll(true)
  assert.equal(service.failures.pi, 0)
  assert.equal(service.retryAt.pi, 0)
  assert.equal(service.loadQuotas()[0].agent, 'pi')
})

test('missing or failing Pi auth never requests HTTP or exposes CLI output', async (t) => {
  const {requests} = await piUsageServer(t)
  const {service, logs, messages} = serviceFor(t)
  for (const auth of [
    ['/does-not-exist/pi'],
    [process.execPath, '-e', `process.stdout.write('${key}'); process.stderr.write('${key}'); process.exit(1)`],
    [process.execPath, '-e', 'process.stdout.write(" \\n")'],
  ]) {
    // Node needs -- before the fetcher's auth arguments when using -e.
    service.pollers.pi.command = auth[0] === process.execPath ? [...auth, '--'] : auth
    await service.pollAll(true)
    const failures = service.failures.pi
    await service.pollAll(false)
    assert.equal(service.failures.pi, failures)
  }
  assert.equal(requests.length, 0)
  assert.deepEqual(messages, [])
  assert.ok(logs.every((log) => log === 'polling pi failed: Pi API key unavailable'))
})
