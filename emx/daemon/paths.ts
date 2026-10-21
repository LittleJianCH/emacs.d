// paths.ts --- where a daemon keeps its socket and state, and its version.

import { createHash } from 'node:crypto'
import { lstatSync, mkdirSync, readdirSync, readFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Runtime root: emx/ in source tests, emx/dist (or its generation) when built. */
export const emxRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/** The checkout this daemon's code belongs to. */
export const checkoutRoot = resolve(emxRoot, import.meta.url.endsWith('.ts') ? '..' : '../..')

/** The built tree whose bytes this process imports (immutable in a checkout). */
const runtimeRoot = import.meta.url.endsWith('.ts') ? join(emxRoot, 'dist') : emxRoot

/** Read an installed runtime path from this process's own generation. */
export function runtimePath(file: string): string {
  return file.startsWith('emx/dist/') ? join(runtimeRoot, file.slice('emx/dist/'.length)) : join(checkoutRoot, file)
}

/** The checkout's runtime directory, the default for --var. */
export const defaultVar = join(checkoutRoot, 'var')

/** Longest socket path we bind: sun_path is 104 bytes on macOS. */
const MAX_SOCKET = 100

/** The daemon's directory under VAR: its state and, if short enough, its socket. */
export function stateDir(varDir: string): string {
  return join(resolve(varDir), 'emx')
}

/**
 * The socket of the daemon for VAR.  Under VAR when the path fits in a
 * Unix socket address, else in the temp directory, named after VAR so
 * each checkout keeps its own daemon.
 */
export function socketPath(varDir: string): string {
  const path = join(stateDir(varDir), 'daemon.sock')
  if (Buffer.byteLength(path) <= MAX_SOCKET) return path
  const hash = createHash('sha1').update(resolve(varDir)).digest('hex').slice(0, 12)
  return join(tmpdir(), `emx-${hash}.sock`)
}

/** Runtime files shared by the installer and code hash; never development trees. */
export function runtimeFiles(): string[] {
  const files: string[] = []
  const walk = (dir: string, prefix: string, pattern: RegExp): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const file = join(prefix, entry.name)
      if (entry.isDirectory()) walk(join(dir, entry.name), file, pattern)
      else if (pattern.test(entry.name)) files.push(file)
    }
  }
  walk(runtimeRoot, 'emx/dist', /\.(js|json)$/)
  const dsh = 'lisp/agent/backend/dsh'
  walk(join(checkoutRoot, dsh), dsh, /\.(mjs|yml)$/)
  const pi = 'lisp/agent/backend/pi'
  walk(join(checkoutRoot, pi), pi, /\.js$/)
  files.push('bin/emx')
  return files.sort()
}

/** Host state is stable across content-addressed code installations. */
export function clientPaths(id: string): { socket: string, varDir: string } {
  if (!/^[a-f0-9]{16,40}$/.test(id)) throw new Error('--client requires a 16..40 digit lowercase hex id')
  const base = join(homedir(), '.cache/emacs-agent/emx')
  let socket = join(base, 'run', id + '.sock')
  if (Buffer.byteLength(socket) > MAX_SOCKET) {
    const uid = process.getuid!()
    const fallback = `/tmp/emx-${uid}`
    let dir = process.env.XDG_RUNTIME_DIR || fallback
    const name = createHash('sha256').update(id).digest('hex').slice(0, 24) + '.sock'
    if (Buffer.byteLength(join(dir, name)) > MAX_SOCKET) dir = fallback
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const stat = lstatSync(dir)
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o777) !== 0o700) {
      throw new Error('Socket directory must be private, owned by us and not a symlink')
    }
    socket = join(dir, name)
  }
  return { socket, varDir: join(base, 'state', id) }
}

let version: string | undefined

/** Hash exactly the installed runtime, including dsh plugins and configuration. */
export function codeVersion(): string {
  if (version !== undefined) return version
  const hash = createHash('sha1')
  for (const file of runtimeFiles()) {
    hash.update(file).update('\0').update(readFileSync(runtimePath(file))).update('\0')
  }
  version = hash.digest('hex').slice(0, 16)
  return version
}
