// profiles.ts --- caller-specific MCP capabilities, independent of provider/model.
import type { Config, Profile } from '../config.ts'
import type { EditorTools } from './protocol.ts'
import type { Session } from './session.ts'

export function sessionProfile(session: Pick<Session, 'info'>): string {
  return typeof session.info.profile === 'string' ? session.info.profile : 'orchestrator'
}

export function toolPolicy(config: Config, name: string): NonNullable<Profile['tools']> {
  // Unknown persisted roles fail closed; legacy unprofiled sessions use orchestrator.
  const role = Object.hasOwn(config.profiles, name) ? config.profiles[name] : undefined
  if (!role) return { allow: name === 'orchestrator' ? '*' : [] }
  return role.tools ?? config.profiles.orchestrator?.tools ?? { allow: '*' }
}

export function delegationProfiles(config: Config, session: Pick<Session, 'info'>): string[] | undefined {
  const name = sessionProfile(session)
  // Inherited unrestricted policy must never enable legacy task nesting.
  if (session.info.parent && !config.profiles[name]?.tools?.delegate) return []
  return toolPolicy(config, name).delegate
}

export function profileTools(config: Config, session: Pick<Session, 'info'>, source: EditorTools): EditorTools {
  const policy = toolPolicy(config, sessionProfile(session))
  const tools = source.tools.filter((tool) => {
    if (tool.name === 'session_rate') return true
    if (policy.allow !== '*' && !policy.allow.includes(tool.name)) return false
    if (tool.name === 'session_ask' && session.info.parent) return false
    if (tool.name === 'session_start' && delegationProfiles(config, session)?.length === 0) return false
    return true
  }).map(({ name, description, inputSchema }) => ({ name, description, inputSchema }))
  return delegationTools({ tools, readOnly: source.readOnly.filter((name) => tools.some((tool) => tool.name === name)) })
}

/** Rating is available exactly when a caller can start a run. */
export function delegationTools(source: EditorTools): EditorTools {
  if (source.tools.some((tool) => tool.name === 'session_start')) return source
  return { tools: source.tools.filter((tool) => tool.name !== 'session_rate'),
    readOnly: source.readOnly.filter((name) => name !== 'session_rate') }
}
