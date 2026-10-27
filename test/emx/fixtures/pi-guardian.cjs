// Fake pi-auto-permissions guardian: asks about "guarded" commands only.
module.exports = function (pi) {
  pi.on('session_start', () => {})
  pi.on('tool_call', async (event, ctx) => {
    if (ctx.mode !== 'rpc') throw new Error('the context must pass through')
    if (event.input?.command !== 'guarded') return
    const choice = await ctx.ui.select('Guarded — Auto Permissions needs approval', ['Allow', 'Block'])
    if (choice !== 'Allow') return { block: true, reason: `guardian: ${choice}` }
  })
}
