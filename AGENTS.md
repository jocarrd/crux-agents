# AGENTS.md — crux

This repo is the **kernel of the agent workflow system**: the standard, the
cross-cutting skills, the templates and the tooling that every project
consumes.

It is not a project's documentation. It is what produces them.

---

## Before touching anything

| You are about to… | Read |
| ----------------- | ---- |
| Understand the whole system | `GUIA.md` — eight levels, from simple to deep |
| Change a rule of the standard | `STANDARD.md` |
| Write a new skill | The `/skill-creator` skill, and `STANDARD.md` §Skills |
| Touch a command | `bin/<command>.sh`, and the suite in `test/` |

And run the suite **before and after**:

```bash
./test/run.sh
```

---

## The five rules that hold this repo up

They are there on purpose and tests fail if they are broken. They are not style.

### 1. The kernel names no project

Not in the skills, not in the templates, not in the profiles, not in the code.
If you need a concrete piece of data —a path, a port, a device, a
credential—, that data goes in an **adapter** inside the project, and what
stays here is the procedure.

It is enforced by `test_kernel_names_no_concrete_projects`. This is the
rule that stops crux from coupling itself again to what it documents, which is
exactly how the problem this repo solves was born.

### 2. No skill is tied to a specific agent

A skill describes **the action to perform**, not who runs it or with what
tool. That is what lets the same `SKILL.md` serve several agents from a single
source.

It is enforced by `test_no_kernel_skill_names_an_agents_tools`.

### 3. A library does not set shell options

`lib/common.sh` **has no `set -e`**. Whoever loads it has already declared
their own options, and overriding them kills the script silently at the first
command that returns a non-zero status.

This has already broken the test suite and then `doctor`, both times without a
single message. If a command returns meaningful codes, collect them with
`cmd || rc=$?`, never with a bare `$?`.

It is enforced by `test_the_library_does_not_override_shell_options`.

### 4. What is generated is generated; it is not maintained by hand

The repo pointers, the skill catalog in the index and the table rows are
produced from templates and contracts. If you find yourself editing something
a command could write, the fix is the command, not the file.

### 5. What cannot be read is reported, and execution stops

A missing, unreadable or corrupt file **is not turned into a default value**.
It is named, and execution stops there.

Carrying on past the gap produces the worst possible failure: one that looks
like it works. `doctor` read `?` from a broken `crux.json` and blamed fields
that were in fact there; `release` found no consumers and published saying
there was nothing to verify; `finish` let the shell error leak out because the
`2>/dev/null` on a command does not cover the redirection the shell itself
performs.

`2>/dev/null` is fine for asking whether something exists. It is not fine for
reading something that has to be there.

It is enforced by `test_no_command_hides_a_file_it_cannot_read`.

---

## How it is organized

```
STANDARD.md    the standard: what a project must meet
GUIA.md        how everything works, from start to finish
install.sh     per-machine installation
bin/           one file per command
lib/           shared utilities and verifiers
templates/     what gets materialized in each project
profiles/      verifiable policy: multi-repo, client-repo
adapters/      how the kernel is exposed to each agent
skills/        the cross-cutting procedures
test/          the kernel's own suite
```

---

## Adding something

**A skill**: `skills/<name>/SKILL.md` with `name` and `description`
frontmatter. The description decides whether it activates, so it carries the
situations and the words in which the problem shows up. Then `./install.sh`
to materialize it.

**A command**: `bin/<name>.sh` plus its entry in the `bin/crux` dispatcher, in
`README.md` and in the table in `STANDARD.md`. And a case in `test/cases/`.

**A `doctor` check**: inside its numbered block, with `section` and
`section_ok`. And a **negative** test: one that fails when it should. A check
that has never been seen to fail is worthless.

---

## How it is tested

```bash
./test/run.sh            # everything
./test/run.sh doctor     # those matching the pattern
```

Each case runs in an isolated sandbox with the agent directories redirected
—including the **settings** where the hooks live, which one case put back in
its real place with an `unset`, leaving the machine with three hooks pointing
at an already deleted worktree—: the suite **does not touch** `~/.claude`,
`~/.codex` or `~/Proyectos`. The runner checks this after every case. If you
write a case that needs a `$HOME`, **pass it per invocation**
(`env HOME=... bash ...`), never with `export`: exporting it carries it over
to the next case, which, once the sandbox is deleted, is left pointing at a
nonexistent directory. The runner detects this and reports it as a failure,
because the first time it happened it hung the whole suite without a single
message.

And calibrate against reality: when `code-health` was written, its first
version produced 248 findings of noise on a real repo. A report nobody reads
twice is worthless, even if the code is correct.

---

## Working rules

- **Semver versioning in `VERSION`.** Patch for wording and fixes; minor for
  new templates, skills or checks; major if the mandatory structure or the
  `crux.json` format changes.
- **The standard is changed here first**, and projects align with
  `crux upgrade`. No project invents its own variant.
- **Language**: everything in English — documentation, descriptions, names,
  commands, branches and **commits**; technical terms are left as they are. The
  commit rule is checked by the `commit-msg` hook that `crux hooks install`
  installs: the rule had been written down since day one and the history was
  entirely in Spanish.
- **Conventional commits**, body lines of 100 characters, no `Co-Authored-By`
  and no emojis. **Neither the commit nor the description of a change proposal
  carries the tool's signature**: no `Co-Authored-By` and no "generated with"
  line at the bottom. The `commit-msg` hook strips it automatically, because
  the agent adds it on instruction from its own environment and the written
  rule kept losing that fight.
- **A proposal's description says what changes, what is added and why**, plus
  what was verified and what is pending. In a client repo it does not name our
  tooling or our internal processes. See `STANDARD.md` §8.
- **No comments that narrate what the code already says.** Only the why that
  cannot be deduced by reading.
