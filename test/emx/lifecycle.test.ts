import './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { Session } from '../../emx/daemon/session.ts'
import { backends } from '../../emx/backends/backend.ts'
import type { SessionHost } from '../../emx/backends/backend.ts'

function barrier() {
  let release!: () => void
  const promise = new Promise<void>((resolve) => { release = resolve })
  return { promise, release }
}

// All lifecycle calls go through Session: adapters are not a public scheduler.
for (const agent of ['claude', 'codex', 'dsh']) test(`${agent}: starts and stop are serialized through environment resolution`, async () => {
  const dir = mkdtempSync('/tmp/emx-lifecycle-'), saved = { ...process.env }
  const log = join(dir, 'calls.jsonl'), gate = barrier(), entered = barrier()
  process.env['EMX_' + agent.toUpperCase() + '_LOG'] = log
  process.env.HOME = dir
  process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
  let lookups = 0
  const session = new Session({ id: 'test', agent, root: dir, environment: async () => {
    lookups++; entered.release(); await gate.promise; return { ...process.env }
  } })
  try {
    const first = session.start()
    await entered.promise
    const second = session.start(), stopping = session.stop(), late = session.start()
    gate.release()
    await Promise.all([first, second, stopping, late])
    const calls = readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
    assert.equal(calls.filter((m) => agent === 'claude' ? m.type === 'spawn' : m.method === 'initialize').length, 1)
    assert.equal(lookups, 1)
    assert.equal(session.backend.alive(), false)
    assert.equal(session.status, 'exited')
  } finally {
    gate.release(); await session.stop()
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]
    Object.assign(process.env, saved)
    rmSync(dir, { recursive: true, force: true })
  }
})

test('echo stop followed immediately by start cannot leave a live exited backend', async () => {
  const session = new Session({ id: 'echo', agent: 'echo', root: '' })
  await session.start()
  await Promise.all([session.stop(), session.start()])
  assert.equal(session.status, 'exited')
  assert.equal(session.backend.alive(), false)
})

type Operation = 'start' | 'stop' | 'restart' | 'hibernate' | 'configure'
function permutations<T>(items: T[]): T[][] {
  return items.length ? items.flatMap((item, i) => permutations(items.filter((_, j) => i !== j)).map((tail) => [item, ...tail])) : [[]]
}

// Pause each await in start/restart/hibernate/configuration and submit every
// ordering of competing operations through the public Session methods.
for (const [initial, points] of [
  ['start', ['environment', 'start', 'configure']],
  ['send', ['environment', 'start', 'configure', 'prepare', 'send']],
  ['restart', ['stop', 'environment', 'start', 'configure']],
  ['hibernate', ['stop']],
  ['stop', ['stop']],
  ['configure', ['configure', 'stop', 'start']],
] as const) for (const point of points) test(`${initial} at ${point}: all competing lifecycle orders`, async () => {
  for (const order of permutations<Operation>(['stop', 'start', 'restart', 'hibernate', 'configure'])) {
    const gate = barrier(), entered = barrier()
    let armed = false, blocked = false, live = false, active = 0, maximum = 0
    const calls: string[] = []
    const wait = async (name: string) => {
      calls.push(name)
      maximum = Math.max(maximum, ++active)
      if (armed && !blocked && name === point) { blocked = true; entered.release(); await gate.promise }
      active--
    }
    let host!: SessionHost
    const start = async () => { await wait('start'); live = true; host.setStatus('idle') }
    const stop = async () => { await wait('stop'); live = false }
    backends.lifecycleFixture = (h) => {
      host = h
      return { start, stop, alive: () => live, resumeId: () => undefined,
        prepare: () => wait('prepare'),
        send: async () => { await wait('send'); host.setStatus('idle') },
        steer: () => false, interrupt: () => {},
        configure: async (settings) => {
          await wait('configure')
          if (settings.effort === 'restart') { await stop(); await start() }
        } }
    }
    const session = new Session({ id: 'interleave', agent: 'lifecycleFixture', root: '',
      environment: async () => { await wait('environment'); return {} } })
    const run = (op: Operation | 'send') => {
      if (op === 'send') { session.send('fixture'); return Promise.resolve() }
      return op === 'configure' ? session.configure({ effort: 'restart' }) : session[op]()
    }
    try {
      if (initial !== 'start' && initial !== 'send') await session.start()
      armed = true
      const first = run(initial)
      await entered.promise
      const rest = order.map(run)
      // No competing operation may enter the paused operation's await.
      assert.equal(active, 1)
      gate.release()
      await Promise.all([first, ...rest])
      assert.equal(maximum, 1, `${initial}/${point}/${order}`)
      assert.equal(session.status, 'exited')
      assert.equal(live, false)
      const end = calls.length
      await Promise.all([session.start(), session.restart(), session.hibernate(), session.configure({ effort: 'restart' })])
      assert.equal(calls.length, end, 'terminal sessions never acquire a new process')
    } finally { gate.release(); await session.stop(); delete backends.lifecycleFixture }
  }
})

test('a rejected operation releases the queue and hibernate rechecks busy state on entry', async () => {
  const session = new Session({ id: 'failure', agent: 'echo', root: '' })
  await session.start()
  const configuration = session.configure({})
  const hibernation = session.hibernate()
  session.setStatus('running')
  await Promise.all([configuration, hibernation])
  assert.equal(session.backend.alive(), true)
  session.setStatus('idle')
  const original = session.backend.configure
  session.backend.configure = () => { throw new Error('bad configure') }
  await assert.rejects(session.configure({}), /bad configure/)
  session.backend.configure = original
  await session.stop()
  assert.equal(session.backend.alive(), false)
})

test('interrupt during preparation cancels an ask created by submission', async () => {
  const gate = barrier(), entered = barrier()
  const session = new Session({ id: 'preparing-ask', agent: 'echo', root: '',
    environment: async () => { entered.release(); await gate.promise; return {} } })
  try {
    session.send('ask before startup')
    await entered.promise
    session.interrupt()
    gate.release()
    await new Promise((resolve) => setImmediate(resolve))
    assert.equal(session.asks.size, 0)
    assert.equal(session.status, 'idle')
    assert.equal(session.blocks.filter((b) => b.type === 'text').at(-1)?.text, 'cancelled')
  } finally { gate.release(); await session.stop() }
})
