import { test, expect } from 'claude-code/testing'

const BANDA = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

const RECORDATORIO = {
  titulo: 'Tareas abiertas',
  mas: 0,
  conflictos: 0,
  tareas: [
    { tarea: 'alfa/revisar-informe', nombre: 'revisar-informe', estado: 'open', cuando: 'hoy', siguiente: 'Decidir qué enseña el informe', aqui: false },
    { tarea: 'beta/radar', nombre: 'radar', estado: 'open', cuando: 'hace 14 días', siguiente: '', aqui: true },
  ],
}

// Lo que en una sesión real resuelve Claude Code: el kernel, el cwd, el hook
// de settings.json y lo que se dibuja cuando ningún mod dibuja.
function entorno(on, salida = JSON.stringify(RECORDATORIO)) {
  const env = {}
  on('env.set', async (_$, e) => { env[e.name] = e.value; return { value: undefined } })
  on('session.cwd', async () => ({ value: '/proyectos/beta' }))
  on('process.run', async () => ({ value: { exitCode: 0, stdout: salida, stderr: '' } }))
  on('classic.SessionStart', async () => ({}))
  on('ui.render', async ($, e) => $.ui.resolve(e).Box({ children: [] }))
  return env
}

const INICIO = { hook_event_name: 'SessionStart', source: 'startup', session_id: 's', transcript_path: '/t', cwd: '/proyectos' }

for (const surface of ['terminal', 'desktop', 'mobile'] as const) {
  test(`al empezar pinta cada tarea y se puede ocultar (${surface})`, async ($, on) => {
    const env = entorno(on)
    await $.classic.SessionStart(INICIO)
    expect(env['CRUX_REMINDER_UI']).toBe('panel')
    const ui = await $.ui.mount({ plugin: 'crux', surface, ...BANDA })
    expect(await ui.find({ key: 'retomar-alfa/revisar-informe' })).toBeDefined()
    expect(await ui.find({ key: 'retomar-beta/radar' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /sin espacio aquí/ })).toBeDefined()
    await ui.press({ key: 'ocultar' })
    expect(await ui.find({ key: 'retomar-beta/radar' })).toBeUndefined()
    await ui.unmount()
  })
}

test('sin tareas abiertas no dibuja nada', async ($, on) => {
  entorno(on, '')
  await $.classic.SessionStart(INICIO)
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...BANDA })
  expect(await ui.find({ key: 'ocultar' })).toBeUndefined()
  await ui.unmount()
})

test('al compactar no vuelve a sacar el panel', async ($, on) => {
  entorno(on)
  await $.classic.SessionStart({ ...INICIO, source: 'compact' })
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...BANDA })
  expect(await ui.find({ key: 'ocultar' })).toBeUndefined()
  await ui.unmount()
})

// La tarea en curso: dentro de un espacio de trabajo, entre las etiquetas de
// modo del pie; fuera, nada.
function entornoTarea(on, raiz) {
  on('env.set', async () => ({ value: undefined }))
  on('session.cwd', async () => ({ value: raiz }))
  on('process.run', async (_$, e) => {
    const argv = e.argv ?? []
    if (argv[0] === 'git') return { value: { exitCode: 0, stdout: raiz + '\n', stderr: '' } }
    if (argv[0] === 'bash') return { value: { exitCode: 0, stdout: JSON.stringify({ tarea: 'checkout-un-paso', estado: 'open', pasos: '2/5', siguiente: 'Probar el pago en el móvil' }), stderr: '' } }
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('classic.SessionStart', async () => ({}))
  on('ui.render', async ($, e) => $.ui.resolve(e).Text({ children: [(e.props.modes ?? []).join(' & ')] }))
}

const PIE = { component: 'SessionMode', props: { modes: ['focus'] } } as const

for (const surface of ['terminal', 'desktop'] as const) {
  test(`el pie enseña la tarea del espacio de trabajo (${surface})`, async ($, on) => {
    entornoTarea(on, '/proyectos/tienda-ws-checkout-un-paso')
    await $.classic.SessionStart(INICIO)
    const ui = await $.ui.mount({ plugin: 'crux', surface, ...PIE })
    expect(await ui.find({ type: 'Text', text: 'focus & ▸ checkout-un-paso · pasos 2/5' })).toBeDefined()
    await ui.unmount()
  })
}

test('fuera de un espacio de trabajo el pie queda como estaba', async ($, on) => {
  entornoTarea(on, '/proyectos/tienda')
  await $.classic.SessionStart(INICIO)
  const ui = await $.ui.mount({ plugin: 'crux', surface: 'terminal', ...PIE })
  expect(await ui.find({ type: 'Text', text: /checkout/ })).toBeUndefined()
  await ui.unmount()
})
