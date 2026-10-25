---
name: end-session
description: Session closing ritual. Reviews what happened in the conversation and promotes to the documentation whatever deserves to survive (decisions, gotchas, conventions, notes). Verifies conformance and drift. Applies agent-memory hygiene. Commits and pushes whatever is pending. Use when about to close the agent or after finishing significant work, or when the user says "ya está", "vale", "termina", "cierra sesión".
---

# end-session

Closing ritual under the standard. It guarantees that **nothing relevant is
lost** when the session ends.

## When to use

- The user is finishing a significant work session.
- They say something like "ya está", "vale", "perfecto", "cierra sesión",
  "termina".
- You are more than ten turns of work in with no closing.
- Before switching machines.

## When not to use

- Short question-and-answer sessions, with no changes or decisions.
- When the user only asked for information and there is nothing to make durable.
- If this ritual was already run in the same session.

## The four questions

Go over the session and ask yourself, for each category, whether anything came
up:

**1. Decisions that don't stay in the code.**
Signals: "we decided X", "we chose Y", agreements on architecture, naming or
dependencies.
Destination: `<project>-docs/decisions/index.md` if it crosses repos;
`<project>-docs/repos/<repo>/decisions.md` if it affects only one.

**2. Gotchas or operational information.**
Signals: "watch out for X", "this breaks if Y", "the header has to be exactly
Z", problems with infrastructure or external data.
Destination: `<project>-docs/operations/<topic>.md`.

**3. New conventions or rules.**
Signals: "we always use X", "never do Y", patterns that should apply to future
sessions.
Destination: `<project>-docs/conventions/<topic>.md`, or the repo's registry if
it only applies to one.

**4. User preferences about how to work.**
Signals: "I prefer X", "I don't like Y", corrections of style or pace.
Destination: the agent's local memory, type `user` or `feedback`. These stay
local by design: they are about the person, not the project.

## Flow

### 1. Inventory of what is not on the remote

```bash
crux sync --leave
```

It walks all the repos and says what would remain only on this machine:
uncommitted changes, unpushed commits, branches that are on no remote, and
stashes. If tomorrow the work is done from another computer, whatever shows up
here won't be there.

### 2. Agent memory hygiene

```bash
crux memory
```

It lists the `project` and `reference` memories that are still only local, from
this session and earlier ones, with the docs repo they belong to. The standard
says those go to git: promote them (with `/promote-to-docs` or directly) and
delete the local copy, including its line in the memory index.

The ones that come out without a docs repo belong to a scope that is no project.
There the destination is your call: the command doesn't guess it from the file
name, because it would be right some of the time and would put documentation in
the wrong project the rest.

### 3. Conformance and drift

```bash
crux doctor
```

It verifies the contract, the structure, the declared repos, the profile rules
and the markdown links. If broken links appear:

- **To files inside the docs repo**: fix them; the referenced doc has been moved
  or renamed.
- **To files of a sibling repo**: convert them to plain text in backticks. The
  standard forbids linking outside the docs repo because those links break with
  any reorganization and end up lying.

### 4. Tasks left open

```bash
crux task list
```

A task only archives itself when its last workspace closes, so one created with
`crux task new` and then done in a workspace with another name stays open
forever. Go through the ones this session created or touched: if the work is
done, archive it (`crux task archive --task <project>/<task>`); if not, leave
its next step written. The ones marked `idle` have gone days with no workspace
and are the usual suspects. Ask before archiving anything the session did not
finish.

### 5. Skill boundary, if you touched any

If a skill was created or changed in the session, decide it now while it is
fresh: pattern or adapter? This is the moment when it is known. Every so many
closings, also run the full review with `/skill-audit`.

### 6. Present the balance to the user

A summary structured by the four categories, with what was found in each, and
confirmation for each item. If there is nothing, say so plainly: a session with
nothing to make durable.

**The user confirms or vetoes each item.** Nothing is promoted unilaterally.

### 7. Write and commit

One commit per category, not one giant one:

- `docs(decisions): ...` for new ADRs
- `docs(operations): ...` for gotchas
- `docs(conventions): ...` for conventions
- `docs(repos/<repo>): ...` for a repo's notes

Push each affected repo.

### 8. Final report

What was written and where, what was fixed, which repos were pushed. If work is
left uncommitted on purpose, say so explicitly instead of staying silent.

## Anti-patterns

- **Promoting everything that was said.** The filter is: would this help another
  session six months from now? If not, it isn't durable.
- **Promoting and not deleting the local copy.** It stays duplicated and will
  diverge.
- **Skipping the verification.** It is the only moment when it is proactively
  checked that the documentation doesn't lie.
- **Closing without asking.** The user decides what survives.

## Related

- `/promote-to-docs`: promote a single item in the middle of the session
- `/skill-audit`: review whether any new skill deserves to move up to the kernel
- The full standard, in the kernel's `STANDARD.md`
