// rpc.ts --- JSON-RPC 2.0 over a stream, one JSON object per line.

import type { Socket } from 'node:net'
import { ErrorCode } from './protocol.ts'

export class RpcError extends Error {
  readonly code: number
  constructor(code: number, message: string) {
    super(message)
    this.code = code
  }
}

/**
 * A handler's result, with work to do once the reply has been written:
 * session/attach replies first and then sends the session's blocks.
 */
export class Reply {
  readonly result: unknown
  // Not named `then`: that would make a Reply a thenable, which `await`
  // would try to resolve.
  readonly afterWrite: () => void
  constructor(result: unknown, afterWrite: () => void) {
    this.result = result
    this.afterWrite = afterWrite
  }
}

type RequestHandler = (method: string, params: any) => unknown
type NotificationHandler = (method: string, params: any) => void

interface Pending {
  resolve: (value: unknown) => void
  reject: (error: Error) => void
}

/** One peer: requests both ways, notifications both ways. */
export class Connection {
  readonly socket: Socket
  onRequest: RequestHandler = (method) => {
    throw new RpcError(ErrorCode.MethodNotFound, `Method not found: ${method}`)
  }
  onNotification: NotificationHandler = () => {}
  onClose: () => void = () => {}

  #buffer = ''
  #nextId = 1
  #pending = new Map<number, Pending>()
  #closed = false

  constructor(socket: Socket) {
    this.socket = socket
    // A string decoder: a character split between chunks stays whole.
    socket.setEncoding('utf8')
    socket.on('data', (chunk: string) => this.#data(chunk))
    socket.on('error', () => {})
    socket.on('close', () => {
      this.#closed = true
      for (const pending of this.#pending.values()) {
        pending.reject(new Error('connection closed'))
      }
      this.#pending.clear()
      this.onClose()
    })
  }

  get closed(): boolean {
    return this.#closed
  }

  notify(method: string, params: unknown): void {
    this.#write({ jsonrpc: '2.0', method, params })
  }

  request(method: string, params: unknown): Promise<unknown> {
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      if (this.#closed) return reject(new Error('connection closed'))
      this.#pending.set(id, { resolve, reject })
      this.#write({ jsonrpc: '2.0', id, method, params })
    })
  }

  close(): void {
    this.socket.end()
  }

  #write(message: unknown): void {
    if (this.#closed || this.socket.destroyed) return
    this.socket.write(JSON.stringify(message) + '\n')
  }

  #data(chunk: string): void {
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
      this.#write({ jsonrpc: '2.0', id: null,
                    error: { code: ErrorCode.ParseError, message: 'Parse error' } })
      return
    }
    if (message === null || typeof message !== 'object') return
    if ('method' in message) {
      if (message.id === undefined || message.id === null) {
        try {
          this.onNotification(message.method, message.params ?? {})
        } catch {
          // A notification has nobody to tell.
        }
      } else {
        void this.#handle(message.id, message.method, message.params ?? {})
      }
    } else if (typeof message.id === 'number') {
      const pending = this.#pending.get(message.id)
      if (!pending) return
      this.#pending.delete(message.id)
      if (message.error) pending.reject(new RpcError(message.error.code, message.error.message))
      else pending.resolve(message.result)
    }
  }

  async #handle(id: unknown, method: string, params: unknown): Promise<void> {
    try {
      let value = this.onRequest(method, params)
      if (value instanceof Promise || (value !== null && typeof value === 'object'
        && typeof (value as { then?: unknown }).then === 'function')) value = await value
      if (value instanceof Reply) {
        this.#write({ jsonrpc: '2.0', id, result: value.result })
        value.afterWrite()
      } else {
        this.#write({ jsonrpc: '2.0', id, result: value ?? {} })
      }
    } catch (error) {
      const code = error instanceof RpcError ? error.code : ErrorCode.Internal
      const text = error instanceof Error ? error.message : String(error)
      this.#write({ jsonrpc: '2.0', id, error: { code, message: text } })
    }
  }
}
