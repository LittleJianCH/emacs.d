// Thin Pi RPC bridge: emx owns policy and the editor owns all interaction.
// When emx answers review (auto mode), the guardian guardian.ts loaded
// decides instead, asking through emx too.

/** CTX whose ui.select becomes an emx-review approval of EVENT. */
function reviewContext(ctx, event) {
  const select = async (title, _options, options) => {
    const choice = await ctx.ui.select('emx-review ' + JSON.stringify({
      tool: event.toolName, id: event.toolCallId, input: event.input, reason: title,
    }), ['allow', 'deny'], options)
    return choice === undefined ? undefined : choice === 'allow' ? 'Allow' : 'Block'
  }
  const bound = (target, key) => {
    const value = Reflect.get(target, key)
    return typeof value === 'function' ? value.bind(target) : value
  }
  const ui = new Proxy(ctx.ui, { get: (target, key) => key === 'select' ? select : bound(target, key) })
  return new Proxy(ctx, { get: (target, key) => key === 'ui' ? ui : bound(target, key) })
}

module.exports = function (pi) {
  pi.registerMcpServer('emacs', {
    command: process.execPath,
    args: [process.env.EMX_PI_EMX, 'mcp'],
    env: { EMX_DAEMON_SOCKET: process.env.EMX_DAEMON_SOCKET, EMX_SESSION: process.env.EMX_SESSION },
    exposure: 'direct',
  })
  let reported = false
  pi.on('tool_call', async (event, ctx) => {
    const guardian = globalThis[Symbol.for('emx.pi.guardian')]
    if (guardian?.error && !reported) {
      reported = true
      ctx.ui.notify?.(`Auto review is unavailable: ${guardian.error.message ?? guardian.error}`, 'error')
    }
    const choice = await ctx.ui.select('emx-approval ' + JSON.stringify({
      tool: event.toolName, id: event.toolCallId, input: event.input,
      review: event.toolName === 'bash' ? guardian?.handlers.length > 0 : Boolean(guardian?.review),
    }), ['allow', 'always', 'deny', 'deny-plan', 'review'])
    if (choice === 'review') {
      const review = reviewContext(ctx, event)
      // Bash goes through the guardian's gates; other tools to its reviewer.
      for (const handler of event.toolName === 'bash' ? guardian?.handlers ?? [] : [guardian?.review].filter(Boolean)) {
        const result = await handler(event, review)
        if (result?.block) return result
      }
      return
    }
    if (choice === 'allow' || choice === 'always') return
    return { block: true, reason: choice === 'deny-plan'
      ? 'You are in plan mode. Do not modify anything. Only read and propose a plan.'
      : 'The user declined this tool call.' }
  })
}
