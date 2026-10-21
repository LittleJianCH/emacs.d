// lock.test.ts --- stale locks, ownership and cross-process exclusion.

import * as assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { acquireLock } from '../../emx/daemon/lock.ts'

function state(t: TestContext): string {
  const dir = fs.mkdtempSync(join(tmpdir(), 'emx-lock-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return dir
}

function deadPid(): number {
  const child = spawnSync(process.execPath, ['-e', ''], { timeout: 2000 })
  assert.equal(child.status, 0)
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' })
  return child.pid
}

test('a dead owner is reclaimed and a live owner is refused', async (t) => {
  const dir = state(t)
  const file = join(dir, 'daemon.lock')
  fs.writeFileSync(file, JSON.stringify({ pid: deadPid(), started: 0 }))
  const release = await acquireLock(dir)
  t.after(release)
  const owner = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(owner.pid, process.pid)
  assert.ok(owner.started > 0)
  await assert.rejects(acquireLock(dir), /Another daemon owns this state directory/)
  release()
  assert.equal(fs.existsSync(file), false)
  assert.deepEqual(fs.readdirSync(dir), [])
})

for (const content of ['', 'garbage', '{"pid":9007199254740991}', 'null']) {
  test(`an invalid lock is reclaimed: ${JSON.stringify(content)}`, async (t) => {
    const dir = state(t)
    fs.writeFileSync(join(dir, 'daemon.lock'), content)
    const release = await acquireLock(dir)
    release()
    assert.deepEqual(fs.readdirSync(dir), [])
  })
}

test('a crashed reclaimer older than ten seconds does not block acquisition', async (t) => {
  const dir = state(t)
  fs.writeFileSync(join(dir, 'daemon.lock'), '')
  const reclaim = join(dir, 'daemon.lock.reclaim')
  fs.mkdirSync(reclaim)
  const old = new Date(Date.now() - 11_000)
  fs.utimesSync(reclaim, old, old)
  const release = await acquireLock(dir)
  release()
  assert.deepEqual(fs.readdirSync(dir), [])
})

test('a busy reclaim mutex retries, then times out without deleting it', async (t) => {
  const dir = state(t)
  fs.writeFileSync(join(dir, 'daemon.lock'), '')
  fs.mkdirSync(join(dir, 'daemon.lock.reclaim'))
  const started = Date.now()
  await assert.rejects(acquireLock(dir), /Timed out reclaiming daemon lock/)
  assert.ok(Date.now() - started >= 1900)
  assert.deepEqual(fs.readdirSync(dir).sort(), ['daemon.lock', 'daemon.lock.reclaim'])
})

test('release leaves a replacement owner intact', async (t) => {
  const dir = state(t)
  const release = await acquireLock(dir)
  const file = join(dir, 'daemon.lock')
  const replacement = JSON.stringify({ pid: deadPid(), started: 1 })
  fs.writeFileSync(file, replacement)
  release()
  assert.equal(fs.readFileSync(file, 'utf8'), replacement)
})

test('eight concurrent processes reclaim and acquire without overlapping holders', async (t) => {
  const dir = state(t)
  // All contenders initially see the same stale lock.
  fs.writeFileSync(join(dir, 'daemon.lock'), JSON.stringify({ pid: deadPid(), started: 0 }))
  const module = new URL('../../emx/daemon/lock.ts', import.meta.url).href
  const script = `
    import { acquireLock } from ${JSON.stringify(module)}
    import { writeFileSync, unlinkSync, readFileSync } from 'node:fs'
    import { join } from 'node:path'
    import { setTimeout as delay } from 'node:timers/promises'
    import assert from 'node:assert/strict'
    const dir = process.argv[1]
    const go = new Promise(resolve => process.once('message', resolve))
    process.send('ready')
    await go
    for (let round = 0; round < 4; round++) {
      let release
      const deadline = Date.now() + 10000
      while (!release) {
        try { release = await acquireLock(dir) } catch (error) {
          if (!/Another daemon owns/.test(String(error)) || Date.now() > deadline) throw error
          await delay(5)
        }
      }
      assert.equal(JSON.parse(readFileSync(join(dir, 'daemon.lock'), 'utf8')).pid, process.pid)
      // Exclusive creation independently detects two simultaneous lock holders.
      const critical = join(dir, 'critical')
      writeFileSync(critical, String(process.pid), { flag: 'wx' })
      await delay(30)
      assert.equal(readFileSync(critical, 'utf8'), String(process.pid))
      unlinkSync(critical)
      release()
      process.send('held')
    }
    process.disconnect()
  `
  const children = Array.from({ length: 8 }, () => spawn(process.execPath,
    ['--input-type=module', '-e', script, dir], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] }))
  t.after(() => {
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    }
  })
  let held = 0
  const ready: Promise<void>[] = []
  const exited: Promise<void>[] = []
  for (const child of children) {
    let errors = ''
    child.stderr!.on('data', (chunk) => { errors += chunk })
    ready.push(new Promise((resolve) => {
      child.on('message', (message) => {
        if (message === 'ready') resolve()
        if (message === 'held') held++
      })
    }))
    exited.push(new Promise((resolve, reject) => {
      child.on('error', reject)
      child.once('exit', (code) => {
        if (code === 0) resolve()
        else reject(new Error(`contender exited ${code}: ${errors}`))
      })
    }))
  }
  // Observe early child failures while waiting for the start barrier.
  const done = Promise.all(exited)
  await Promise.race([Promise.all(ready), done])
  for (const child of children) child.send('go')
  await done
  assert.equal(held, 32)
  assert.deepEqual(fs.readdirSync(dir), [])
})
