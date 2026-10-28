// Loads the vendored pi-auto-permissions guardian (auto-permissions/) for
// emacs-extension.js, which runs it only when emx answers review in auto
// mode.  Bash goes to the guardian's own tool_call handlers; every other call
// emx would ask about goes to `review' below, which reuses the guardian's
// evidence, prompt, verdicts and reviewer model, so Pi's auto mode reviews
// all tools like Claude Code's and Codex's.  Pi loads this file itself, so
// the guardian's imports resolve to Pi's own packages.  A guardian that fails
// to load records its error instead of stopping Pi, and emx asks as before.

import { randomUUID } from 'node:crypto'

type Handler = (event: any, ctx: any) => Promise<{ block: true, reason: string } | undefined>

/** Text the reviewer reads for the parts of a request too long to matter. */
const LIMIT = 2000

const NON_SHELL = `

The latest request may also be a file write or edit, possibly outside the project, or an editor tool call (names starting with mcp__, such as eval running Emacs Lisp in the user's editor). Judge its exact target and payload with the same risk levels and decision table: a shell command's rules about what it executes apply to what such a call writes or runs.`

/** INPUT with long strings cut, keeping what identifies the action. */
function compact(input: unknown): unknown {
  if (typeof input === 'string') {
    return input.length > LIMIT ? input.slice(0, LIMIT) + `… [${input.length - LIMIT} more characters]` : input
  }
  if (Array.isArray(input)) return input.map(compact)
  if (input && typeof input === 'object') {
    return Object.fromEntries(Object.entries(input).map(([key, value]) => [key, compact(value)]))
  }
  return input
}

const text = (content: readonly any[]): string =>
  content.filter((part) => part?.type === 'text' && typeof part.text === 'string').map((part) => part.text).join('\n')

/** A tool_call handler reviewing any call with the guardian's model.
 * DEPS supplies the guardian's review module, its config loader and Pi's
 * completeSimple, so tests can stand in for Pi. */
export function reviewer(deps: { review: any, loadConfig: () => any, complete: Function }): Handler {
  // OpenCode Go routes by session; one per Pi process also keeps its cache.
  const sessionId = `emx-review-${randomUUID()}`
  return async (event, ctx) => {
    const label = `${event.toolName} call`
    const ask = async (reason: string) => {
      const choice = await ctx.ui.select(`${label} — Auto Permissions needs approval\n\n${reason}`,
        ['Allow', 'Block'], { signal: ctx.signal })
      return choice === 'Allow' ? undefined : { block: true as const, reason: 'Blocked by user' }
    }
    let verdict: { decision: string, reason: string }
    try {
      const config = deps.loadConfig()
      const model = config.reviewer
        ? ctx.modelRegistry.find(config.reviewer.provider, config.reviewer.model) : ctx.model
      if (!model) throw new Error('review model not found')
      const records = deps.review.collectReviewEvidence(ctx.sessionManager.buildContextEntries(), event.toolCallId)
      const request = { tool: event.toolName, input: compact(event.input ?? {}), cwd: ctx.cwd,
        gate: label, group: 'tools' }
      // Keep the latest evidence within half the reviewer's context.
      const budget = (model.contextWindow ?? 128000) * 2
      while (records.length && deps.review.buildReviewEnvelope(records, request, 'full').length > budget) records.shift()
      const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model)
      if (!auth.ok) throw new Error(auth.error)
      const signal = AbortSignal.any([AbortSignal.timeout(config.reviewer?.timeoutMs ?? 30000),
        ...(ctx.signal ? [ctx.signal] : [])])
      const response = await deps.complete(model, {
        systemPrompt: config.systemPrompt + NON_SHELL,
        messages: [{ role: 'user', timestamp: Date.now(),
          content: [{ type: 'text', text: deps.review.buildReviewEnvelope(records, request, 'full') }] }],
      }, { apiKey: auth.apiKey, headers: auth.headers, env: auth.env, signal,
        reasoning: config.reviewer?.reasoningEffort ?? 'low', sessionId, cacheRetention: 'long' })
      if (response.stopReason === 'aborted' || signal.aborted) throw new Error('review timed out or was cancelled')
      if (response.stopReason === 'error') throw new Error(response.errorMessage ?? 'reviewer request failed')
      verdict = deps.review.parsePermissionVerdict(text(response.content))
    } catch (error) {
      if (ctx.signal?.aborted) return { block: true, reason: 'Auto Permissions review cancelled' }
      return ask(`Automatic review failed: ${error instanceof Error ? error.message : String(error)}`)
    }
    if (verdict.decision === 'approve') return undefined
    if (verdict.decision === 'revise') {
      return { block: true, reason: `Auto Permissions requested revision: ${verdict.reason}\nRevise the call and try again.` }
    }
    return ask(verdict.reason)
  }
}

export default async function (pi: any): Promise<void> {
  const guardian: { handlers: Handler[], review?: Handler, error?: unknown } = { handlers: [] }
  ;(globalThis as any)[Symbol.for('emx.pi.guardian')] = guardian
  try {
    const { default: factory } = await import(process.env.EMX_PI_GUARDIAN ?? './auto-permissions/index.ts')
    await factory(new Proxy(pi, {
      get(target, key) {
        if (key === 'on') {
          return (event: string, handler: Handler) => event === 'tool_call'
            ? guardian.handlers.push(handler) : target.on(event, handler)
        }
        const value = Reflect.get(target, key)
        return typeof value === 'function' ? value.bind(target) : value
      },
    }))
    if (!process.env.EMX_PI_GUARDIAN) {
      const [review, config, { completeSimple }] = await Promise.all([
        import('./auto-permissions/review.ts'), import('./auto-permissions/config.ts'),
        import('@earendil-works/pi-ai/compat')])
      guardian.review = reviewer({ review, loadConfig: config.loadAutoPermissionsConfig, complete: completeSimple })
    }
  } catch (error) {
    guardian.handlers.length = 0
    guardian.review = undefined
    guardian.error = error
  }
}
