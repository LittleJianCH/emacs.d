// build.test.ts --- atomic checkout builds and source-free host runtimes.
import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { execFile, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import * as fs from 'node:fs'
import { join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { Connection } from '../../emx/daemon/rpc.ts'
import { createConnection } from 'node:net'

const root = resolve(import.meta.dirname, '../..')
const exec = promisify(execFile)
function fixture(t: TestContext) {
  const dir = fs.mkdtempSync('/tmp/emx-build-')
  t.after(async () => {
    const runtime = fs.existsSync(join(dir, 'host/bin/emx')) ? join(dir, 'host') : dir
    if (fs.existsSync(join(runtime, 'emx/dist'))) await command(runtime, ['--stop', '--var', join(dir, 'var')]).catch(() => {})
    fs.rmSync(dir, { recursive: true, force: true })
  })
  fs.cpSync(join(root, 'emx'), join(dir, 'emx'), { recursive: true, filter: (file) => {
    const name = file.split('/').at(-1)!
    return name !== 'node_modules' && name !== 'dist' && !name.startsWith('.dist-')
  } })
  fs.mkdirSync(join(dir, 'bin'))
  fs.copyFileSync(join(root, 'bin/emx'), join(dir, 'bin/emx'))
  fs.cpSync(join(root, 'lisp/agent/backend/dsh'), join(dir, 'lisp/agent/backend/dsh'), { recursive: true })
  fs.symlinkSync(join(root, 'emx/node_modules'), join(dir, 'emx/node_modules'))
  fs.mkdirSync(join(dir, 'var/emx'), { recursive: true })
  fs.writeFileSync(join(dir, 'var/emx/config.json'), JSON.stringify({
    collab: { handleCommand: [], agentHandleCommands: {} }, usage: { pollInterval: 0 },
  }))
  return dir
}
function command(dir: string, args = ['--manifest'], node = process.execPath) {
  return exec(node, [join(dir, 'bin/emx'), 'daemon', ...args], {
    env: { ...process.env, HOME: dir }, timeout: 20000,
  })
}
function generation(dir: string) { return fs.readlinkSync(join(dir, 'emx/dist')) }

test('clean ensure builds once, concurrent touched sources build once, failures retain the previous runtime', async (t) => {
  const dir = fixture(t)
  const args = ['--ensure', '--var', join(dir, 'var')]
  assert.equal(fs.existsSync(join(dir, 'emx/dist')), false)
  const first = JSON.parse((await command(dir, args)).stdout)
  const manifest = JSON.parse((await command(dir)).stdout)
  const original = generation(dir)
  const noop = JSON.parse((await command(dir, args)).stdout)
  assert.equal(noop.pid, first.pid)
  assert.equal(generation(dir), original)
  const source = join(dir, 'emx/daemon/main.ts')
  const future = new Date(Date.now() + 2000)
  fs.utimesSync(source, future, future)
  await Promise.all([command(dir, args), command(dir, args)])
  assert.notEqual(generation(dir), original)
  assert.equal(fs.readdirSync(join(dir, 'emx')).filter((name) => name.startsWith('.dist-build-')).length, 2)
  assert.equal(JSON.parse((await command(dir)).stdout).version, first.version, 'mtime changes alone do not change runtime bytes')
  const previous = generation(dir)
  fs.appendFileSync(source, '\nconst invalid: number = "compiler error"\n')
  await assert.rejects(command(dir), (error: any) => /TS2322/.test(error.stderr))
  assert.equal(generation(dir), previous)
  assert.equal(fs.existsSync(join(dir, 'emx/.dist-lock')), false)
  // Stop via the built-only host, even though this checkout no longer compiles.
  await command(install(dir, manifest), ['--stop', '--var', join(dir, 'var')])
})

function install(dir: string, manifest: { files: string[] }) {
  const host = join(dir, 'host')
  for (const file of manifest.files) {
    fs.mkdirSync(resolve(host, file, '..'), { recursive: true })
    fs.copyFileSync(join(dir, file), join(host, file))
  }
  return host
}

test('concurrent builders recover a dead lock owner', async (t) => {
  const dir = fixture(t)
  const exited = spawnSync(process.execPath, ['-e', ''], { timeout: 5000 })
  assert.equal(exited.status, 0)
  fs.writeFileSync(join(dir, 'emx/.dist-lock'), String(exited.pid))
  const results = await Promise.all([command(dir), command(dir)])
  assert.equal(JSON.parse(results[0].stdout).version, JSON.parse(results[1].stdout).version)
  assert.equal(fs.readdirSync(join(dir, 'emx')).filter((name) => name.startsWith('.dist-build-')).length, 1)
  assert.equal(fs.existsSync(join(dir, 'emx/.dist-lock')), false)
})

test('manifest versions describe runtime bytes and source-free hosts never need a compiler', async (t) => {
  const dir = fixture(t)
  const first = JSON.parse((await command(dir)).stdout)
  assert.ok(first.files.includes('emx/dist/package.json'))
  assert.ok(first.files.every((file: string) => !/\.ts$|node_modules|tsconfig|package-lock|build-stamp/.test(file)))
  const host = install(dir, first)
  assert.equal(fs.existsSync(join(host, 'emx/node_modules')), false)
  assert.equal(fs.existsSync(join(host, 'emx/daemon')), false)
  assert.equal(JSON.parse((await command(host)).stdout).version, first.version)
  for (const entry of first.integrity) {
    const bytes = fs.readFileSync(join(host, entry.file))
    assert.equal(bytes.length, entry.size)
    assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256)
  }
  fs.appendFileSync(join(dir, 'emx/daemon/main.ts'), '\n// comments do not change emitted code\n')
  assert.equal(JSON.parse((await command(dir)).stdout).version, first.version)
  fs.appendFileSync(join(dir, 'emx/daemon/main.ts'), '\nvoid "changed runtime"\n')
  assert.notEqual(JSON.parse((await command(dir)).stdout).version, first.version)
  const config = join(dir, 'emx/config.json')
  const value = JSON.parse(fs.readFileSync(config, 'utf8')); value.collab.maxActive++
  const before = JSON.parse((await command(dir)).stdout).version
  fs.writeFileSync(config, JSON.stringify(value))
  assert.notEqual(JSON.parse((await command(dir)).stdout).version, before)
})

// This inventory is intentionally explicit: review new APIs against the minimum.
// AbortSignal.any is the limiting API (18.17.0, also backported from 20.3.0).
const apiFloor = {
  'crypto.randomUUID': '14.17.0', 'timers/promises.setTimeout': '15.0.0',
  'Array.at': '16.6.0', 'Object.hasOwn': '16.9.0', 'structuredClone': '17.0.0',
  'AbortSignal.timeout': '17.3.0', 'Array.findLast': '18.0.0', 'AbortSignal.any': '18.17.0',
}
test('build target and runtime APIs stay within Node 18.17', async (t) => {
  assert.equal(JSON.parse(fs.readFileSync(join(root, 'emx/tsconfig.json'), 'utf8')).compilerOptions.target, 'es2022')
  const build = JSON.parse(fs.readFileSync(join(root, 'emx/tsconfig.build.json'), 'utf8')).compilerOptions
  assert.equal(build.rewriteRelativeImportExtensions, true)
  assert.equal(JSON.parse(fs.readFileSync(join(root, 'emx/tsconfig.json'), 'utf8')).compilerOptions.erasableSyntaxOnly, true)
  assert.deepEqual(build.lib, ['es2023'])
  assert.equal(apiFloor['AbortSignal.any'], '18.17.0')
  const manifest = JSON.parse((await exec(process.execPath, [join(root, 'bin/emx'), 'daemon', '--manifest'])).stdout)
  const modules = new Set(['child_process', 'crypto', 'events', 'fs', 'fs/promises', 'net', 'os', 'path', 'readline', 'timers/promises', 'url', 'util'])
  for (const file of ['bin/emx', ...manifest.files.filter((f: string) => f.startsWith('emx/dist/') && f.endsWith('.js'))]) {
    const text = fs.readFileSync(join(root, file), 'utf8')
    assert.doesNotMatch(text, /import\.meta\.(dirname|filename|resolve)|Promise\.withResolvers|(?:Object|Map)\.groupBy|Array\.fromAsync|\.to(?:Sorted|Reversed|Spliced)\(|process\.(getBuiltinModule|availableMemory)|\b(?:globSync|openAsBlob)\b|\.glob\s*\(/, file)
    assert.doesNotMatch(text, /(?:from\s*|import\s*\()['"][^'"]+\.ts['"]/, file)
    for (const match of text.matchAll(/['"]node:([^'"]+)['"]/g)) assert.ok(modules.has(match[1]), `${file}: review new builtin ${match[1]}`)
  }
})

test('minimum Node runs every compiled module, daemon, config, echo session and stdio MCP', { skip: !process.env.EMX_NODE_MIN }, async (t) => {
  const dir = fixture(t)
  const node = process.env.EMX_NODE_MIN!
  const manifest = JSON.parse((await command(dir)).stdout)
  const host = install(dir, manifest)
  const varDir = join(dir, 'var')
  const modules = manifest.files.filter((f: string) => f.startsWith('emx/dist/') && f.endsWith('.js'))
  const probe = `import {pathToFileURL} from 'node:url';
    for (const file of ${JSON.stringify(modules)}) await import(pathToFileURL(${JSON.stringify(host)} + '/' + file));
    if (typeof AbortSignal.any !== 'function' || typeof [].findLast !== 'function') throw Error('API floor');`
  await exec(node, ['--input-type=module', '-e', probe])
  const info = JSON.parse((await command(host, ['--ensure', '--var', varDir], node)).stdout)
  const peer = new Connection(createConnection(info.socket))
  t.after(() => peer.socket.destroy())
  await peer.request('hello', { client: 'minimum-node', version: info.version })
  const config: any = await peer.request('config/get', {})
  assert.deepEqual(config.config.collab.handleCommand, [])
  const session: any = await peer.request('session/open', { agent: 'echo', root: dir })
  await peer.request('session/attach', { id: session.id })
  await peer.request('session/send', { id: session.id, text: 'compiled runtime', block: 'test-user' })
  const input = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }) + '\n'
  const mcp = spawnSync(node, [join(host, 'bin/emx'), 'mcp'], {
    encoding: 'utf8', input, env: { ...process.env, EMX_DAEMON_SOCKET: info.socket, EMX_SESSION: session.id }, timeout: 5000,
  })
  assert.equal(mcp.status, 0, mcp.stderr)
  assert.equal(JSON.parse(mcp.stdout).result.serverInfo.name, 'emacs')
  await peer.request('session/stop', { id: session.id })
})
