export type Appshot = {
  id: string
  app: string
  title: string
  txt: string
  png?: string
  /** The screenshot was pasted into the prompt box as an image. */
  isPasted?: boolean
  url?: string
  chars: number
  /** The label the band shows: "Safari 22:04:34 — Pricing". */
  token: string
}

declare module 'claude-code' {
  interface PluginState {
    'appshot-for-claude': { pending: Appshot[]; shown: string | null }
  }
}
