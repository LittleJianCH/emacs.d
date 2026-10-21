// client.ts --- a small test client for the emx daemon's socket protocol.
//
// It speaks only the wire contract of emx/daemon/protocol.ts: newline
// delimited JSON-RPC 2.0 over a Unix socket.  Every wait is bounded so a
// broken daemon fails a test instead of hanging the suite.

import './fixtures/environment.ts'
import type { Method, Params, Result } from '../../emx/daemon/protocol.ts'
import type { Socket } from 'node:net'
import * as net from 'node:net'

export interface Notification {
  method: string
  params: any
}

export interface DaemonClient {
  /** Every notification received, in order, including `replaced`. */
  readonly notifications: Notification[]
  readonly closed: boolean
  /** Send a request and resolve with its result, or reject with its error. */
  request<M extends Method>(method: M, params: Params<M>): Promise<Result<M>>
  /** Send a notification (no reply). */
  notify(method: string, params?: unknown): void
  /** Resolve with a matching notification, or reject after a bounded wait. */
  waitFor(
    predicate: (notification: Notification) => boolean,
    timeoutMs?: number,
    description?: string,
    from?: number,
  ): Promise<Notification>
  /** Close the connection and wait for the socket to be gone. */
  close(): Promise<void>
}

interface Pending {
  method: string
  resolve: (value: unknown) => void
  reject: (error: Error) => void
}

interface Waiter {
  predicate: (notification: Notification) => boolean
  from: number
  description: string
  resolve: (notification: Notification) => void
  reject: (error: Error) => void
  timer: NodeJS.Timeout
}

class RpcFailure extends Error {
  readonly code: number

  constructor(code: number, message: string) {
    super(message)
    this.name = 'RpcFailure'
    this.code = code
  }
}

function describe(notification: Notification): string {
  let params: string
  try {
    params = JSON.stringify(notification.params)
  } catch {
    params = String(notification.params)
  }
  if (params.length > 220) params = params.slice(0, 220) + '...'
  return `${notification.method} ${params}`
}

export class SocketClient implements DaemonClient {
  readonly notifications: Notification[] = []

  #socket: Socket
  #buffer = ''
  #nextId = 1
  #pending = new Map<number, Pending>()
  #waiters = new Set<Waiter>()
  #closed = false

  private constructor(socket: Socket) {
    this.#socket = socket
    socket.setEncoding('utf8')
    socket.on('data', (chunk: string) => this.#onData(chunk))
    // A dropped connection is reported through pending requests and waiters;
    // without a listener the socket would throw an uncaught 'error'.
    socket.on('error', () => {})
    socket.on('close', () => this.#onClose())
  }

  /** Open a connection. The caller normally sends `hello` next. */
  static async connect(socketPath: string): Promise<DaemonClient> {
    const socket = net.connect({ path: socketPath })
    await new Promise<void>((resolve, reject) => {
      const ready = (): void => {
        socket.off('connect', ready)
        socket.off('error', failed)
        resolve()
      }
      const failed = (error: Error): void => {
        socket.off('connect', ready)
        socket.off('error', failed)
        reject(error)
      }
      socket.once('connect', ready)
      socket.once('error', failed)
    })
    return new SocketClient(socket)
  }

  get closed(): boolean {
    return this.#closed
  }

  request<M extends Method>(method: M, params: Params<M>): Promise<Result<M>> {
    if (this.#closed) {
      return Promise.reject(new Error(`connection closed before ${method}`))
    }
    const id = this.#nextId++
    return new Promise<Result<M>>((resolve, reject) => {
      this.#pending.set(id, {
        method,
        resolve: resolve as (value: unknown) => void,
        reject,
      })
      this.#write({ jsonrpc: '2.0', id, method, params })
    })
  }

  notify(method: string, params: unknown = {}): void {
    this.#write({ jsonrpc: '2.0', method, params })
  }

  waitFor(
    predicate: (notification: Notification) => boolean,
    timeoutMs = 5000,
    description = 'notification',
    from = 0,
  ): Promise<Notification> {
    for (let i = from; i < this.notifications.length; i++) {
      if (predicate(this.notifications[i])) {
        return Promise.resolve(this.notifications[i])
      }
    }
    if (this.#closed) {
      return Promise.reject(new Error(`connection closed while waiting for ${description}`))
    }
    return new Promise<Notification>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#waiters.delete(waiter)
        const seen = this.notifications.slice(-8).map(describe).join('\n  ')
        reject(new Error(
          `timed out after ${timeoutMs} ms waiting for ${description}` +
          (seen ? `; last notifications:\n  ${seen}` : '; no notifications received'),
        ))
      }, timeoutMs)
      const waiter: Waiter = { predicate, from, description, resolve, reject, timer }
      this.#waiters.add(waiter)
    })
  }

  async close(): Promise<void> {
    if (this.#socket.destroyed) return
    await new Promise<void>((resolve) => {
      let timer: NodeJS.Timeout
      const done = (): void => {
        clearTimeout(timer)
        resolve()
      }
      timer = setTimeout(() => {
        this.#socket.destroy()
        done()
      }, 1000)
      this.#socket.once('close', done)
      this.#socket.end()
    })
  }

  #write(message: unknown): void {
    if (this.#closed || this.#socket.destroyed) return
    this.#socket.write(JSON.stringify(message) + '\n')
  }

  #onData(chunk: string): void {
    this.#buffer += chunk
    let newline: number
    while ((newline = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, newline)
      this.#buffer = this.#buffer.slice(newline + 1)
      if (line.trim()) this.#line(line)
    }
  }

  #line(line: string): void {
    let message: any
    try {
      message = JSON.parse(line)
    } catch {
      return
    }
    if (message === null || typeof message !== 'object') return
    if (typeof message.method === 'string') {
      const notification: Notification = {
        method: message.method,
        params: message.params ?? {},
      }
      const index = this.notifications.length
      this.notifications.push(notification)
      for (const waiter of [...this.#waiters]) {
        if (index >= waiter.from && waiter.predicate(notification)) {
          clearTimeout(waiter.timer)
          this.#waiters.delete(waiter)
          waiter.resolve(notification)
        }
      }
      return
    }
    if (typeof message.id !== 'number') return
    const pending = this.#pending.get(message.id)
    if (!pending) return
    this.#pending.delete(message.id)
    if (message.error) {
      pending.reject(new RpcFailure(
        Number(message.error.code),
        String(message.error.message ?? 'JSON-RPC error'),
      ))
    } else {
      pending.resolve(message.result)
    }
  }

  #onClose(): void {
    this.#closed = true
    for (const pending of this.#pending.values()) {
      pending.reject(new Error(`connection closed while waiting for ${pending.method}`))
    }
    this.#pending.clear()
    for (const waiter of [...this.#waiters]) {
      clearTimeout(waiter.timer)
      this.#waiters.delete(waiter)
      waiter.reject(new Error(`connection closed while waiting for ${waiter.description}`))
    }
  }
}