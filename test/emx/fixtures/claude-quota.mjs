#!/usr/bin/env node
// Status/quota peer only. Unexpected commands fail rather than reaching a model.
import {appendFileSync, readFileSync} from 'node:fs'
const [file, ...args] = process.argv.slice(2)
const state = JSON.parse(readFileSync(file, 'utf8'))
appendFileSync(file + '.calls', JSON.stringify(args) + '\n')
let reply
if (JSON.stringify(args) === JSON.stringify(['auth', 'status', '--json'])) reply = state.auth
else if (JSON.stringify(args) === JSON.stringify(['-p', '/usage', '--output-format', 'json', '--no-session-persistence'])) reply = state.usage
else throw new Error('Unexpected fake Claude quota command')
if (!reply) throw new Error('Unexpected fake Claude quota probe')
if (reply.delay) await new Promise((resolve) => setTimeout(resolve, reply.delay))
process.stdout.write(typeof reply.out === 'string' ? reply.out : JSON.stringify(reply.out))
process.exit(reply.code ?? 0)
