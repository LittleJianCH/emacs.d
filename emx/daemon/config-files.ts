// config-files.ts --- local checkout file tools used by agents on other hosts.
import * as fs from 'node:fs/promises'
import { homedir } from 'node:os'
import * as path from 'node:path'
import { checkoutRoot } from './paths.ts'

const PATH_PARAM = {
  type: 'string',
  description: 'File path, relative to the Emacs configuration root or absolute inside it',
};

const CONFIG_METHODS = {
  config_read: {
    description: `Read a file of the Emacs configuration on the machine Emacs runs on, with
line numbers. Use it instead of your own file tools, which work on the project's host.`,
    inputSchema: {
      type: 'object',
      properties: {
        path: PATH_PARAM,
        offset: { type: 'integer', description: 'First line to read, default 1' },
        limit: { type: 'integer', description: 'Number of lines to read, default 2000' },
      },
      required: ['path'],
    },
  },
  config_edit: {
    description: `Replace an exact string in a file of the Emacs configuration on the
machine Emacs runs on. old_string must occur exactly once unless replace_all is set.
Fails if a buffer visiting the file has unsaved changes; a visiting buffer without
changes is reverted afterwards.`,
    inputSchema: {
      type: 'object',
      properties: {
        path: PATH_PARAM,
        old_string: { type: 'string', description: 'Text to replace, including whitespace' },
        new_string: { type: 'string', description: 'Replacement text' },
        replace_all: { type: 'boolean', description: 'Replace every occurrence' },
      },
      required: ['path', 'old_string', 'new_string'],
    },
  },
  config_write: {
    description: `Create or overwrite a file of the Emacs configuration on the machine
Emacs runs on. Prefer config_edit for changes to existing files. Fails if a buffer
visiting the file has unsaved changes; a visiting buffer without changes is reverted
afterwards.`,
    inputSchema: {
      type: 'object',
      properties: {
        path: PATH_PARAM,
        content: { type: 'string', description: 'The complete file content' },
      },
      required: ['path', 'content'],
    },
  },
};


export const configTools = Object.entries(CONFIG_METHODS).map(([name, m]) =>
  ({ name, description: m.description, inputSchema: m.inputSchema }))
export const configNames = configTools.map((tool) => tool.name)

export class ConfigFiles {
  #writes: Promise<unknown> = Promise.resolve()
  readonly root: string
  readonly buffer: (method: string, file: string) => Promise<unknown>
  constructor(buffer: ConfigFiles['buffer'], root = checkoutRoot) {
    this.root = root; this.buffer = buffer
  }
  async resolve(file: unknown): Promise<string> {
    if (typeof file !== 'string' || !file) throw new Error('path is required')
    if (file === '~' || file.startsWith('~/')) file = path.join(homedir(), file.slice(1))
    const root = await fs.realpath(this.root)
    let real = path.resolve(root, file as string)
    if (path.relative(root, real).split(path.sep)[0] === '.git') {
      throw new Error(`${file} is not a file in the Emacs configuration (${root})`)
    }
    const rest: string[] = []
    for (;;) {
      try { await fs.lstat(real); break }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        rest.unshift(path.basename(real)); real = path.dirname(real)
      }
    }
    real = path.join(await fs.realpath(real), ...rest)
    const rel = path.relative(root, real)
    if (!rel || rel === '..' || rel.startsWith('..' + path.sep) || path.isAbsolute(rel)
      || rel.split(path.sep)[0] === '.git') throw new Error(`${file} is not a file in the Emacs configuration (${root})`)
    return real
  }
  call(method: string, args: Record<string, any>): Promise<string> {
    if (method === 'config_read') return this.#call(method, args)
    // Legacy emx writes were synchronous. Keep read/modify/write operations
    // ordered when several remote agents edit through this one local writer.
    const result = this.#writes.then(() => this.#call(method, args))
    this.#writes = result.catch(() => {})
    return result
  }
  async #call(method: string, args: Record<string, any>): Promise<string> {
    const file = await this.resolve(args.path)
    if (method === 'config_read') {
      const lines = (await fs.readFile(file, 'utf8')).split('\n')
      if (lines.at(-1) === '') lines.pop()
      if (!lines.length) return '(empty file)'
      const start = Math.max(1, Number(args.offset) || 1), count = Math.max(1, Number(args.limit) || 2000)
      const out = lines.slice(start - 1, start - 1 + count).map((line, i) => `${String(start + i).padStart(6)}\t${line}`)
      if (start - 1 + count < lines.length) out.push(`... ${lines.length} lines in total; continue with offset ${start + count}`)
      return out.join('\n')
    }
    let content: string, count = 0
    if (method === 'config_edit') {
      const from = args.old_string, to = args.new_string
      if (typeof from !== 'string' || !from) throw new Error('old_string is required')
      if (typeof to !== 'string') throw new Error('new_string is required')
      if (from === to) throw new Error('old_string and new_string are the same')
      const parts = (await fs.readFile(file, 'utf8')).split(from)
      count = parts.length - 1
      if (!count) throw new Error(`old_string not found in ${file}`)
      if (count > 1 && args.replace_all !== true && args.replace_all !== 'true') throw new Error(`old_string occurs ${count} times in ${file}; add context to make it unique, or set replace_all`)
      content = parts.join(to)
    } else if (method === 'config_write') {
      if (typeof args.content !== 'string') throw new Error('content is required')
      content = args.content
    } else throw new Error(`Unknown config tool: ${method}`)
    if (await this.buffer('_config_modified', file)) throw new Error(`${file} has unsaved changes in Emacs; ask the user to save or revert it first`)
    await fs.mkdir(path.dirname(file), { recursive: true })
    await fs.writeFile(file, content)
    await this.buffer('_config_written', file).catch(() => {})
    const result = method === 'config_edit' ? `Edited ${file} (${count} ${count === 1 ? 'replacement' : 'replacements'})` : `Wrote ${file}`
    return result + (file.endsWith('.el') ? '. The running Emacs still has the old version: call reload once your edits are done.' : '')
  }
}
