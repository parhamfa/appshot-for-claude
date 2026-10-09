import { expect, test } from 'claude-code/testing'

import { chooseHandoff, formatAppshot, HANDOFF_WINDOW_MS, INLINE_CHARS, labelFor } from '../hooks/appshot-core'

const shot = {
  id: '20261007-120000-000-Safari',
  app: 'Safari',
  title: 'Pricing',
  txt: '/nowhere/window.txt',
  png: '/nowhere/window.png',
  url: 'https://example.com/pricing',
  chars: 1200,
  token: '',
}
shot.token = labelFor(shot)

test('the label names the app, the capture time and a short, bracket-free title', () => {
  expect(shot.token).toBe('Safari 12:00:00 — Pricing')
  expect(labelFor({ id: '20261007-213005-000-Notes', app: 'Notes', title: '' })).toBe('Notes 21:30:05')
  expect(labelFor({ ...shot, app: 'X', title: 'a [b] ' + 'y'.repeat(80) })).toBe(`X 12:00:00 — a  b  ${'y'.repeat(41)}…`)
})

test('the model gets the screenshot path and the window text, cut when long', () => {
  const block = formatAppshot(shot, 'Plans\nPro $20')
  expect(block).toContain('<appshot app="Safari" window="Pricing" url="https://example.com/pricing">')
  expect(block).toContain('Screenshot: /nowhere/window.png')
  expect(block).toContain('Window text:\nPlans\nPro $20')
  expect(formatAppshot({ ...shot, isPasted: true }, '')).toContain('pasted into the message as an image')

  const long = formatAppshot({ ...shot, png: undefined }, 'x'.repeat(INLINE_CHARS + 5))
  expect(long).toContain('No screenshot')
  expect(long).toContain(`first ${INLINE_CHARS} of ${INLINE_CHARS + 5} characters`)
})

// Delivery times for the handoff tests: `now` and a minute before it.
const now = 1_791_544_404_104
const fresh = now - 60_000

test('a prompt claims the newest pasted, unsent captures its own appshots do not explain', () => {
  const candidates = [
    { id: '20261009-141000-000-Safari', isPasted: true, isDone: false, deliveredAt: fresh },
    { id: '20261009-141200-000-Notes', isPasted: true, isDone: false, deliveredAt: fresh },
    { id: '20261009-141100-000-Mail', isPasted: true, isDone: false, deliveredAt: fresh },
  ]
  expect(chooseHandoff(candidates, 1, 0, now)).toEqual(['20261009-141200-000-Notes'])
  expect(chooseHandoff(candidates, 3, 1, now)).toEqual(['20261009-141200-000-Notes', '20261009-141100-000-Mail'])
  expect(chooseHandoff(candidates, 5, 0, now)).toEqual([
    '20261009-141200-000-Notes',
    '20261009-141100-000-Mail',
    '20261009-141000-000-Safari',
  ])
})

test('no spare image claims nothing', () => {
  const candidates = [{ id: '20261009-141000-000-Safari', isPasted: true, isDone: false, deliveredAt: fresh }]
  expect(chooseHandoff(candidates, 1, 1, now)).toEqual([])
  expect(chooseHandoff(candidates, 1, 2, now)).toEqual([])
  expect(chooseHandoff(candidates, 0, 0, now)).toEqual([])
})

test('captures not pasted or already done are never claimed', () => {
  const candidates = [
    { id: '20261009-141300-000-Notes', isPasted: false, isDone: false, deliveredAt: fresh },
    { id: '20261009-141200-000-Mail', isPasted: true, isDone: true, deliveredAt: fresh },
    { id: '20261009-141100-000-Safari', isPasted: true, isDone: false, deliveredAt: fresh },
  ]
  expect(chooseHandoff(candidates, 3, 0, now)).toEqual(['20261009-141100-000-Safari'])
  expect(chooseHandoff(candidates.slice(0, 2), 2, 0, now)).toEqual([])
})

test('a capture pasted more than 30 minutes ago stays with the session that holds it', () => {
  const atTheEdge = { id: '20261009-141200-000-Notes', isPasted: true, isDone: false, deliveredAt: now - HANDOFF_WINDOW_MS }
  const tooOld = { id: '20261009-141300-000-Mail', isPasted: true, isDone: false, deliveredAt: now - HANDOFF_WINDOW_MS - 1 }
  const unmarked = { id: '20261009-141400-000-Safari', isPasted: true, isDone: false, deliveredAt: 0 }
  expect(HANDOFF_WINDOW_MS).toBe(30 * 60_000)
  expect(chooseHandoff([tooOld, atTheEdge, unmarked], 3, 0, now)).toEqual(['20261009-141200-000-Notes'])
})

test('a prompt with no appshot waiting passes through untouched', async ($, on) => {
  let seen: { text: string; context?: readonly string[] } | undefined
  on('prompt.submit', ($, e) => {
    seen = { text: e.text, context: e.context }
    return { text: e.text, context: e.context }
  })

  await $.prompt.submit({ text: 'plain question', wait: false, origin: { kind: 'composer' } })

  expect(seen?.text).toBe('plain question')
  expect(seen?.context).toBeUndefined()
})
