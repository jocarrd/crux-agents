---
name: promote-to-docs
description: Move to the docs repo what only exists in the conversation, in the agent's local memory or in a commit message, and commit it where it belongs: `decisions/`, `operations/`, `conventions/` or `repos/<repo>/notes.md`. Use when about to write a memory of type project or reference, when you say «esto habría que documentarlo», when a session has uncovered an operational gotcha or a why that isn't left in the code, and before it gets lost on closing.
---

# promote-to-docs

It moves information from the local, ephemeral scope to the durable one: git.

## When to use

- You are about to save a memory of type `project` or `reference`. The standard
  says those go to git, not to local.
- A conversation has decided something, discovered a gotcha or fixed a convention
  that right now is not anywhere durable.

## When not to use

- For memories of type `user` or `feedback`: those stay local, they are about the
  person and not the project.
- For implementation details the code itself already explains.
- For everything that occurs to you. Promoting is selective: if in six months it
  won't help anyone, it isn't worth it.

## Flow

### 1. Identify the piece

- What is going to be documented, in one or two lines.
- Which project it belongs to.
- What type it is: cross-repo decision, single-repo decision, operational,
  convention or status note.

### 2. Locate the docs repo

`~/Projects/<project>/<project>-docs/`. If it doesn't exist, the project is not
under the standard yet: use `/crux-init` or `crux adopt` first.

### 3. Decide the destination

| Type | Destination |
| ---- | ----------- |
| Cross-repo decision | `decisions/index.md`, as a new ADR |
| Single-repo decision | `repos/<repo>/decisions.md` |
| Operational, gotcha, infrastructure | `operations/<topic>.md` |
| Cross-cutting code convention | `conventions/<topic>.md` |
| A repo's status or context | `repos/<repo>/notes.md` |

When in doubt between cross-repo and single-repo, start with single: promoting it
later is provided for in the format; splitting it is not.

### 4. Write

- **ADRs**: canonical template from `decisions/README.md`, with the next
  sequential number of the log where it goes.
- **operations/ and conventions/**: if there is already a file on the same topic,
  add a section; don't create a new one. These folders become useless when every
  gotcha has its own file.
- **notes.md**: dated entries, the most recent on top.

Absolute dates (`2026-08-01`), never relative: "last week" means nothing when
someone reads it in March.

### 5. Clean up the source

If it came from the agent's local memory, delete it along with its line in the
index. Otherwise it stays duplicated in two places that will diverge.

### 6. Commit

A message that says where it went and what it is:

```
docs(decisions): add ADR-NNN <title>
docs(operations): document <title>
docs(conventions): add <title>
docs(repos/<repo>): note on <title>
```

Ask before pushing.

## How to tell the type

| Clue | Likely type |
| ---- | ----------- |
| "Why we decided X", affects one repo | single-repo decision |
| "Why we decided X", affects several | cross-repo decision |
| "When X happens, do Y" in infrastructure or external data | operational |
| "Rule applicable in all repos" | convention |
| "X is blocked because of Y" | status note |

## Anti-patterns

- **Promoting for the sake of promoting.** If the commit already explains it well,
  it isn't needed.
- **Creating a new file when one on the same topic exists.**
- **Forgetting to delete the local source.**

## Related

- `/end-session`: the full closing ritual, which includes this
- `/add-repo-to-docs`: register a new repo in the project
