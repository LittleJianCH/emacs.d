// On-disk formats retained from emx serve; input excludes cached tokens.
export interface UsageRecord {
  time: number
  agent: string
  root?: string | null
  session?: string | null
  model?: string | null
  child?: boolean
  turns?: number
  input?: number
  cache_read?: number
  cache_write?: number
  output?: number
  [key: string]: any
}
export interface UsageWindow {
  id: string
  label?: string
  minutes?: number | null
  used?: number
  limited?: boolean
  resets?: number | null
  history?: number[][]
  [key: string]: any
}
export interface QuotaReading {
  agent: string
  host?: string | null
  windows?: UsageWindow[]
  balance?: {amount: number, currency: string}[]
  plan?: string
  credits?: number | 'unlimited'
  [key: string]: any
}
export interface QuotaEntry extends QuotaReading {
  time?: number
  windows: UsageWindow[]
}
export interface ReportParams {
  range?: string
  filter?: Record<string, unknown>
  withoutCache?: boolean
  now?: number
}
