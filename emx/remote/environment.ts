// environment.ts --- project environments, matching tramp-rpc's direnv overlay.
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { lstat, readdir, readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { promisify } from 'node:util'

const execute = promisify(execFile)
// Keep this aligned with tramp-rpc-direnv-essential-vars.
const essential = new Set(['PATH', 'LD_LIBRARY_PATH', 'LIBRARY_PATH', 'CARGO_HOME',
  'RUSTUP_HOME', 'RUST_SRC_PATH', 'CC', 'CXX', 'PKG_CONFIG_PATH', 'NIX_CC',
  'NIX_CFLAGS_COMPILE', 'NIX_LDFLAGS', 'GOPATH', 'GOROOT', 'PYTHONPATH',
  'VIRTUAL_ENV', 'NODE_PATH', 'NPM_CONFIG_PREFIX'])

/** Include parent .envrc and shallow .direnv metadata; never walk dependencies. */
async function fingerprint(root: string): Promise<string> {
  const hash = createHash('sha256')
  const visit = async (file: string): Promise<void> => {
    try {
      const stat = await lstat(file)
      hash.update(file + ':' + stat.mtimeMs + ':' + stat.size)
      if (stat.isDirectory()) {
        for (const name of (await readdir(file)).sort()) {
          const child = await lstat(join(file, name))
          hash.update(name + ':' + child.mtimeMs + ':' + child.size)
        }
      } else if (stat.isFile() && file.endsWith('/.envrc')) hash.update(await readFile(file))
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  for (let dir = resolve(root); ; dir = dirname(dir)) {
    await visit(join(dir, '.envrc')); await visit(join(dir, '.direnv'))
    if (dirname(dir) === dir) break
  }
  return hash.digest('hex')
}

export class ProjectEnvironments {
  readonly base: NodeJS.ProcessEnv
  #cache = new Map<string, { stamp: string, at: number, env: NodeJS.ProcessEnv }>()
  constructor(base: NodeJS.ProcessEnv = process.env) { this.base = { ...base } }
  /** Read the last resolved environment without running direnv or host work. */
  peek(root: string): NodeJS.ProcessEnv {
    return this.#cache.get(resolve(root))?.env ?? this.base
  }
  async get(root: string, notice: (message: string) => void = () => {}): Promise<NodeJS.ProcessEnv> {
    root = resolve(root)
    let stamp: string
    try { stamp = await fingerprint(root) }
    catch (error) { notice(String(error)); return { ...this.base } }
    const old = this.#cache.get(root)
    if (old?.stamp === stamp && Date.now() - old.at < 300_000) return { ...old.env }
    const env = { ...this.base }
    try {
      // direnv itself checks authorization. Never run .envrc directly.
      const { stdout } = await execute('direnv', ['export', 'json'], {
        cwd: root, env, timeout: 10000, maxBuffer: 4 * 1024 * 1024,
      })
      // Without an .envrc, or with nothing to change, direnv prints nothing.
      const overlay = stdout.trim() ? JSON.parse(stdout) : {}
      for (const [key, value] of Object.entries(overlay)) {
        if (!essential.has(key)) continue
        if (value === null) delete env[key]
        else if (typeof value === 'string') env[key] = value
      }
    } catch (error) { notice(String(error)) }
    this.#cache.set(root, { stamp, at: Date.now(), env })
    return { ...env }
  }
}
