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
