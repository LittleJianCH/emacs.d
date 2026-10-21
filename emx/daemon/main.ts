// main.ts --- foreground daemon, detached startup and clean shutdown.

import { spawn } from 'node:child_process'
import { appendFile, chmod, mkdir } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { join, resolve } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { checkoutRoot, defaultVar, socketPath, stateDir } from './paths.ts'
import type { HelloResult } from './protocol.ts'
import { Connection } from './rpc.ts'
import { DaemonServer } from './server.ts'

interface Options {
  varDir: string
  idleExit: number
  mode: 'foreground' | 'ensure' | 'stop'
}

function options(args: string[]): Options {
  const result: Options = { varDir: defaultVar, idleExit: 900, mode: 'foreground' }
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === '--var') {
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
  const socket = socketPath(opts.varDir)
  let peer = await ping(socket)
  let started = false
  if (!peer) {
    started = true
    const child = spawn(process.execPath, [join(checkoutRoot, 'bin', 'emx'), 'daemon',
      '--var', opts.varDir, '--idle-exit', String(opts.idleExit)], { detached: true, stdio: 'ignore' })
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
  console.log(JSON.stringify({ socket, version: peer.result.version, pid: peer.result.daemon, started }))
  peer.connection.close()
}

async function stop(opts: Options): Promise<void> {
  const peer = await ping(socketPath(opts.varDir))
  if (!peer) return
  const connection = peer.connection
  let timeout: NodeJS.Timeout | undefined
  const closed = new Promise<void>((resolve, reject) => {
    connection.socket.once('close', () => resolve())
    timeout = setTimeout(() => {
      connection.socket.destroy()
      reject(new Error('Daemon did not stop within 5 seconds'))
    }, 5000)
  })
  // Observe a close timeout immediately, even if the stop reply never arrives.
  const requested = connection.request('daemon/stop', {})
  try {
    await Promise.race([requested, closed])
    await closed
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
  const daemon = new DaemonServer({ varDir: opts.varDir, idleExit: opts.idleExit, log })
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
  if (opts.mode === 'ensure') await ensure(opts)
  else if (opts.mode === 'stop') await stop(opts)
  else await foreground(opts)
}
