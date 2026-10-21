// backend.ts --- the boundary between an agent adapter and its session.

import type { Answer, Ask, Block, Info, Settings, Status } from '../daemon/protocol.ts'
import { EchoBackend } from './echo.ts'
import { DshBackend } from './dsh.ts'
import type { McpServer, SessionEvent } from '../daemon/protocol.ts'

export type NewAsk = Ask extends infer A ? A extends Ask ? Omit<A, 'id'> : never : never

export interface SessionHost {
  readonly root: string
  readonly settings: Settings
  readonly info: Info
  readonly blocks: Block[]
  readonly mcpServers: McpServer[]
  emit(event: SessionEvent): void
  setStatus(status: Status): void
  setInfo(info: Info): void
  addBlock(block: Block, before?: string): void
  append(id: string, text: string): void
  update(id: string, fields: Partial<Record<string, unknown>>): void
  remove(ids: string[]): void
  /** Cancellation resolves with an empty answer. */
  ask(ask: NewAsk): Promise<Answer>
  newId(prefix: string): string
}

export interface Backend {
  start(resume?: string): void | Promise<void>
  send(text: string, images?: string[], block?: string): void | Promise<void>
  steer(text: string, images?: string[], block?: string): boolean
  interrupt(): void
  configure(settings: Settings): void | Promise<void>
  stop(): void | Promise<void>
  alive(): boolean
  resumeId(): string | undefined
}

export const backends: Record<string, (host: SessionHost) => Backend> = {
  echo: (host) => new EchoBackend(host),
  dsh: (host) => new DshBackend(host),
}
