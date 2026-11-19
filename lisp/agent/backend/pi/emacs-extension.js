// Thin Pi RPC bridge: emx owns policy and the editor owns all interaction.

const COMMUNICATION_RULES = `## Task communication
- Communicate with the task giver. As a subagent, report to the parent agent; your final result goes to the parent, with no requirement to address the end user directly.
- Before substantial tool work, briefly state what you will do.
- During long tasks, give brief progress updates with meaningful findings, phase changes, or blockers, aiming for about every 60 seconds when able to reply. Do not promise updates while blocked waiting for tools or the network.
- Use ordinary assistant text for progress; thinking is not a progress update. Do not narrate every tool call.
- Finish with the result, relevant validation, and remaining limitations. If unsuccessful, state what was completed, what remains incomplete, and why.`

module.exports = function (pi) {
  // Pi 1.3.0 supplies the current chained prompt for each run. Keep it intact,
  // without caching a prior turn's prompt or adding conversation messages.
  pi.on('before_agent_start', (event) => ({
    systemPrompt: event.systemPrompt.includes(COMMUNICATION_RULES)
      ? event.systemPrompt : event.systemPrompt + '\n\n' + COMMUNICATION_RULES,
  }))
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
