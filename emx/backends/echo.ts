// echo.ts --- a deterministic agent for exercising the daemon protocol.

import type { Answer, Settings } from '../daemon/protocol.ts'
import type { Backend, SessionHost } from './backend.ts'

export class EchoBackend implements Backend {
  readonly host: SessionHost
  #live = false
  #generation = 0
  #cancel: (() => void) | undefined

  constructor(host: SessionHost) {
    this.host = host
  }

  start(_resume?: string): void {
    this.#live = true
    this.host.setStatus('idle')
  }

  async send(text: string, _images?: string[], block?: string): Promise<void> {
    const generation = this.#generation
    this.host.setStatus('running')
    this.host.addBlock({ id: block ?? this.host.newId('u'), type: 'user', text })
    if (text.startsWith('tool')) {
      const id = this.host.newId('tool')
      this.host.addBlock({ id, type: 'tool', status: 'running',
        view: { kind: 'command', name: 'echo', title: 'echo', command: 'echo' } })
      this.host.append(id, 'tool output')
      this.host.update(id, { status: 'done' })
    }
    let reply = 'echo: ' + text
    const approval = text.startsWith('ask')
    if (approval) {
      const cancelled = new Promise<Answer>((resolve) => {
        this.#cancel = () => resolve({})
      })
      let answer: Answer
      try {
        answer = await Promise.race([this.host.ask({ type: 'approval',
          choices: ['allow', 'deny'], view: { kind: 'other', name: 'echo', title: 'echo' } }),
          cancelled])
      } catch {
        answer = {}
      } finally {
        this.#cancel = undefined
      }
      reply = answer.choice === 'allow' || answer.choice === 'always' ? 'allowed'
        : answer.choice === 'deny' ? 'denied' : 'cancelled'
    }
    // A stopped turn must not resurrect the session when its ask settles.
    if (!this.#live || generation !== this.#generation) return
    const id = this.host.newId('text')
    this.host.addBlock({ id, type: 'text', kind: 'assistant', text: '', done: false })
    if (approval) this.host.append(id, reply)
    else {
      this.host.append(id, 'echo: ')
      this.host.append(id, text)
    }
    this.host.update(id, { done: true, text: reply })
    this.host.setStatus('idle')
  }

  steer(_text: string, _images?: string[], _block?: string): boolean {
    return false
  }

  interrupt(): void {
    this.#cancel?.()
  }

  configure(_settings: Settings): void {}

  stop(): void {
    this.#live = false
    this.#generation++
    this.#cancel?.()
  }

  alive(): boolean {
    return this.#live
  }

  resumeId(): string | undefined {
    return undefined
  }
}
