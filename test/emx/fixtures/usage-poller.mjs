#!/usr/bin/env node
// Quota protocol peers: no credentials, model calls or editor access.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
const source = process.argv[2]
if (source !== 'pi' && process.argv[3] && !process.argv[3].startsWith('-') && process.argv[3] !== 'app-server') {
  appendFileSync(process.argv[3], source + '\n')
}
if (source === 'pi') {
  if (JSON.stringify(process.argv.slice(3)) !== JSON.stringify(['auth', 'print-api-key', '--provider', 'opencode-go'])) {
    throw new Error('Unexpected Pi quota arguments')
  }
  process.stdout.write('  fake-go-key\n')
} else if (source === 'claude') {
  console.log(JSON.stringify({result: 'Current session: 25% used'}))
} else {
  createInterface({input: process.stdin}).on('line', (line) => {
    const message = JSON.parse(line)
    if (message.id === undefined) return
    let result = {}
    if (message.method === 'balance') result = {balances: [{total: '9.03', currency: 'CNY'}]}
    if (message.method === 'account/rateLimits/read') result = {
      rateLimits: {primary: {usedPercent: 30, windowDurationMins: 300, resetsAt: 2000000000},
        credits: {unlimited: true}, planType: 'plus'} }
    console.log(JSON.stringify({id: message.id, result}))
  })
}
