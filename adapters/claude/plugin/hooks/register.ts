// El recordatorio de tareas de Crux como panel encima del prompt.
//
// Los datos y el texto los sigue generando el kernel (lib/task-sync.mjs) y el
// hook de shell de SessionStart, que es lo que ven Codex, la web y el móvil.
// Este mod solo cambia cómo se enseña en Claude Code: avisa al hook con
// CRUX_REMINDER_UI para que no pinte el texto y dibuja el mismo contenido
// como panel, con un atajo numérico para retomar cada tarea.
import { atom, read, update } from 'claude-code'

const titulo = atom({ plugin: 'crux', key: 'titulo' }, '')
const tareas = atom({ plugin: 'crux', key: 'tareas' }, [])
const mas = atom({ plugin: 'crux', key: 'mas' }, 0)
const oculto = atom({ plugin: 'crux', key: 'oculto' }, false)
const enCurso = atom({ plugin: 'crux', key: 'enCurso' }, '')

// El plugin vive en <kernel>/adapters/claude/plugin.
const kernelDe = (root: string) => root.replace(/\/adapters\/claude\/plugin\/?$/, '')

async function cargar($) {
  const cwd = await $.session.cwd()
  const { exitCode, stdout } = await $.process.run(
    ['node', kernelDe($.plugin.root) + '/lib/task-sync.mjs', 'remind', '--cwd', cwd],
    { timeoutMs: 20000 },
  )
  const datos = exitCode === 0 && stdout.trim() ? JSON.parse(stdout) : null
  await update($, titulo, () => datos?.titulo ?? '')
  await update($, tareas, () => datos?.tareas ?? [])
  await update($, mas, () => datos?.mas ?? 0)
  await update($, oculto, () => false)
}

// La tarea del espacio de trabajo en que está la sesión, con la misma búsqueda
// que el hook task-context: common.sh la encuentra y task.mjs la resume.
const RESUMEN = `
  source "$1/lib/common.sh"
  f="$(task_file_for_path "\${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}" "$2")" || exit 0
  node "$1/lib/task.mjs" summary --file "$f" --json`

async function estadoTarea($) {
  const cwd = await $.session.cwd()
  const git = await $.process.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'])
  const raiz = git.exitCode === 0 ? git.stdout.trim() : ''
  let etiqueta = ''
  if (raiz.includes('-ws-')) {
    const { exitCode, stdout } = await $.process.run(
      ['bash', '-c', RESUMEN, 'crux', kernelDe($.plugin.root), raiz],
      { timeoutMs: 10000 },
    )
    if (exitCode === 0 && stdout.trim()) {
      const t = JSON.parse(stdout)
      etiqueta = [t.tarea, t.pasos ? 'pasos ' + t.pasos : t.estado].filter(Boolean).join(' · ')
    }
  }
  await update($, enCurso, () => etiqueta)
}

export function register(on) {
  // La línea de estado se pone al día al acabar cada turno: es cuando el
  // agente ha podido marcar pasos o cambiar el siguiente con crux task.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    await estadoTarea($)
    return r
  })

  // Corre antes que los hooks de settings.json del mismo evento: la variable
  // ya está puesta cuando el hook de Crux decide si pinta el texto.
  on('classic.SessionStart', async ($, e, next) => {
    await $.env.set('CRUX_REMINDER_UI', 'panel')
    const resultado = await next(e)
    // Tras compactar la sesión sigue a medias: el hook calla y el panel también.
    if (e.source !== 'compact') await cargar($)
    await estadoTarea($)
    return resultado
  })

  // En cuanto la persona escribe, el recordatorio ya ha cumplido.
  on('prompt.submit', async ($, e, next) => {
    await update($, oculto, () => true)
    return next(e)
  })

  // La tarea del espacio, entre las etiquetas de modo del pie del prompt:
  // discreta y siempre a la vista, sin pasar por la conversación.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const etiqueta = await read($, enCurso)
    if (!etiqueta) return next(e)
    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, '▸ ' + etiqueta] } })
  })

  // Una tarea que espera a otra persona no es trabajo pendiente: dice a quién
  // espera y desde cuándo, y avisa cuando conviene insistir.
  const waitingLabel = (w) => {
    const age = w.days == null ? '' : w.days === 0 ? 'hoy' : w.days === 1 ? 'ayer' : 'hace ' + w.days + ' días'
    return '· esperando a ' + w.on + (age ? ', ' + age : '') + (w.nudge ? ' · conviene insistir' : '')
  }

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const lista = await read($, tareas)
    if ((await read($, oculto)) || lista.length === 0) return next(e)
    const restantes = await read($, mas)
    const { Box, Text, Button } = $.ui.resolve(e)

    const fila = (t, i) =>
      Box({
        key: 'tarea-' + t.tarea,
        flexDirection: 'column',
        children: [
          Box({
            flexDirection: 'row',
            columnGap: 1,
            children: [
              Button({
                key: 'retomar-' + t.tarea,
                label: t.tarea,
                hotkey: String(i + 1),
                plain: true,
                onPress: async () => {
                  await update($, oculto, () => true)
                  await $.prompt.submit({ text: `Retomemos la tarea ${t.tarea}.`, asUser: true })
                },
              }),
              ...(t.waiting
                ? [Text({ color: t.waiting.nudge ? 'warning' : undefined, dimColor: !t.waiting.nudge, children: [waitingLabel(t.waiting)] })]
                : [
                    Text({ dimColor: true, children: ['· ' + t.cuando + (t.estado === 'open' ? '' : ' · ' + t.estado)] }),
                    ...(t.aqui ? [] : [Text({ color: 'warning', children: ['· sin espacio aquí'] })]),
                  ]),
            ],
          }),
          ...(t.siguiente
            ? [Text({ dimColor: true, wrap: 'truncate-end', children: ['   ' + t.siguiente] })]
            : []),
        ],
      })

    return Box({
      flexDirection: 'column',
      borderStyle: 'round',
      paddingX: 1,
      children: [
        Box({
          flexDirection: 'row',
          columnGap: 1,
          children: [
            Text({ bold: true, children: [(await read($, titulo)) || 'Tareas abiertas'] }),
            Text({ dimColor: true, children: ['· pulsa el número para retomar una'] }),
          ],
        }),
        ...lista.map(fila),
        ...(restantes > 0 ? [Text({ dimColor: true, children: [`y ${restantes} más: crux status`] })] : []),
        Box({
          flexDirection: 'row',
          children: [
            Button({
              key: 'ocultar',
              label: 'Ocultar',
              plain: true,
              dimColor: true,
              onPress: () => update($, oculto, () => true),
            }),
          ],
        }),
      ],
    })
  })
}
