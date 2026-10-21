// Every test daemon and its descendants resolve model commands to fixtures.
import { delimiter } from 'node:path'
import { fileURLToPath } from 'node:url'
const bin = fileURLToPath(new URL('./bin/', import.meta.url))
process.env.PATH = bin + delimiter + (process.env.PATH ?? '')
