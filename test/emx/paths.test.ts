import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, lstatSync, rmSync, symlinkSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { clientPaths } from '../../emx/daemon/paths.ts'

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
