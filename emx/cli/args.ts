// args.ts --- positional, flag, JSON-file and stdin arguments for bare commands.
import * as fs from 'node:fs'

// Maps positional arguments to parameter names; other parameters use --key value.
const POSITIONAL: Record<string, string[]> = {
  open: ['path', 'line', 'end_line'],
  show: ['path'],
  eval: ['code'],
  notify: ['message'],
  read_buffer: ['name', 'start_line', 'end_line'],
  diagnostics: ['path'],
  session_read: ['session', 'last'],
  session_ask: ['prompt'],
}

// These methods take structured data: the positional argument is a JSON file (or - for
// stdin) whose contents are merged into the parameters.
const JSON_INPUT = new Set(['render', 'patch'])

export function parseArgs(method: string, argv: string[]): Record<string, unknown> {
  const params: Record<string, unknown> = {}
  const positional: string[] = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg.startsWith('--') && arg.length > 2) {
      const [key, inline] = arg.slice(2).split(/=(.*)/s)
      params[key.replace(/-/g, '_')] = inline !== undefined ? inline : argv[++i]
    } else {
      positional.push(arg)
    }
  }
  if (JSON_INPUT.has(method) && positional.length) {
    const source = positional[0] === '-' ? 0 : positional[0]
    return { ...JSON.parse(fs.readFileSync(source, 'utf8')), ...params }
  }
  (POSITIONAL[method] || []).forEach((key, i) => {
    if (positional[i] !== undefined && params[key] === undefined) params[key] = positional[i]
  })
  // "-" means read the content from stdin.
  if (params.path === '-') {
    delete params.path
    params.content = fs.readFileSync(0, 'utf8')
  }
  return params
}
