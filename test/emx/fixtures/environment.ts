// Every test daemon and its descendants resolve model commands to fixtures.
// Keep the caller's HOME; native Claude history and fixture logs stay temporary.
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, existsSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { after, afterEach } from 'node:test'
import { fileURLToPath } from 'node:url'

const bin = fileURLToPath(new URL('./bin/', import.meta.url))
const state = fileURLToPath(new URL('../../../var/emx/', import.meta.url))
const dir = mkdtempSync(join(tmpdir(), 'emx-node-state-'))
process.env.PATH = bin + delimiter + (process.env.PATH ?? '')
for (const name of ['CLAUDE', 'CODEX', 'DSH', 'PI']) {
  delete process.env[`EMX_${name}_EXECUTABLE`]
  delete process.env[`EMX_${name}_CONFIG`]
  delete process.env[`EMX_${name}_LOG`]
}
for (const name of ['EMX_PI_USAGE_URL', 'EMX_CODEX_BAD_CONFIG', 'EMX_CODEX_RESTART_GATE', 'EMX_DAEMON_SOCKET', 'EMX_SESSION']) {
  delete process.env[name]
}
process.env.EMX_EMACSCLIENT = '/does-not-exist'
process.env.EMX_CLAUDE_PROJECTS_DIR = join(dir, 'projects')
mkdirSync(process.env.EMX_CLAUDE_PROJECTS_DIR)
process.env.EMX_PI_SESSIONS_DIR = join(dir, 'pi-sessions')
mkdirSync(process.env.EMX_PI_SESSIONS_DIR)

// In the checkout the user's Emacs runs from, var/emx holds the live
// daemon's state, which keeps changing: only entries the tests add count.
const stateNames = () => existsSync(state) ? readdirSync(state) : []
const stateBefore = new Set(stateNames())
export function addedStateEntries(directory: string, before: Set<string>): string[] {
  let snapshot: string | undefined
  if (before.has('daemon.lock')) {
    try {
      const lock = JSON.parse(readFileSync(join(directory, 'daemon.lock'), 'utf8'))
      const pid = typeof lock === 'number' ? lock : lock?.pid
      if (Number.isSafeInteger(pid) && pid > 0 && pid !== process.pid) snapshot = `sessions.json.${pid}.tmp`
    } catch { /* Missing or incomplete locks do not exempt any new files. */ }
  }
  // The already-running daemon writes this between its snapshot and rename.
  const names = existsSync(directory) ? readdirSync(directory) : []
  return names.filter((name) => !before.has(name) && name !== snapshot)
}
function assertDefaultStateUnchanged() {
  assert.deepEqual(addedStateEntries(state, stateBefore), [],
    'Tests must not write to the checkout default var/emx directory')
}
afterEach(assertDefaultStateUnchanged)
after(() => {
  try { assertDefaultStateUnchanged() } finally { rmSync(dir, { recursive: true, force: true }) }
})
