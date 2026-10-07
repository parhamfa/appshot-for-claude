import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Appshot } from '../types'

import { formatAppshot, labelFor } from './appshot-core'

// Press both Command keys anywhere on the Mac: a helper captures the front
// window (screenshot + accessibility text) into ~/.claude/appshots/captures,
// addressed to the session the person last sent a prompt from. That session
// pastes the screenshot into its composer and holds the text as a pending
// appshot, listed in a band above the composer with a "Show text" button
// each; the next prompt the person sends carries every pending text, and the
// band goes. Pressed over Claude itself, the hotkey takes the app used before
// Claude.

const pending = atom({ plugin: 'appshot-for-claude', key: 'pending' } as const, [])
const shown = atom({ plugin: 'appshot-for-claude', key: 'shown' } as const, null)

// State outlives a reload: a value an earlier version of this mod stored
// under `pending` (null, one appshot) is read as a list all the same.
function asList(value: unknown): Appshot[] {
  if (Array.isArray(value)) return value as Appshot[]
  return value && typeof value === 'object' ? [value as Appshot] : []
}

const PERSON = new Set(['composer', 'sdk', 'bridge'])
const CLAUDE_DESKTOP = 'com.anthropic.claudefordesktop'
const TEXT_PANE = 'appshot-text'
const PANE_CHARS = 60_000

type Meta = Omit<Appshot, 'token'> & { target?: string }

// Terminal apps by TERM_PROGRAM, to bring the right one forward on capture.
const TERMINALS: Record<string, string> = {
  Apple_Terminal: 'com.apple.Terminal',
  'iTerm.app': 'com.googlecode.iterm2',
  ghostty: 'com.mitchellh.ghostty',
  WezTerm: 'com.github.wez.wezterm',
  vscode: 'com.microsoft.VSCode',
}

// Module values; a reload starts them over, which is fine for all of them.
const s = {
  root: '',
  sessionId: '',
  lastSeen: '',
  isHost: false,
  isPolling: false,
  helperState: 'starting',
  hasWarned: false,
}

function captures() {
  return `${s.root}/captures`
}
function binary() {
  return `${s.root}/bin/appshot-helper`
}

async function markActive($: EngineInterface) {
  const cwd = await $.session.cwd()
  await $.fs.write(`${s.root}/active.json`, JSON.stringify({ sessionId: s.sessionId, cwd, at: await $.clock.now() }))
}

async function ensureBinary($: EngineInterface): Promise<boolean> {
  const source = `${$.plugin.root}/helper/appshot-helper.swift`
  if (await $.fs.exists(binary())) {
    const [built, written] = await Promise.all([$.fs.stat(binary()), $.fs.stat(source)])
    if (built.mtimeMs >= written.mtimeMs) return true
  }
  s.helperState = 'compiling the helper'
  // Several sessions may compile at once: build aside, then move into place.
  const scratch = `${binary()}.${s.sessionId}`
  await $.process.run(['/bin/mkdir', '-p', `${s.root}/bin`])
  const built = await $.process.run(['/usr/bin/swiftc', '-O', source, '-o', scratch], { timeoutMs: 300_000 })
  if (built.exitCode !== 0) {
    s.helperState = `compile failed: ${built.stderr.slice(0, 400)}`
    $.ui.toast('Appshot: the helper did not compile; run /appshot for details')
    return false
  }
  await $.process.run(['/bin/mv', '-f', scratch, binary()])
  return true
}

function onHelperLine($: EngineInterface, line: string) {
  let event: Record<string, unknown>
  try {
    event = JSON.parse(line)
  } catch {
    return
  }
  if (event.event === 'busy') {
    s.helperState = 'another session hosts the hotkey'
  } else if (event.event === 'ready') {
    s.isHost = true
    const missing = [
      event.accessibility === false || event.hotkey === false ? 'Accessibility' : '',
      event.screenRecording === false ? 'Screen Recording' : '',
    ].filter(Boolean)
    s.helperState = missing.length
      ? `listening, but missing ${missing.join(' and ')} permission`
      : 'listening for both Command keys'
    if (missing.length && !s.hasWarned) {
      s.hasWarned = true
      $.ui.toast(
        `Appshot: allow Claude under System Settings → Privacy & Security → ${missing.join(' and ')}`,
        { timeoutMs: 12_000 },
      )
    }
  } else if (event.event === 'error' && event.reason === 'text-timeout') {
    $.ui.toast('Appshot: that app did not answer for its text; using the screenshot alone')
  } else if (event.event === 'error' && event.reason === 'no-window') {
    $.ui.toast('Appshot: press both ⌘ keys over the window you want; Claude skips its own window')
  } else if (event.event === 'error') {
    $.ui.log(`appshot: ${String(event.reason)}`, { to: 'debug' })
  }
}

