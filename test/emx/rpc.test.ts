// rpc.test.ts --- after-write replies must not be assimilated as promises.

import './fixtures/environment.ts'
import type { Socket } from 'node:net'

import * as assert from 'node:assert/strict'
import { Duplex } from 'node:stream'
import { setImmediate as nextTick } from 'node:timers/promises'
import { test } from 'node:test'
import { Connection, Reply } from '../../emx/daemon/rpc.ts'

test('a synchronous Reply writes its result before its callback notifications', async () => {
  const written: any[] = []
  const socket = new Duplex({
    read() {},
    write(chunk, _encoding, done) {
      written.push(JSON.parse(chunk.toString()))
      done()
    },
  })
  const connection = new Connection(socket as Socket)
  connection.onRequest = () => new Reply({ replay: 'fresh' }, () => {
    connection.notify('block/add', { history: true })
  })
  socket.emit('data', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'session/attach', params: {} }) + '\n')
  await nextTick()
  assert.deepEqual(written, [
    { jsonrpc: '2.0', id: 1, result: { replay: 'fresh' } },
    { jsonrpc: '2.0', method: 'block/add', params: { history: true } },
  ])
  socket.destroy()
})

test('ordinary async request handlers still return their results', async () => {
  const written: any[] = []
  const socket = new Duplex({
    read() {},
    write(chunk, _encoding, done) {
      written.push(JSON.parse(chunk.toString()))
      done()
    },
  })
  const connection = new Connection(socket as Socket)
  connection.onRequest = async () => ({ id: 'session-1' })
  socket.emit('data', JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'session/open', params: {} }) + '\n')
  await nextTick()
  assert.deepEqual(written, [{ jsonrpc: '2.0', id: 2, result: { id: 'session-1' } }])
  socket.destroy()
})


test('pipelined requests write a synchronous Reply and afterWrite before the next handler', async () => {
  const written: any[] = []
  const socket = new Duplex({
    read() {},
    write(chunk, _encoding, done) {
      written.push(JSON.parse(chunk.toString()))
      done()
    },
  })
  const connection = new Connection(socket as Socket)
  connection.onRequest = (method) => {
    if (method === 'first') return new Reply({ first: true }, () => {
      connection.notify('history/done', { earlier: false })
    })
    connection.notify('second/event', {})
    return {}
  }
  socket.emit('data', ['first', 'second'].map((method, i) =>
    JSON.stringify({ jsonrpc: '2.0', id: i + 1, method, params: {} })).join('\n') + '\n')
  // Assert immediately: a synchronous handler must not yield to the next line.
  assert.deepEqual(written, [
    { jsonrpc: '2.0', id: 1, result: { first: true } },
    { jsonrpc: '2.0', method: 'history/done', params: { earlier: false } },
    { jsonrpc: '2.0', method: 'second/event', params: {} },
    { jsonrpc: '2.0', id: 2, result: {} },
  ])
  socket.destroy()
})
