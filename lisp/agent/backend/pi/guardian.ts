// Loads the vendored pi-auto-permissions guardian (auto-permissions/) for
// emacs-extension.js, which runs its tool_call handlers only when emx answers
// review.  Pi loads this file itself, so the guardian's imports resolve to
// Pi's own packages.  A guardian that fails to load records its error instead
// of stopping Pi, and Bash goes back to emx's own auto policy.

export default async function (pi: any): Promise<void> {
  const guardian: { handlers: Function[], error?: unknown } = { handlers: [] }
  ;(globalThis as any)[Symbol.for('emx.pi.guardian')] = guardian
  try {
    const { default: factory } = await import(process.env.EMX_PI_GUARDIAN ?? './auto-permissions/index.ts')
    await factory(new Proxy(pi, {
      get(target, key) {
        if (key === 'on') {
          return (event: string, handler: Function) => event === 'tool_call'
            ? guardian.handlers.push(handler) : target.on(event, handler)
        }
        const value = Reflect.get(target, key)
        return typeof value === 'function' ? value.bind(target) : value
      },
    }))
  } catch (error) {
    guardian.handlers.length = 0
    guardian.error = error
  }
}
