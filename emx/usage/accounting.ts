// accounting.ts --- live backend events become one ledger record per turn/model.
import { homedir } from 'node:os'
import type { SessionEvent, Usage } from '../daemon/protocol.ts'
import type { Session } from '../daemon/session.ts'
import { UsageService, windowLabel } from './service.ts'

const labels: Record<string, string> = { five_hour: '5h', seven_day: '周',
  seven_day_opus: '周·Opus', seven_day_sonnet: '周·Sonnet' }

export class Accounting {
  readonly service: UsageService
  readonly pending = new Map<string, Map<string, Usage>>()

  constructor(service: UsageService) { this.service = service }

  /** Called only on original backend events, never attach/history replay. */
  accept(session: Session, event: SessionEvent): void {
    switch (event.type) {
      case 'usage/call': {
        let turn = this.pending.get(session.id)
        if (!turn) this.pending.set(session.id, turn = new Map())
        const sum = turn.get(event.model) ?? { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 }
        for (const key of ['input', 'cacheRead', 'cacheWrite', 'output'] as const) sum[key] += event.usage[key] ?? 0
        turn.set(event.model, sum)
        break
      }
      case 'usage/end': this.flush(session); break
      case 'status': if (event.status === 'exited') this.flush(session); break
      case 'quota': this.service.quota({ agent: session.agent, host: null, balance: event.balance }); break
      case 'quota/rate-limits': {
        const reading = event.rateLimits
        this.service.quota({ agent: session.agent, host: null, ...reading,
          windows: reading.windows.map((window) => ({ ...window, label: labels[window.id] ?? windowLabel(window.minutes) })) })
        break
      }
    }
  }

  flush(session: Session): void {
    const turn = this.pending.get(session.id)
    this.pending.delete(session.id)
    let turns = 1
    for (const [model, usage] of turn ?? []) {
      if (usage.input + usage.cacheRead + usage.cacheWrite + usage.output <= 0) continue
      const home = homedir()
      const root = session.root.startsWith(home + '/') ? '~' + session.root.slice(home.length) : session.root
      this.service.record({ record: { time: this.service.now(), agent: session.agent,
        root, session: typeof session.info.handle === 'string' ? session.info.handle : null,
        ...(session.info.parent ? { child: true } : {}), model, turns,
        input: usage.input, cache_read: usage.cacheRead, cache_write: usage.cacheWrite, output: usage.output } })
      turns = 0
    }
  }
}
