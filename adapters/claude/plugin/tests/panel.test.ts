import { test, expect } from 'claude-code/testing'

const BAND = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

const REMINDER = {
  title: 'Open tasks',
  more: 0,
  conflicts: 0,
  tasks: [
    { task: 'alpha/review-report', name: 'review-report', status: 'open', when: 'today', next: 'Decide what the report shows', here: false },
    { task: 'beta/radar', name: 'radar', status: 'open', when: '14 days ago', next: '', here: true },
    { task: 'alpha/domain', name: 'domain', status: 'waiting', when: 'yesterday', next: 'Do we register the domain?', here: false,
      waiting: { on: 'Alex', ask: 'Do we register the domain?', since: '2026-09-20', ref: '', days: 9, nudge: true } },
  ],
}

// What Claude Code resolves in a real session: the kernel, the cwd, the
// settings.json hook and what is drawn when no mod draws.
function environment(on, output = JSON.stringify(REMINDER)) {
  const env = {}
  on('env.set', async (_$, e) => { env[e.name] = e.value; return { value: undefined } })
  on('session.cwd', async () => ({ value: '/projects/beta' }))
  on('process.run', async () => ({ value: { exitCode: 0, stdout: output, stderr: '' } }))
  on('classic.SessionStart', async () => ({}))
  on('ui.render', async ($, e) => $.ui.resolve(e).Box({ children: [] }))
  return env
}

const START = { hook_event_name: 'SessionStart', source: 'startup', session_id: 's', transcript_path: '/t', cwd: '/projects' }

for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
  test(`on start it draws each task and can be hidden (${surface})`, async ($, on) => {
    const env = environment(on)
    await $.classic.SessionStart(START)
    expect(env['CRUX_REMINDER_UI']).toBe('panel')
    const ui = await $.ui.mount({ plugin: 'crux', surface, ...BAND })
    expect(await ui.find({ key: 'resume-alpha/review-report' })).toBeDefined()
    expect(await ui.find({ key: 'resume-beta/radar' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /no workspace here/ })).toBeDefined()
    await ui.press({ key: 'hide' })
    expect(await ui.find({ key: 'resume-beta/radar' })).toBeUndefined()
    await ui.unmount()
  })
}

test('with no open tasks it draws nothing', async ($, on) => {
  environment(on, '')
  await $.classic.SessionStart(START)
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...BAND })
  expect(await ui.find({ key: 'hide' })).toBeUndefined()
  await ui.unmount()
})

test('on compaction it does not bring the panel back', async ($, on) => {
  environment(on)
  await $.classic.SessionStart({ ...START, source: 'compact' })
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...BAND })
  expect(await ui.find({ key: 'hide' })).toBeUndefined()
  await ui.unmount()
})

// The current task: inside a workspace, among the footer mode labels; outside,
// nothing.
function taskEnvironment(on, root) {
  on('env.set', async () => ({ value: undefined }))
  on('session.cwd', async () => ({ value: root }))
  on('process.run', async (_$, e) => {
    const argv = e.argv ?? []
    if (argv[0] === 'git') return { value: { exitCode: 0, stdout: root + '\n', stderr: '' } }
    if (argv[0] === 'bash') return { value: { exitCode: 0, stdout: JSON.stringify({ task: 'checkout-one-step', status: 'open', steps: '2/5', next: 'Try the payment on mobile' }), stderr: '' } }
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('classic.SessionStart', async () => ({}))
  on('ui.render', async ($, e) => $.ui.resolve(e).Text({ children: [(e.props.modes ?? []).join(' & ')] }))
}

const FOOTER = { component: 'SessionMode', props: { modes: ['focus'] } } as const

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the footer shows the workspace's task (${surface})`, async ($, on) => {
    taskEnvironment(on, '/projects/shop-ws-checkout-one-step')
    await $.classic.SessionStart(START)
    const ui = await $.ui.mount({ plugin: 'crux', surface, ...FOOTER })
    expect(await ui.find({ type: 'Text', text: 'focus & ▸ checkout-one-step · steps 2/5' })).toBeDefined()
    await ui.unmount()
  })
}

test('outside a workspace the footer stays as it was', async ($, on) => {
  taskEnvironment(on, '/projects/shop')
  await $.classic.SessionStart(START)
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...FOOTER })
  expect(await ui.find({ type: 'Text', text: /checkout/ })).toBeUndefined()
  await ui.unmount()
})

test('a waiting task says who it waits on and warns about a nudge', async ($, on) => {
  environment(on)
  await $.classic.SessionStart(START)
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...BAND })
  expect(await ui.find({ key: 'resume-alpha/domain' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /waiting on Alex, 9 days ago · worth a nudge/ })).toBeDefined()
  await ui.unmount()
})
