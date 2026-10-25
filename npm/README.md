# crux

A working system for coding agents: a documentation standard, cross-agent
skills and the tooling that keeps projects in line. The agent's memory lives in
git repos of your own, on GitHub or any other remote, with no server to run.

```bash
npx crux-agents install    # lays out the kernel on this machine
crux setup                 # account, remote, profile and projects, step by step
```

Or install the command globally with `npm i -g crux-agents` and run
`crux install`.

The package carries one binary per platform (Linux and macOS, x64 and arm64)
and runs nothing when it is installed. Documentation, source and issues:
https://github.com/jocarrd/crux-agents
