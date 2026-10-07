import { expect, test } from 'claude-code/testing'

import { formatAppshot, INLINE_CHARS, labelFor } from '../hooks/appshot-core'

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
