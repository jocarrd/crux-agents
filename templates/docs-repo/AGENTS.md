# AGENTS.md — {{PROJECT}}-docs

Cross-cutting documentation for **{{PROJECT}}**. It is the project's canonical
context for any coding agent.

This file is an **index**: read only the section you need for the current task,
not everything blindly.

---

## How we work here

**For any development task, the cycle is `/flow`**: understand, isolate the
space, plan, develop, pass the gate, propose and close. That skill explains the
order and why that order.

The steps, if you need to go straight to one:

| Moment | What to invoke |
| ------ | -------------- |
| You arrive and do not know the repo | `/repo-map` |
| You are about to start working | `/workspace` — your branch and your environment, without stepping on anyone |
| Before touching code | `/explain-plan` |
| Something fails and you do not know why | `/root-cause` |
| You are about to commit | `/ship` |
| You have finished | `/workspace finish` — pushes the branch and opens the proposal |
| You close the session | `/end-session` |

The two most often overlooked are `/ship` and `/end-session`, and they are the
ones that hold up the rest: the first stops broken work from getting in, the
second stops what was learned from being lost.

---

## When to read what

**You are going to touch the code of a specific repo**
- Repo-specific documentation → `repos/<repo>/`
- Decisions that affect only that repo → `repos/<repo>/decisions.md`

**You are going to make or review a decision that crosses several repos**
- ADR registry → `decisions/index.md`
- Format and how to add one → `decisions/README.md`

**You want to understand how this documentation is organized**
- The complete standard lives in the kernel: `crux/STANDARD.md`
- Version and profile applied here: `crux.json`

<!-- Add sections as they appear: architecture/, conventions/,
     operations/, topics/<topic>/ -->

---

## Skills

The cross-cutting procedures live in the kernel and are available as
`/<name>`. This list is maintained by `crux link`:

<!-- crux:skills -->
<!-- /crux:skills -->

{{PROJECT}}-specific ones live in `.claude/skills/project/` of this repo. When
they appear, they are listed here with their trigger, so that agents that do
not read frontmatter can discover them.

---

## Hard rules

- **Repo-specific documentation goes in `repos/<repo>/`**, not inside the code
  repo. What is cross-cutting goes in `architecture/`, `conventions/`,
  `operations/` or `topics/<topic>/`.
- **Code ↔ doc sync:** when changing code that invalidates a doc here, it is
  updated in the same turn.
- **Project notes and references go to git, not to the agent's local memory.**
  Local memory is kept for what concerns the person.
- **Changes in this repo are committed and pushed when finished.**
- **Conventional commits**, body of 100 characters per line at most.
- **No `Co-Authored-By`. No emojis.** Neither in the commit nor in a change
  proposal's description: no tool signatures and no "generated with" lines.
