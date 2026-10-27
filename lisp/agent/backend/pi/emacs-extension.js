// Thin Pi RPC bridge: emx owns policy and the editor owns all interaction.
// When emx answers review (Bash in auto mode), the vendored
// pi-auto-permissions guardian decides instead, asking through emx too.

const { join } = require('node:path')

/** Load the guardian against a view of PI that keeps its tool_call handlers. */
function loadGuardian(pi) {
  const handlers = []
  try {
    const module = require(process.env.EMX_PI_GUARDIAN ?? join(__dirname, 'auto-permissions/index.ts'))
    ;(module.default ?? module)(new Proxy(pi, {
      get(target, key) {
        if (key === 'on') {
          return (event, handler) => event === 'tool_call' ? handlers.push(handler) : target.on(event, handler)
        }
        const value = Reflect.get(target, key)
        return typeof value === 'function' ? value.bind(target) : value
      },
    }))
    return { handlers }
  } catch (error) {
    return { handlers, error }
  }
}

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
  const guardian = loadGuardian(pi)
  let reported = false
  pi.on('tool_call', async (event, ctx) => {
    if (guardian.error && !reported) {
      reported = true
      ctx.ui.notify?.(`Bash review is unavailable: ${guardian.error.message ?? guardian.error}`, 'error')
    }
    const choice = await ctx.ui.select('emx-approval ' + JSON.stringify({
      tool: event.toolName, id: event.toolCallId, input: event.input, review: !guardian.error,
    }), ['allow', 'always', 'deny', 'deny-plan', 'review'])
    if (choice === 'review') {
      const review = reviewContext(ctx, event)
      for (const handler of guardian.handlers) {
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
