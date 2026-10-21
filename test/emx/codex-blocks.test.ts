// codex-blocks.test.ts --- repeated backend blocks keep every session view equal.
import assert from 'node:assert/strict'
import test from 'node:test'
import { Session } from '../../emx/daemon/session.ts'
import type { Block, EventParams } from '../../emx/daemon/protocol.ts'

function apply(events: EventParams[]): Block[] {
  const blocks: Block[] = []
  for (const event of events) {
    if (event.type === 'block/add') {
      assert.ok(!blocks.some((block) => block.id === event.block.id), 'stream adds each id once')
      blocks.push(structuredClone(event.block))
    } else if (event.type === 'block/update') {
      const index = blocks.findIndex((block) => block.id === event.id)
      assert.ok(index >= 0)
      blocks[index] = { ...blocks[index], ...event.fields } as Block
    }
  }
  return blocks
}

function assertViews(session: Session, live: EventParams[]): void {
  const blocks = apply(live)
  assert.deepEqual(blocks, session.blocks)
  const replay: EventParams[] = []
  session.notify = (event) => replay.push(event)
  const attached = session.attach({ epoch: session.epoch, seq: 0 })
  assert.equal(attached.result.replay, 'events')
  attached.afterWrite()
  assert.deepEqual(replay, live)
  assert.deepEqual(apply(replay), blocks)
  const fresh: EventParams[] = []
  session.notify = (event) => fresh.push(event)
  const snapshot = session.attach()
  assert.equal(snapshot.result.replay, 'fresh')
  assert.equal(snapshot.result.seq, session.seq)
  snapshot.afterWrite()
  assert.deepEqual(apply(fresh), blocks)
}

test('identical block/add repeats do not advance seq, log, broadcast or persistence', () => {
  let changes = 0
  const session = new Session({ id: 'blocks', agent: 'echo', root: '', onChange: () => changes++ })
  const live: EventParams[] = []
  session.notify = (event) => live.push(event)
  const block: Block = { id: 'tool', type: 'tool', status: 'running',
    view: { kind: 'command', name: 'sh', title: 'echo hi', command: 'echo hi' } }
  session.addBlock(block)
  session.addBlock(structuredClone(block))
  session.emit({ type: 'block/add', block: structuredClone(block), before: 'other', history: true })
  assert.equal(session.seq, 1)
  assert.equal(session.log.length, 1)
  assert.equal(live.length, 1)
  assert.equal(changes, 1)
  assertViews(session, live)
})

test('changed block/add repeats become updates of changed fields in every session view', () => {
  const session = new Session({ id: 'blocks', agent: 'echo', root: '' })
  const live: EventParams[] = []
  session.notify = (event) => live.push(event)
  const block: Block = { id: 'tool', type: 'tool', status: 'running',
    view: { kind: 'command', name: 'sh', title: 'echo hi', command: 'echo hi' } }
  session.addBlock(block)
  session.addBlock({ ...structuredClone(block), status: 'done', output: 'hi' })
  session.addBlock({ ...structuredClone(block), status: 'done', output: 'hi' })
  assert.equal(session.seq, 2)
  assert.deepEqual(live[1], { type: 'block/update', id: 'tool',
    fields: { status: 'done', output: 'hi' }, session: session.id, seq: 2 })
  assert.equal(session.index.get('tool')?.type, 'tool')
  assertViews(session, live)
})
