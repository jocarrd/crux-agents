# Architecture

crux is one Rust binary plus the files it materializes: the standard, the
skills, the templates and the profiles. This is the map of the binary, for
whoever is about to change it. What crux does and why is in `GUIA.md`; the
decision to make it one binary is ADR-019.

## How a command runs

```
~/.local/bin/crux ──► <kernel>/bin/crux ──► <kernel>/bin/crux-core
   symlink               launcher: finds        the binary: main.rs
                         the kernel's binary    └─ cmd::dispatch
                                                   └─ cmd::<command>::run(argv) -> Res
```

`bin/crux` exists so the same kernel works installed (`bin/crux-core`) and
from a clone right after `cargo build` (`rs/target/...`). The binary finds its
kernel from its own path, so nothing has to be exported.

A command returns `Res`, `Result<(), Exit>`: `Ok` is exit 0, `Exit(n)` is
exit n, and `die!` prints an error and returns `Exit(1)`. Only `main` turns
that into a process exit. That is what lets the destructors run on every
path: the registry lock, a half-made workspace's reservation, temporary
files. Rule 3 of `AGENTS.md`.

## The three layers

Each layer uses only the ones below it.

| Layer | Modules | What lives there |
| ----- | ------- | ---------------- |
| Entry points | `cmd/`, `agent_hooks/`, `script_api` | What a person, an agent or a script calls |
| Domain | `project`, `policy`, `checks`, `mcp`, `person`, `registry`, `task/`, `template`, `skills`, `secrets` | The contract, the profile, workspaces, tasks, and what crux writes into other people's files |
| Foundation | `env`, `files`, `git`, `sh`, `signals`, `args`, `ui`, `help`, `error` | Paths, files, processes, arguments and output |

Entry points:

- `cmd/<command>.rs` — one module per command; `cmd/workspace/` is split by
  phase (create, list, clean, propose). Each command's usage is
  `help/<command>.txt`.
- `agent_hooks/` — `crux hook <name>`: they read the agent's event as JSON
  on stdin, exit 0 to let it through and 2 to stop it. They run on every tool
  call, so they do no network and little disk.
- `script_api` — `crux __fn <function>`: single functions for what has to
  stay a shell script (a skill's script, a git hook) and for suite cases.

Domain, the parts that are not obvious from their names:

- `task/record` — a task's markdown record and its `Status`; `task/sync` —
  its replica in the docs repo's `crux/tasks` branch, written with git
  plumbing so the working tree is never touched; `task/remind` — what is open
  and the reminder a session gets.
- `template` — the blocks crux owns inside files that are otherwise the
  person's: regenerated between markers, the rest left as written.
- `checks` — what `doctor` verifies, each usable alone (`crux __check`).

## Conventions in the code

- **Paths come from `env`.** Every directory crux touches can be redirected
  by a variable; that is how the suite keeps its sandboxes off the real
  machine. A new path goes there, not in a command.
- **Writes that matter are atomic**: `files::write_atomic`. A truncated
  registry would open the deletion guard.
- **What cannot be read is reported**, never turned into a default (rule 5 of
  `AGENTS.md`). `files::read_or_empty` is for files that may not exist;
  for one that must, read it and handle the error.
- **Regular expressions** are `crate::regex!("...")`: compiled once per call
  site.
- **Arguments** are read with `args::Parser`; each command says which options
  it knows and what an unknown one means.
- **Other programs** run through `sh` (and `git` through `git`), which return
  the code, stdout and stderr instead of failing.
- **Output** goes through `ui` (`ok`, `warn`, `err`, `info`): the format is
  what the suite and people read.
- **Closed sets are enums** (`task::record::Status`), not strings compared
  across files.
- **Comments say why**, in present tense; what changed and when is git's job.

## Testing

Two levels, and both run in CI:

- `cargo test --manifest-path rs/Cargo.toml` — unit tests of pure pieces:
  parsing, ordering, URL normalization.
- `./test/run.sh` — the black-box suite, about 1,400 assertions. Each case
  calls crux as a person would (`crux <command> ...`) in a sandbox with every
  path redirected, and the runner checks afterwards that nothing outside it
  was touched. It is the specification: the binary was ported command by
  command against it.
- `./test/e2e.sh` — the whole cycle in one go, against a local bare remote.
- `./test/two-machines.sh` — one person on two computers: a task started on
  one, resumed on the other, and what `sync` does when both changed it.
- `CRUX_SUITE_BIN=<binary> ./test/run.sh` runs the suite against a binary
  built elsewhere, on a machine with no Rust.

A behaviour change starts with a case in `test/cases/` that fails.
