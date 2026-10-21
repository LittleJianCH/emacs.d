// Thin Pi RPC bridge: emx owns policy and the editor owns all interaction.

module.exports = function (pi) {
  pi.registerMcpServer('emacs', {
    command: process.execPath,
    args: [process.env.EMX_PI_EMX, 'mcp'],
    env: { EMX_DAEMON_SOCKET: process.env.EMX_DAEMON_SOCKET, EMX_SESSION: process.env.EMX_SESSION },
    exposure: 'direct',
  })
  pi.on('tool_call', async (event, ctx) => {
    const choice = await ctx.ui.select('emx-approval ' + JSON.stringify({
      tool: event.toolName, id: event.toolCallId, input: event.input,
    }), ['allow', 'always', 'deny', 'deny-plan'])
    if (choice === 'allow' || choice === 'always') return
    return { block: true, reason: choice === 'deny-plan'
      ? 'You are in plan mode. Do not modify anything. Only read and propose a plan.'
      : 'The user declined this tool call.' }
  })
}