// One helper per machine holds the hotkey; every session retries so the
// hotkey survives the hosting session closing.
function runHelper($: EngineInterface) {
  void (async () => {
    let code: number | null = null
    try {
      const child = $.process.spawn({ argv: [binary(), '--root', s.root, '--skip-bundle', CLAUDE_DESKTOP] })
      let buffer = ''
      for await (const piece of child) {
        if (piece.stream === 'stderr') {
          $.ui.log(`appshot helper: ${piece.text.trim()}`, { to: 'debug' })
          continue
        }
        buffer += piece.text
        const lines = buffer.split('\n')
        buffer = lines.pop() ?? ''
        for (const line of lines) onHelperLine($, line)
      }
      code = (await child.result).code
    } catch (error) {
      s.helperState = `helper failed: ${String(error)}`
    }
    s.isHost = false
    $.clock.after(code === 3 ? 15_000 : 5_000, () => runHelper($))
  })()
}

// Brings the app this session draws in forward; answers its bundle id.
async function bringForward($: EngineInterface): Promise<string | undefined> {
  const entrypoint = await $.env.get('CLAUDE_CODE_ENTRYPOINT')
  const terminal = await $.env.get('TERM_PROGRAM')
  const bundle = entrypoint === 'claude-desktop'
    ? CLAUDE_DESKTOP
    : terminal === undefined ? undefined : TERMINALS[terminal]
  if (bundle !== undefined) await $.process.run(['/usr/bin/open', '-b', bundle])
  return bundle
}

// The desktop app attaches a pasted image natively: the helper focuses the
// composer, pastes the screenshot, then restores the clipboard.
async function pasteImage($: EngineInterface, png: string): Promise<boolean> {
  const ran = await $.process.run([binary(), '--paste', png, '--expect-bundle', CLAUDE_DESKTOP], { timeoutMs: 10_000 })
  $.ui.log(`appshot: paste: ${ran.stdout.trim()}`, { to: 'debug' })
  return ran.exitCode === 0
}

async function deliver($: EngineInterface, meta: Meta) {
  const shot: Appshot = { ...meta, token: labelFor(meta) }
  delete (shot as Meta).target

  const bundle = await bringForward($)
  shot.isPasted = bundle === CLAUDE_DESKTOP && meta.png !== undefined && (await pasteImage($, meta.png))
  await update($, pending, list => [...asList(list), shot].slice(-10))
  // No toast: the pasted screenshot and the band say it all.
}

async function poll($: EngineInterface) {
  if (s.isPolling || !(await $.fs.exists(captures()))) return
  s.isPolling = true
  try {
    const names = (await $.fs.list(captures()))
      .filter(entry => entry.kind === 'dir' && entry.name > s.lastSeen)
      .map(entry => entry.name)
      .sort()
    for (const name of names) {
      const metaPath = `${captures()}/${name}/meta.json`
      if (!(await $.fs.exists(metaPath))) break // still being written
      s.lastSeen = name
      const meta = JSON.parse(await $.fs.read(metaPath)) as Meta
      const isMine = meta.target === undefined ? s.isHost : meta.target === s.sessionId
      if (isMine) await deliver($, meta)
    }
  } finally {
    s.isPolling = false
  }
}

