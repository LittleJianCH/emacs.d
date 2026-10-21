// paths.ts --- where a daemon keeps its socket and state, and its version.

import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The emx/ directory of this checkout. */
export const emxRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/** The checkout this daemon's code belongs to. */
export const checkoutRoot = resolve(emxRoot, '..')

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

let version: string | undefined

/**
 * A hash of the daemon's code: the TypeScript under emx/ and bin/emx.
 * A client whose copy hashes differently runs other code.
 */
export function codeVersion(): string {
  if (version !== undefined) return version
  const files: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) walk(path)
      else if (/\.(ts|json)$/.test(entry.name)) files.push(path)
    }
  }
  walk(emxRoot)
  files.push(join(checkoutRoot, 'bin', 'emx'))
  const hash = createHash('sha1')
  for (const file of files.sort()) {
    hash.update(relative(checkoutRoot, file)).update('\0').update(readFileSync(file)).update('\0')
  }
  version = hash.digest('hex').slice(0, 16)
  return version
}
