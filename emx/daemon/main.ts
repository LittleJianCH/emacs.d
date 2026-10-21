// main.ts --- foreground daemon, detached startup and clean shutdown.

import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { appendFile, chmod, mkdir } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { dirname, join, resolve } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { clientPaths, codeVersion, checkoutRoot, defaultVar, runtimeFiles, runtimePath, socketPath, stateDir } from './paths.ts'
import type { HelloResult } from './protocol.ts'
import { Connection } from './rpc.ts'
import { DaemonServer } from './server.ts'

interface Options {
  varDir: string
  client?: string
  idleExit?: number
  mode: 'foreground' | 'ensure' | 'stop' | 'manifest'
}

function options(args: string[]): Options {
  const result: Options = { varDir: defaultVar, mode: 'foreground' }
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '--client') {
      result.client = args[++i]
      if (!result.client) throw new Error('--client requires an id')
      result.varDir = clientPaths(result.client).varDir
    } else if (arg === '--manifest') {
      result.mode = 'manifest'
    } else if (arg === '--var') {
      if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error('--var requires a directory')
      result.varDir = resolve(args[++i])
    } else if (arg === '--idle-exit') {
      const value = args[++i]
      const seconds = value === undefined || value.trim() === '' ? NaN : Number(value)
      if (!Number.isFinite(seconds) || seconds < 0 || seconds * 1000 > 2 ** 31 - 1) {
        throw new Error('--idle-exit requires a non-negative number of seconds')
      }
      result.idleExit = seconds
    } else if (arg === '--ensure' || arg === '--stop') {
      if (result.mode !== 'foreground') throw new Error('Choose only one of --ensure and --stop')
      result.mode = arg === '--ensure' ? 'ensure' : 'stop'
    } else throw new Error(`Unknown daemon option: ${arg}`)
  }
  if (result.client && args.includes('--var')) throw new Error('--client and --var are mutually exclusive')
  return result
}

/** Every probe is bounded, including sockets that accept but never reply. */
async function connect(path: string, timeout = 250): Promise<Connection | undefined> {
  const socket = createConnection(path)
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      socket.destroy()
      resolve(undefined)
    }, timeout)
    socket.once('error', () => {
      clearTimeout(timer)
      resolve(undefined)
    })
    socket.once('connect', () => {
      clearTimeout(timer)
      resolve(new Connection(socket))
    })
  })
}

async function ping(path: string): Promise<{ connection: Connection, result: HelloResult } | undefined> {
  const connection = await connect(path)
  if (!connection) return undefined
  const timer = setTimeout(() => connection.socket.destroy(), 250)
  let success = false
  try {
    const result = await connection.request('ping', {}) as HelloResult
    if (typeof result?.daemon !== 'number' || typeof result.version !== 'string') return undefined
    success = true
    return { connection, result }
  } catch {
    return undefined
  } finally {
    clearTimeout(timer)
    // The caller owns a successful connection; failed probes cannot keep it alive.
    if (!success) connection.socket.destroy()
  }
}

async function ensure(opts: Options): Promise<void> {
  const socket = (opts.client ? clientPaths(opts.client).socket : socketPath(opts.varDir))
  let peer = await ping(socket)
  let started = false
  if (peer && peer.result.version !== codeVersion() && peer.result.capabilities?.stopIfIdle === 1
    && await stopPeer(peer.connection, true)) peer = undefined
  if (!peer) {
    started = true
    const child = spawn(process.execPath, [join(checkoutRoot, 'bin', 'emx'), 'daemon',
      ...(opts.client ? ['--client', opts.client] : ['--var', opts.varDir]), ...(opts.idleExit === undefined ? [] : ['--idle-exit', String(opts.idleExit)])], { detached: true, stdio: 'ignore' })
    let spawnError: Error | undefined
    child.on('error', (error) => { spawnError = error })
    child.unref()
    const deadline = Date.now() + 5000
    while (!peer && Date.now() < deadline) {
      if (spawnError) throw spawnError
      await delay(50)
      peer = await ping(socket)
    }
    if (!peer) throw new Error(`Daemon did not start within 5 seconds: ${socket}`)
  }
  console.log(JSON.stringify({ socket, version: peer.result.version, pid: peer.result.daemon, started,
    stale: peer.result.version !== codeVersion() }))
  peer.connection.close()
}

async function stop(opts: Options): Promise<void> {
  const peer = await ping((opts.client ? clientPaths(opts.client).socket : socketPath(opts.varDir)))
  if (!peer) return
  await stopPeer(peer.connection)
}

/** Use the probed peer: an automatic stop must never fall back to legacy stop. */
async function stopPeer(connection: Connection, ifIdle = false): Promise<boolean> {
  let timeout: NodeJS.Timeout | undefined
  const closed = new Promise<void>((resolve, reject) => {
    connection.socket.once('close', () => resolve())
    timeout = setTimeout(() => {
      connection.socket.destroy()
      reject(new Error('Daemon did not stop within 5 seconds'))
    }, 5000)
  })
  // Observe a close timeout immediately, even if the stop reply never arrives.
  const requested = connection.request('daemon/stop', ifIdle ? { ifIdle: true } : {})
  try {
    const result = await Promise.race([requested, closed]) as { stopped?: boolean } | undefined
    if (ifIdle && result?.stopped !== true) return false
    await closed
    return true
  } finally {
    clearTimeout(timeout)
    connection.socket.destroy()
  }
}

async function foreground(opts: Options): Promise<void> {
  const dir = stateDir(opts.varDir)
  await mkdir(dir, { recursive: true, mode: 0o700 })
  await chmod(dir, 0o700)
  // Serialize appends so the log also preserves shutdown ordering.
  let writes: Promise<void> = Promise.resolve()
  const log = (message: string): void => {
    writes = writes.then(() => appendFile(join(dir, 'daemon.log'),
      `${new Date().toISOString()} ${message}\n`, { mode: 0o600 }))
      .catch((error) => { console.error(`emx daemon: ${error.message}`) })
  }
  const socket = opts.client ? clientPaths(opts.client).socket : undefined
  if (socket) {
    await mkdir(dirname(socket), { recursive: true, mode: 0o700 })
    await chmod(dirname(socket), 0o700)
    await chmod(opts.varDir, 0o700)
  }
  const daemon = new DaemonServer({ varDir: opts.varDir, socket, remote: !!opts.client,
    idleExit: opts.idleExit, log, restart: (runtime) => {
      const child = spawn(process.execPath, [runtime, 'daemon',
        ...(opts.client ? ['--client', opts.client] : ['--var', opts.varDir]),
        '--ensure', ...(opts.idleExit === undefined ? [] : ['--idle-exit', String(opts.idleExit)])],
      { detached: true, stdio: 'ignore' })
      child.on('error', (error) => log(`Cannot launch replacement: ${error.message}`))
      child.unref()
    } })
  await daemon.start()
  const shutdown = (): void => { void daemon.stop() }
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
  try {
    await daemon.finished
    await writes
  } finally {
    process.off('SIGTERM', shutdown)
    process.off('SIGINT', shutdown)
  }
}

export async function main(args: string[]): Promise<void> {
  const opts = options(args)
  if (opts.mode === 'manifest') console.log(JSON.stringify({ version: codeVersion(), files: runtimeFiles(), integrity: runtimeFiles().map((file) => {
    const bytes = readFileSync(runtimePath(file))
    return { file, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }
  }) }))
  else if (opts.mode === 'ensure') await ensure(opts)
  else if (opts.mode === 'stop') await stop(opts)
  else await foreground(opts)
}
