declare module 'claude-code' {
  interface PluginState {
    crux: {
      titulo: string
      tareas: {
        tarea: string
        nombre: string
        estado: string
        cuando: string
        siguiente: string
        aqui: boolean
      }[]
      mas: number
      oculto: boolean
      enCurso: string
    }
  }
}
