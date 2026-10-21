// history.ts --- native session discovery without opening an agent session.
import { spawn } from 'node:child_process'
import { open, readdir, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, isAbsolute, join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import type { AgentConfig } from '../config.ts'
import { checkoutRoot } from '../daemon/paths.ts'
import { encodePath } from './claude.ts'

export interface HistoryItem { id: string, title: string, time: number, root?: string, worktree?: string }
interface Directory { root: string, label?: string }

/** Short-lived discovery processes have a deadline and always reap their child. */
async function peer<T>(command: string[], root: string, env: NodeJS.ProcessEnv | undefined,
  run: (request: (method: string, params?: unknown) => Promise<any>, notify: (method: string) => void) => Promise<T>): Promise<T> {
  const child = spawn(command[0], command.slice(1), { cwd: root, env, stdio: 'pipe' })
  child.stdin.on('error', () => {})
  child.stderr.resume()
  let next = 0
  const pending = new Map<number, { resolve: (v: any) => void, reject: (e: Error) => void }>()
  const fail = (e: Error) => { for (const p of pending.values()) p.reject(e); pending.clear() }
  child.once('error', fail)
  child.once('exit', () => fail(new Error('History process exited')))
  const timer = setTimeout(() => { fail(new Error('History request timed out')); child.kill() }, 15000)
  const lines = createInterface({ input: child.stdout })
  lines.on('line', (line) => {
    try {
      const msg = JSON.parse(line), p = pending.get(msg.id)
      if (p) { pending.delete(msg.id); msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result) }
    } catch { /* Startup diagnostics are not protocol messages. */ }
  })
  const write = (value: object) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n')
  try {
    return await run((method, params = {}) => new Promise((resolve, reject) => {
      const id = ++next
      pending.set(id, { resolve, reject }); write({ id, method, params })
    }), (method) => { write({ method }) })
  } finally { clearTimeout(timer); lines.close(); child.kill() }
}

async function directories(root: string, env?: NodeJS.ProcessEnv): Promise<Directory[]> {
  const paths = await new Promise<string[]>((done) => {
    const child = spawn('git', ['worktree', 'list', '--porcelain', '-z'], { cwd: root, env, stdio: ['ignore', 'pipe', 'ignore'] })
    let output = ''
    const timer = setTimeout(() => child.kill(), 5000)
    child.stdout.on('data', (v) => { output += v })
    child.once('error', () => { clearTimeout(timer); done([]) })
    child.once('close', (code) => {
      clearTimeout(timer)
      done(code === 0 ? output.split('\0').filter((v) => v.startsWith('worktree ')).map((v) => resolve(v.slice(9))) : [])
    })
  })
  return [{ root }, ...paths.includes(root) ? paths.filter((p) => p !== root).map((p) => ({ root: p, label: basename(p) })) : []]
}

const title = (value: unknown): string => typeof value === 'string' && value.trim() ? value.trim().split('\n')[0] : '（无标题）'
const location = (cwd: string, dirs: Directory[]) => {
  const dir = dirs.find((d) => d.root === cwd)
  return dir?.label ? { root: dir.root, worktree: dir.label } : {}
}

/** Bound title reads to the transcript head/tail, as the original sidebar did. */
async function claudeTitle(file: string): Promise<string> {
  const handle = await open(file, 'r')
  try {
    const size = (await handle.stat()).size
    const read = async (start: number) => {
      const buffer = Buffer.alloc(Math.min(65536, size - start))
      await handle.read(buffer, 0, buffer.length, start)
      return buffer.toString('utf8').split('\n').flatMap((line) => { try { return [JSON.parse(line)] } catch { return [] } })
    }
    const custom = (await read(Math.max(0, size - 65536))).reverse().find((e) => e.type === 'custom-title')
    if (custom?.customTitle) return title(custom.customTitle)
    for (const e of await read(0)) {
      if (e.type !== 'user' || e.isMeta || e.isSidechain) continue
      const c = e.message?.content
      const text = typeof c === 'string' ? c : Array.isArray(c) && c.length && c.every((p) => ['text', 'image'].includes(p.type))
        ? c.map((p) => p.type === 'image' ? '[图片]' : p.text).join('\n') : undefined
      if (text && !text.trimStart().startsWith('<')) return title(text)
    }
    return title(undefined)
  } finally { await handle.close() }
}

export async function history(agent: string, root: string, config?: AgentConfig,
  environment?: () => Promise<NodeJS.ProcessEnv>): Promise<HistoryItem[]> {
  if (!isAbsolute(root) || /^\/[^/]+:/.test(root)) throw new Error('History requires a host-local absolute root')
  root = resolve(root)
  const env = await environment?.(), dirs = await directories(root, env)
  if (agent === 'claude') {
    const projects = process.env.EMX_CLAUDE_PROJECTS_DIR ?? join(homedir(), '.claude/projects')
    const names = await readdir(projects).catch((e) => { if (e.code === 'ENOENT') return []; throw e })
    const sources = dirs.map((d) => ({ ...d, name: encodePath(d.root) }))
    const prefix = encodePath(root) + '--claude-worktrees-'
    for (const name of names) if (name.startsWith(prefix) && !sources.some((d) => d.name === name)) {
      const label = name.slice(prefix.length)
      sources.push({ name, label, root: join(root, '.claude/worktrees', label) })
    }
    const files = (await Promise.all(sources.map(async (d) => {
      const files = await readdir(join(projects, d.name)).catch((e) => { if (e.code === 'ENOENT') return []; throw e })
      return Promise.all(files.filter((f) => f.endsWith('.jsonl')).map(async (f) => {
        const file = join(projects, d.name, f)
        return { file, dir: d, time: (await stat(file)).mtimeMs / 1000 }
      }))
    }))).flat().sort((a, b) => b.time - a.time).slice(0, 50)
    return Promise.all(files.map(async ({ file, dir, time }) => ({ id: basename(file, '.jsonl'), title: await claudeTitle(file), time,
      ...dir.label ? { root: dir.root, worktree: dir.label } : {} })))
  }
  if (!config) throw new Error(`Agent is not configured: ${agent}`)
  const cwds = dirs.map((d) => d.root)
  if (agent === 'codex') return peer([config.executable, 'app-server', ...(config.extraArgs ?? [])], root, env, async (request, notify) => {
    await request('initialize', { clientInfo: { name: 'emx-history', version: '1' } }); notify('initialized')
    const result = await request('thread/list', { cwd: cwds, limit: 50, sortKey: 'updated_at', sortDirection: 'desc' })
    return (result.data ?? []).filter((t: any) => cwds.includes(t.cwd)).map((t: any) => ({
      id: t.id, title: title(t.name ?? t.preview), time: t.updatedAt, ...location(t.cwd, dirs),
    }))
  })
  if (agent === 'dsh') return peer([config.executable, '--profile', 'sdk', '--patch',
    join(checkoutRoot, 'lisp/agent/backend/dsh/emacs.yml'), ...(config.extraArgs ?? [])], root, env, async (request) => {
    const result = await request('sessions/list', { cwds })
    return (result.sessions ?? []).filter((s: any) => cwds.includes(s.cwd)).map((s: any) => ({
      id: s.id, title: title(s.title), time: s.time, ...location(s.cwd, dirs),
    }))
  })
  throw new Error(`Unknown history agent: ${agent}`)
}
