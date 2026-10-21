// lock.ts --- publish complete locks and serialize stale-lock reclamation.

import { randomUUID } from 'node:crypto'
import { linkSync, mkdirSync, readFileSync, rmdirSync, statSync,
  unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'

function readLock(file: string): string | undefined {
  try { return readFileSync(file, 'utf8') } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    return undefined
  }
}

function lockPid(content: string): number | undefined {
  try {
    const value = JSON.parse(content)
    // Also recognize locks written by the previous daemon version.
    const pid = typeof value === 'number' ? value : value?.pid
    if (Number.isSafeInteger(pid) && pid > 0 && pid <= 2 ** 31 - 1) return pid
  } catch {}
  return undefined
}

function alive(pid: number | undefined): boolean {
  if (pid === undefined) return false
  try { process.kill(pid, 0); return true } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'EPERM') return true
    if (code === 'ESRCH') return false
    throw error
  }
}

/** Acquire a state-directory lock; return a release function for its owner. */
export async function acquireLock(dir: string): Promise<() => void> {
  const file = join(dir, 'daemon.lock')
  const reclaim = `${file}.reclaim`
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`
  const deadline = Date.now() + 2000
  writeFileSync(temp, JSON.stringify({ pid: process.pid, started: Date.now() }) + '\n',
    { flag: 'wx', mode: 0o600 })
  try {
    for (;;) {
      try {
        // A hard link publishes the already-written inode atomically.
        linkSync(temp, file)
        return () => {
          const current = readLock(file)
          if (current !== undefined && lockPid(current) === process.pid) unlinkSync(file)
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      }
      const previous = readLock(file)
      if (previous !== undefined && alive(lockPid(previous))) {
        throw new Error(`Another daemon owns this state directory: ${file}`)
      }
      if (Date.now() >= deadline) throw new Error(`Timed out reclaiming daemon lock: ${file}`)
      if (previous === undefined) continue
      try {
        mkdirSync(reclaim, { mode: 0o700 })
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
        try {
          if (Date.now() - statSync(reclaim).mtimeMs > 10_000) {
            rmdirSync(reclaim)
            continue
          }
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        }
        await delay(50)
        continue
      }
      try {
        // Re-read under the reclaim mutex: a starter may have replaced it.
        const current = readLock(file)
        if (current === previous && !alive(lockPid(current))) unlinkSync(file)
      } finally {
        rmdirSync(reclaim)
      }
    }
  } finally {
    unlinkSync(temp)
  }
}
