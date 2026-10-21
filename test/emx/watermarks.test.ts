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

test('large ordered backlogs survive apply-before-ack and producer/owner restarts', () => {
  const dir = fs.mkdtempSync('/tmp/emx-watermarks-')
  const file = join(dir, 'outbox.json')
  try {
    const source = 'producer'
    const backlog = Array.from({ length: 10001 }, (_, i) => ({ id: 'entry-' + i, source, sequence: i + 1, method: 'record', params: { record: { agent: 'codex', input: 1 } } }))
    fs.writeFileSync(file, JSON.stringify({ source, sequence: backlog.length, entries: backlog }))
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

for (const failed of ['record', 'quota']) test(`a failed ${failed} blocks higher sequences and watermark acknowledgments`, () => {
  const dir = fs.mkdtempSync('/tmp/emx-gap-')
  const outbox = new Outbox(join(dir, 'outbox.json'))
  const owner = service(dir)
  try {
    for (let i = 1; i <= 7; i++) outbox.add(i === 5 ? failed as 'record' | 'quota' : 'record',
      i === 5 && failed === 'quota' ? { reading: { agent: 'codex', credits: 5 } } : { record: { input: i } })
    const deliver = (entry: any) => entry.method === 'record' ? owner.record({ ...entry.params, ...entry })
      : owner.quota(entry.params.reading, entry.id, entry.source, entry.sequence)
    for (const entry of outbox.entries.slice(0, 4)) { const ack = deliver(entry); outbox.ack(ack.source!, ack.sequence!) }
    const fifth = outbox.entries[0]
    // Real filesystem failure at the application boundary, not a mocked record().
    const blocked = failed === 'record' ? join(dir, 'ledger.jsonl') : join(dir, 'quotas.json')
    const backup = blocked + '.saved'
    if (fs.existsSync(blocked)) fs.renameSync(blocked, backup)
    fs.mkdirSync(blocked)
    assert.throws(() => deliver(fifth))
    assert.equal(owner.receipt(undefined, fifth.source).sequence, 4)
    fs.rmdirSync(blocked)
    if (fs.existsSync(backup)) fs.renameSync(backup, blocked)
    assert.throws(() => deliver(outbox.entries[1]), /sequence/i)
    for (const entry of [...outbox.entries]) { const ack = deliver(entry); outbox.ack(ack.source!, ack.sequence!) }
    assert.equal(outbox.entries.length, 0)
    assert.equal(owner.receipt(undefined, fifth.source).sequence, 7)
    const records = fs.readFileSync(join(dir, 'ledger.jsonl'), 'utf8').trim().split('\n').map((s) => JSON.parse(s))
    assert.equal(records.length, failed === 'record' ? 7 : 6)
    assert.equal(records.reduce((sum, r) => sum + r.input, 0), failed === 'record' ? 28 : 23)
  } finally { owner.stop(); fs.rmSync(dir, { recursive: true, force: true }) }
})
