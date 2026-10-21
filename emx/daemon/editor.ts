// editor.ts --- cached editor tools and cancellable deferred calls.
import { readFile, writeFile, rename } from 'node:fs/promises'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import type { EditorTools, EditorCall } from './protocol.ts'
import type { Connection } from './rpc.ts'

export class Editor {
  tools: EditorTools = { tools: [], readOnly: [] }
  connection: Connection | undefined
  #calls = new Set<AbortController>()
  #writes: Promise<void> = Promise.resolve()
  readonly file: string
  constructor(dir: string) { this.file = join(dir, 'tools.json') }

  async restore(): Promise<void> {
    try { this.tools = this.#validate(JSON.parse(await readFile(this.file, 'utf8'))) }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
  }

  #validate(value: any): EditorTools {
    if (!Array.isArray(value?.tools) || !Array.isArray(value?.readOnly)
      || !value.readOnly.every((name: unknown) => typeof name === 'string')
      || !value.tools.every((tool: any) => typeof tool.name === 'string'
        && typeof tool.description === 'string' && tool.inputSchema?.type === 'object')) {
      throw new Error('Invalid editor tools')
    }
    // Copy only MCP definition fields. Permission hints must never reach agents.
    return { tools: value.tools.map((tool: any) => ({ name: tool.name,
      description: tool.description, inputSchema: tool.inputSchema })), readOnly: [...value.readOnly] }
  }

  update(value: unknown): boolean {
    const tools = this.#validate(value)
    if (JSON.stringify(tools) === JSON.stringify(this.tools)) return false
    this.tools = tools
    const data = JSON.stringify(tools) + '\n'
    this.#writes = this.#writes.catch(() => {}).then(async () => {
      await writeFile(this.file + '.tmp', data, { mode: 0o600 })
      await rename(this.file + '.tmp', this.file)
    })
    return true
  }

  async flush(): Promise<void> { await this.#writes }

  detach(): void {
    this.connection = undefined
    for (const call of this.#calls) call.abort(new Error('Emacs is not attached'))
  }

  async call(method: string, params: Record<string, unknown>, caller: EditorCall['caller'],
    cancelled: AbortSignal, privateCall = false): Promise<unknown> {
    const editor = this.connection
    if (!editor || editor.closed) throw new Error('Emacs is not attached')
    if (!privateCall && !this.tools.tools.some((tool) => tool.name === method)) throw new Error(`Unknown editor tool: ${method}`)
    const controller = new AbortController()
    this.#calls.add(controller)
    const signal = AbortSignal.any([cancelled, controller.signal])
    let pending: string | undefined
    const cancelPending = (id: string) => {
      if (!editor.closed) void editor.request('editor/call', {
        method: '_poll', params: { id, cancel: true }, caller,
      }).catch(() => {})
    }
    const request = async (name: string, args: Record<string, unknown>) => {
      signal.throwIfAborted()
      // Keep the original response even after cancellation: a late deferred id
      // still needs releasing on the editor that created it.
      let abort!: () => void
      const cancelled = new Promise<never>((_resolve, reject) => {
        abort = () => reject(signal.reason)
        signal.addEventListener('abort', abort, { once: true })
      })
      const response = editor.request('editor/call', { method: name, params: args, caller })
        .then((out: any) => {
          if (signal.aborted && out.pending && out.pending !== pending) cancelPending(out.pending)
          return out
        })
      try {
        const out = await Promise.race([response, cancelled])
        if (!out.ok) throw new Error(out.error ?? 'Editor call failed')
        return out
      } finally { signal.removeEventListener('abort', abort) }
    }
    try {
      let out = await request(method, params)
      while (out.pending) {
        pending = out.pending
        await delay(1000, undefined, { signal })
        out = await request('_poll', { id: pending })
      }
      pending = undefined
      return out.result
    } catch (error) {
      if (signal.aborted) throw signal.reason instanceof Error ? signal.reason : new Error('Cancelled')
      throw error
    } finally {
      this.#calls.delete(controller)
      if (pending) cancelPending(pending)
    }
  }
}
