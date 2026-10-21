import { test } from 'node:test'
import * as assert from 'node:assert/strict'
import * as fs from 'node:fs'
import { join } from 'node:path'
import { UsageService } from '../../emx/usage/service.ts'
import { Outbox } from '../../emx/remote/outbox.ts'

function service(dir: string) {
  const usage = new UsageService()
  usage.initialize({ usageFile: join(dir, 'ledger.jsonl'), quotaFile: join(dir, 'quotas.json') })
  return usage
}

test('backlogs beyond old receipt caches survive apply-before-ack and producer/owner restarts', () => {
  const dir = fs.mkdtempSync('/tmp/emx-watermarks-')
  const file = join(dir, 'outbox.json')
  try {
    // Migrate a legacy producer backlog, preserving its receipt ids.
    const backlog = Array.from({ length: 10001 }, (_, i) => ({ id: 'old-' + i, method: 'record', params: { record: { agent: 'codex', input: 1 } } }))
    fs.writeFileSync(file, JSON.stringify(backlog))
    let outbox = new Outbox(file); outbox.restore()
    let owner = service(dir)
    const deliver = () => {
      for (const entry of outbox.entries as any[]) {
        if (entry.method === 'record') owner.record({ ...entry.params, id: entry.id, source: entry.source, sequence: entry.sequence })
        else (owner.quota as any)(entry.params.reading, entry.id, entry.source, entry.sequence)
      }
    }
    deliver(); owner.stop()
    fs.rmSync(join(dir, 'ledger.jsonl.watermarks.json'), { force: true })
    outbox = new Outbox(file); outbox.restore(); owner = service(dir)
    deliver()
    assert.equal(fs.readFileSync(join(dir, 'ledger.jsonl'), 'utf8').trim().split('\n').length, 10001)
    ;(owner.record as any)({ source: (outbox.entries[0] as any).source, sequence: 1, id: 'different-id', record: { input: 100 } })
    assert.equal(fs.readFileSync(join(dir, 'ledger.jsonl'), 'utf8').trim().split('\n').length, 10001)
    const last: any = outbox.entries.at(-1)
    assert.ok(last.source); assert.equal(last.sequence, 10001)
    ;(outbox.ack as any)(last.source, last.sequence)
    outbox = new Outbox(file); outbox.restore()
    assert.equal(outbox.entries.length, 0)
    for (let i = 0; i < 130; i++) outbox.add('quota', { reading: { agent: 'codex', time: i + 1, credits: i } })
    deliver(); owner.stop(); fs.rmSync(join(dir, 'ledger.jsonl.watermarks.json')); owner = service(dir)
    deliver()
    assert.equal(JSON.parse(fs.readFileSync(join(dir, 'quotas.json'), 'utf8'))[0].credits, 129)
    const fresh: any = outbox.entries.at(-1)
    assert.equal(fresh.source, last.source); assert.equal(fresh.sequence, 10131)
    // A stale unique receipt below the watermark must also be ignored.
    ;(owner.quota as any)({ agent: 'codex', credits: -1 }, 'new-id', fresh.source, fresh.sequence - 1)
    assert.equal(JSON.parse(fs.readFileSync(join(dir, 'quotas.json'), 'utf8'))[0].credits, 129)
    ;(outbox.ack as any)(fresh.source, fresh.sequence)
    outbox = new Outbox(file); outbox.restore(); outbox.add('record', { record: { input: 2 } })
    assert.equal((outbox.entries[0] as any).sequence, 10132)
    owner.stop()
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('migration recognizes all legacy ledger ids, including receipts older than 10000', () => {
  const dir = fs.mkdtempSync('/tmp/emx-receipt-migrate-')
  try {
    fs.writeFileSync(join(dir, 'ledger.jsonl'), Array.from({ length: 10002 }, (_, i) => JSON.stringify({ id: 'legacy-' + i, time: 1, agent: 'codex', input: 1 })).join('\n') + '\n')
    let owner = service(dir)
    ;(owner.record as any)({ id: 'legacy-0', source: 'migrated', sequence: 1, record: { input: 1 } })
    owner.stop(); owner = service(dir)
    ;(owner.record as any)({ id: 'new-id', source: 'migrated', sequence: 1, record: { input: 1 } })
    assert.equal(fs.readFileSync(join(dir, 'ledger.jsonl'), 'utf8').trim().split('\n').length, 10002)
    owner.stop()
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
