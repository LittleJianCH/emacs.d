// Keep tooling manifests outside the dsh plugin's package ancestry.
import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import test from 'node:test'

test('the dsh plugin has no package.json from its directory through the checkout root', () => {
  // dsh reports the nearest plugin package with every DeepSeek request.
  const root = resolve(import.meta.dirname, '../..')
  for (let dir = join(root, 'lisp/agent/backend/dsh'); ; dir = dirname(dir)) {
    assert.equal(existsSync(join(dir, 'package.json')), false, `unexpected package.json in ${dir}`)
    if (dir === root) break
  }
})
