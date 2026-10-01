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

export function register(on) {
  // Corre antes que los hooks de settings.json del mismo evento: la variable
  // ya está puesta cuando el hook de Crux decide si pinta el texto.
  on('classic.SessionStart', async ($, e, next) => {
    await $.env.set('CRUX_REMINDER_UI', 'panel')
    const resultado = await next(e)
    // Tras compactar la sesión sigue a medias: el hook calla y el panel también.
    if (e.source !== 'compact') await cargar($)
    return resultado
  })

  // En cuanto la persona escribe, el recordatorio ya ha cumplido.
  on('prompt.submit', async ($, e, next) => {
    await update($, oculto, () => true)
    return next(e)
  })

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
              Text({ dimColor: true, children: ['· ' + t.cuando + (t.estado === 'open' ? '' : ' · ' + t.estado)] }),
              ...(t.aqui ? [] : [Text({ color: 'warning', children: ['· sin espacio aquí'] })]),
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
