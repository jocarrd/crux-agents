# Contributing to crux

Thanks for wanting to improve crux. This file covers how to send a change.
How the kernel is built, and the rules a change has to respect, are in
[`AGENTS.md`](AGENTS.md): read it first, it is short.

## Before you start

- **Open an issue first** for anything bigger than a fix: a new command, a new
  skill, a change to the standard. Many design questions are already settled
  in [`decisions/`](decisions/index.md), and the issue saves you from building
  something that reopens one of them.
- A fix with a clear cause can go straight to a pull request.

## Setting up

```bash
git clone https://github.com/jocarrd/crux.git
cd crux
./test/run.sh
```

You need `git`, `bash` and Rust's toolchain (`cargo`, from https://rustup.rs):
`test/run.sh` builds the binary before running the cases. The cases for the
few skills whose scripts use `node` or `curl` are skipped without them, and
say so. `shellcheck` is only needed to run the same static analysis CI runs
on the remaining scripts. The suite runs each case in a sandbox and never touches `~/.claude`, `~/.codex` or your projects.

To try your copy as your real kernel, install it in dev mode (see
"Release and dev modes" in the README).

## Making the change

- **Start from `ARCHITECTURE.md`** if you touch the binary: where each thing
  lives and the conventions the code follows.
- **Add a test with the change.** A new command gets a case in `test/cases/`.
  A new `doctor` check gets a negative test: one that fails when it should.
- **Run the whole suite before you push**: `./test/run.sh`, and
  `./test/e2e.sh` if you touched a command.
- **The five rules in `AGENTS.md` are enforced by tests.** If one turns red,
  the fix is in your change, not in the test.
- **Comments say why, not what.** The code already says what it does.

## Commits and pull requests

- [Conventional commits](https://www.conventionalcommits.org/) in English,
  imperative and lowercase: `fix(sync): keep the remote when …`. The body
  explains why.
- No `Co-Authored-By` lines and no "generated with" signatures. The
  `commit-msg` hook that `crux hooks install` sets up removes them anyway.
- One change per pull request. Its description says what changes, why, what
  you verified and what is still pending.
- If you bump `VERSION`, follow semver: patch for wording and fixes, minor for
  new skills, templates or checks, major if the `crux.json` format or the
  mandatory structure changes.

## Using an agent

Most of crux was written with coding agents, and you are welcome to use one.
Point it at `AGENTS.md`. You are still the author: read the whole diff before
you open the pull request.

## Licence

By contributing you agree that your contribution is released under the
[MIT licence](LICENSE).
