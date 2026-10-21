// outbox.ts --- durable, ordered usage with stable producer sequence numbers.
import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

export interface Delivery {
  id: string // Correlates in-flight transport requests.
  source: string
  sequence: number
  method: 'record' | 'quota'
  params: Record<string, any>
}
export class Outbox {
  readonly file: string
  source = randomUUID()
  sequence = 0
  entries: Delivery[] = []
  changed: () => void = () => {}
  constructor(file: string) { this.file = file }
  restore(): void {
    // Corrupt state must fail startup rather than silently discard usage.
    if (!existsSync(this.file)) return
    const state = JSON.parse(readFileSync(this.file, 'utf8'))
    if (typeof state.source !== 'string' || !Number.isSafeInteger(state.sequence) || !Array.isArray(state.entries)) throw new Error('Invalid usage outbox')
    this.source = state.source; this.sequence = state.sequence; this.entries = state.entries
  }
  #save(): void {
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 })
    writeFileSync(this.file + '.tmp', JSON.stringify({ source: this.source, sequence: this.sequence, entries: this.entries }), { mode: 0o600 })
    renameSync(this.file + '.tmp', this.file)
  }
  add(method: Delivery['method'], params: Delivery['params']): void {
    this.entries.push({ id: randomUUID(), source: this.source, sequence: ++this.sequence, method, params: structuredClone(params) })
    this.#save()
    this.changed()
  }
  ack(source: string, sequence: number): void {
    this.entries = this.entries.filter((entry) => entry.source !== source || entry.sequence > sequence)
    this.#save()
  }
}
