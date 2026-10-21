// Every test daemon and its descendants resolve model commands to fixtures.
// Keep the caller's HOME; native Claude history and fixture logs stay temporary.
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, existsSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { after, afterEach } from 'node:test'
import { fileURLToPath } from 'node:url'

const bin = fileURLToPath(new URL('./bin/', import.meta.url))
const state = fileURLToPath(new URL('../../../var/emx/', import.meta.url))
const dir = mkdtempSync(join(tmpdir(), 'emx-node-state-'))
process.env.PATH = bin + delimiter + (process.env.PATH ?? '')
for (const name of ['CLAUDE', 'CODEX', 'DSH']) {
  delete process.env[`EMX_${name}_EXECUTABLE`]
  delete process.env[`EMX_${name}_CONFIG`]
  delete process.env[`EMX_${name}_LOG`]
}
for (const name of ['EMX_CODEX_BAD_CONFIG', 'EMX_CODEX_RESTART_GATE', 'EMX_DAEMON_SOCKET', 'EMX_SESSION']) {
  delete process.env[name]
}
process.env.EMX_EMACSCLIENT = '/does-not-exist'
process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
mkdirSync(process.env.EMX_CLAUDE_PROJECTS_DIR)

function assertDefaultStateEmpty() {
  assert.deepEqual(existsSync(state) ? readdirSync(state) : [], [],
    'Tests must not write to the checkout default var/emx directory')
}
assertDefaultStateEmpty()
afterEach(assertDefaultStateEmpty)
after(() => {
  try { assertDefaultStateEmpty() } finally { rmSync(dir, { recursive: true, force: true }) }
})