async function contextFor($: EngineInterface, shot: Appshot): Promise<string> {
  let text = ''
  try {
    text = await $.fs.read(shot.txt)
  } catch {
    text = '(the window text file could not be read inline; open it with the Read tool)'
  }
  return formatAppshot(shot, text)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    s.root = `${await $.env.get('HOME')}/.claude/appshots`
    s.sessionId = await $.session.id()
    await $.command.register({
      name: 'appshot',
      description: 'Send appshots (both Command keys) to this session, and show the helper status',
    })

    if (await $.fs.exists(captures())) {
      const names = (await $.fs.list(captures())).map(entry => entry.name).sort()
      s.lastSeen = names.at(-1) ?? ''
    }
    void (async () => {
      await markActive($)
      if (!(await ensureBinary($))) return
      runHelper($)
      // Captures older than a week are dropped.
      await $.process.run(['/usr/bin/find', captures(), '-mindepth', '1', '-maxdepth', '1', '-mtime', '+7', '-exec', '/bin/rm', '-rf', '{}', '+'])
    })()
    $.clock.every(500, () => void poll($))

    return next(e)
  })

  // Every pending appshot rides the person's next prompt, then is done with.
  on('prompt.submit', async ($, e, next) => {
    if (!PERSON.has(e.origin.kind)) return next(e)
    if (s.root) void markActive($)
    const list = asList(await read($, pending))
    if (list.length === 0) return next(e)

    await update($, pending, () => [])
    void $.ui.close({ id: TEXT_PANE })
    const blocks = await Promise.all(list.map(shot => contextFor($, shot)))

    return next({ ...e, context: [...(e.context ?? []), ...blocks] })
  }).catch(($, e, next) => next(e)) // never hold up the person's message

  // Above the composer while appshots wait: one row each, Show text, Remove.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = asList(await read($, pending))
    if (list.length === 0 || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Text dimColor>
          {list.length === 1 ? 'Appshot going with your next message:' : `${list.length} appshots going with your next message:`}
        </Text>
        {list.map(shot => (
          <Box key={`row-${shot.id}`} gap={1}>
            <Text wrap="truncate-end">
              {shot.token} · {shot.chars.toLocaleString('en-US')} chars
            </Text>
            <Button
              key={`show-${shot.id}`}
              label="Show text"
              onPress={async () => {
                await update($, shown, () => shot.id)
                await $.ui.open({ id: TEXT_PANE, title: `Appshot: ${shot.app}`, closeOnEscape: true })
              }}
            />
            <Button
              key={`remove-${shot.id}`}
              label="Remove"
              dimColor
              onPress={async () => {
                await update($, pending, all => asList(all).filter(one => one.id !== shot.id))
                if ((await read($, shown)) === shot.id) void $.ui.close({ id: TEXT_PANE })
                $.ui.toast(`${shot.app} appshot text dropped; delete its pasted screenshot too if you do not want it sent`)
              }}
            />
          </Box>
        ))}
      </Box>
    )
  })

  // The pane: the text the model will read for the chosen pending appshot.
  on('ui.render', { component: 'Pane', requestId: TEXT_PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const id = await read($, shown)
    const shot = asList(await read($, pending)).find(one => one.id === id)
    if (shot === undefined) return <Text dimColor>No appshot waiting.</Text>
    let text = ''
    try {
      text = await $.fs.read(shot.txt)
    } catch {
      text = `(the text file is gone: ${shot.txt})`
    }
    const isCut = text.length > PANE_CHARS
    return (
      <Box flexDirection="column" gap={1}>
        <Text dimColor>
          {shot.token} · {shot.chars.toLocaleString('en-US')} characters · {shot.txt}
        </Text>
        <Text wrap="wrap">{isCut ? text.slice(0, PANE_CHARS) : text}</Text>
        {isCut && <Text dimColor>… {text.length - PANE_CHARS} more characters in the file.</Text>}
      </Box>
    )
  })

  on('command.run', { command: 'appshot' }, async $ => {
    await markActive($)
    const list = asList(await read($, pending))
    return {
      text: [
        'Appshots now go to this session (the session you last sent a prompt from gets them).',
        `Helper: ${s.helperState}${s.isHost ? ' (hosted by this session)' : ''}.`,
        list.length === 0 ? 'No appshot waiting.' : `Waiting for your next message: ${list.map(shot => shot.token).join('; ')}.`,
        `Captures live in ${captures()}.`,
      ].join('\n'),
    }
  })

  on('session.end', async ($, e, next) => {
    try {
      const active = JSON.parse(await $.fs.read(`${s.root}/active.json`)) as { sessionId?: string }
      if (active.sessionId === s.sessionId) await $.fs.write(`${s.root}/active.json`, '{}')
    } catch {
      // No active session recorded.
    }
    return next(e)
  })
}
