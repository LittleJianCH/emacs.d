// session.test.ts --- backend-independent session state transitions.
import assert from 'node:assert/strict'
import test from 'node:test'
import { Session } from '../../emx/daemon/session.ts'

test('setStatus ignores repeated states without advancing events or notifying listeners', () => {
  let changes = 0
  let notifications = 0
  const session = new Session({ id: 'test', agent: 'echo', root: '',
    onChange: () => { changes++ } })
  session.notify = () => { notifications++ }
  for (const status of ['starting', 'running', 'running', 'idle', 'idle', 'exited', 'exited'] as const) {
    session.setStatus(status)
  }
  assert.equal(session.seq, 3)
  assert.equal(changes, 3)
  assert.equal(notifications, 3)
  assert.deepEqual(session.log.map((event) => event.type === 'status' && event.status),
    ['running', 'idle', 'exited'])
})

test('idle sessions hibernate and resume while children and pending asks keep their process', async () => {
  const { setTimeout: delay } = await import('node:timers/promises')
  const session = new Session({ id: 'hibernate', agent: 'echo', root: '', hibernateAfter: () => 0.03 })
  const child = new Session({ id: 'child', agent: 'echo', root: '', info: { parent: 'hibernate' }, hibernateAfter: () => 0.03 })
  const asking = new Session({ id: 'asking', agent: 'echo', root: '', hibernateAfter: () => 0.03 })
  try {
    await Promise.all([session.start(), child.start(), asking.start()])
    const ask = asking.ask({ type: 'approval', choices: ['allow', 'deny'] })
    await delay(80)
    assert.equal(session.backend.alive(), false)
    assert.equal(session.status, 'idle')
    assert.equal(child.backend.alive(), true)
    assert.equal(asking.backend.alive(), true)
    session.send('resume')
    await delay(5)
    assert.equal(session.backend.alive(), true)
    assert.ok(session.blocks.some((b) => b.type === 'text' && b.text === 'echo: resume'))
    asking.answer([...asking.asks.keys()][0], { choice: 'allow' }); await ask
    await delay(80)
    assert.equal(asking.backend.alive(), false)
  } finally { await Promise.all([session.stop(), child.stop(), asking.stop()]) }
})

test('queued mailbox metadata survives persistence and repeated user echoes cannot reveal hidden notes', async () => {
  const s = new Session({ id: 'mail', agent: 'echo', root: '' })
  await s.start(); s.setStatus('running')
  s.sendMessage('visible', '@child', 'hidden note', 'mail-block')
  const restored = new Session({ id: 'mail', agent: 'echo', root: '', restored: true, transcript: s.transcript() })
  try {
    await restored.start()
    await new Promise((resolve) => setImmediate(resolve))
    assert.deepEqual(restored.index.get('mail-block'), { id: 'mail-block', type: 'user', text: 'visible', origin: '@child' })
    restored.addBlock({ id: 'mail-block', type: 'user', text: 'visible\n\nhidden note' })
    restored.update('mail-block', { text: 'visible\n\nhidden note' })
    assert.equal((restored.index.get('mail-block') as any).text, 'visible')
  } finally { await s.stop(); await restored.stop() }
})
