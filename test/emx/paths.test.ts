import './fixtures/environment.ts'
import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, lstatSync, writeFileSync, rmSync, symlinkSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { clientPaths, runtimeFiles } from '../../emx/daemon/paths.ts'

test('long HOME client sockets use a stable private short directory', () => {
  const dir = mkdtempSync('/tmp/emx-paths-')
  const saved = { HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR }
  try {
    process.env.HOME = join(dir, '家'.repeat(80))
    process.env.XDG_RUNTIME_DIR = join(dir, 'run')
    const first = clientPaths('1234567890abcdef')
    assert.ok(Buffer.byteLength(first.socket) < 104)
    assert.equal(clientPaths('1234567890abcdef').socket, first.socket)
    assert.notEqual(clientPaths('abcdef1234567890').socket, first.socket)
    const stat = lstatSync(dirname(first.socket))
    assert.equal(stat.mode & 0o777, 0o700)
    assert.equal(stat.uid, process.getuid!())
    rmSync(process.env.XDG_RUNTIME_DIR, { recursive: true, force: true })
    mkdirSync(join(dir, 'other'))
    symlinkSync(join(dir, 'other'), process.env.XDG_RUNTIME_DIR)
    assert.throws(() => clientPaths('1234567890abcdef'), /private|symlink/)
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value
    }
    rmSync(dir, { recursive: true, force: true })
  }
})


test('runtime manifest includes optional site configuration from the install root', () => {
  const dir = mkdtempSync('/tmp/emx-manifest-')
  try {
    for (const path of ['emx/dist', 'lisp/agent/backend/dsh', 'lisp/agent/backend/pi', 'site/emx']) {
      mkdirSync(join(dir, path), { recursive: true })
    }
    writeFileSync(join(dir, 'emx/dist/config.json'), '{}')
    const before = runtimeFiles(dir)
    assert.ok(!before.includes('site/emx/config.json'))
    writeFileSync(join(dir, 'site/emx/config.json'), '{"agents":{}}')
    assert.deepEqual(runtimeFiles(dir), [...before, 'site/emx/config.json'].sort())
    writeFileSync(join(dir, 'site/emx/private.json'), '{}')
    assert.ok(!runtimeFiles(dir).includes('site/emx/private.json'))
    rmSync(join(dir, 'site/emx/config.json'))
    assert.deepEqual(runtimeFiles(dir), before)
  } finally { rmSync(dir, { recursive: true, force: true }) }
})
