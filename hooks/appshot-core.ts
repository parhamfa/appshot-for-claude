import type { Appshot } from '../types'

export const INLINE_CHARS = 90_000

// The band's label for a capture: app, time and a short title.
export function labelFor(shot: Pick<Appshot, 'id' | 'app' | 'title'>): string {
  const clean = shot.title.replace(/[\[\]\n]/g, ' ').trim()
  const short = clean.length > 48 ? `${clean.slice(0, 47)}…` : clean
  const time = `${shot.id.slice(9, 11)}:${shot.id.slice(11, 13)}:${shot.id.slice(13, 15)}`
  return `${shot.app} ${time}${short ? ` — ${short}` : ''}`
}

// The block the model reads beside the prompt.
export function formatAppshot(shot: Appshot, text: string): string {
  const isCut = text.length > INLINE_CHARS
  return [
    `<appshot app="${shot.app}" window="${shot.title}"${shot.url ? ` url="${shot.url}"` : ''}>`,
    'The user captured this window with the Appshot hotkey and attached it to their message.',
    shot.png === undefined
      ? 'No screenshot: Screen Recording permission is missing for Claude.'
      : shot.isPasted
        ? `Screenshot: ${shot.png} (pasted into the message as an image; if no image came with it, view it with the Read tool)`
        : `Screenshot: ${shot.png} (view it with the Read tool before answering)`,
    shot.chars === 0
      ? 'The app exposes no text to accessibility: the screenshot is all there is.'
      : `Full window text, from the accessibility tree, including content scrolled out of view: ${shot.txt}`,
    isCut ? `Window text (first ${INLINE_CHARS} of ${text.length} characters):` : 'Window text:',
    isCut ? text.slice(0, INLINE_CHARS) : text,
    '</appshot>',
  ].join('\n')
}

export type HandoffCandidate = { id: string; isPasted: boolean; isDone: boolean }

/** Which waiting captures a prompt carrying `imageCount` images claims: the newest pasted, undone ones, as many as the images not already accounted for by the session's own pasted captures. */
export function chooseHandoff(candidates: readonly HandoffCandidate[], imageCount: number, ownPastedCount: number): string[] {
  const spare = Math.max(0, imageCount - ownPastedCount)
  // Ids start with the capture time (YYYYMMDD-HHMMSS-mmm), so string order is time order.
  return candidates
    .filter(one => one.isPasted && !one.isDone)
    .map(one => one.id)
    .sort((a, b) => (a < b ? 1 : a > b ? -1 : 0))
    .slice(0, spare)
}
