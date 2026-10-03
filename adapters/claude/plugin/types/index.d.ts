declare module 'claude-code' {
  interface PluginState {
    crux: {
      title: string
      tasks: {
        task: string
        name: string
        status: string
        when: string
        next: string
        here: boolean
      }[]
      more: number
      hidden: boolean
      currentTask: string
    }
  }
}
