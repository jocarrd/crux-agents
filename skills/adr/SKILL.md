---
name: adr
description: Record an ADR: a technical decision in the project's canonical format, in `decisions/index.md` if it crosses repos or in `repos/<repo>/decisions.md` if not, with the context that motivated it, its consequences and its reversal cost. Use when an architecture decision is made, a choice is made between alternatives, an option is discarded for a non-obvious reason, when about to edit a decision log or mark one as superseded, and when someone asks why something is done this way.
---

# adr

A decision that only lives in the head of whoever made it gets argued again every
six months, or worse: it gets reverted by accident.

## When it deserves a record

**Yes:**

- A choice was made between real alternatives and the chosen one is not the
  obvious one.
- Something was discarded for a reason not deducible from the code.
- It affects how things will be written from now on.
- Someone is going to ask "and why didn't we do X?".
- Debt was knowingly taken on.

**No:**

- Implementation details the code already explains.
- Style preferences, which go to the conventions.
- Decisions reversible in five minutes and with no consequences.

The filter: **if a year from now someone could undo it for not knowing why it was
done, it deserves a record.**

## Where it goes

| Scope | Log |
| ----- | --- |
| Affects more than one repo | `decisions/index.md` |
| Affects a single repo | `repos/<repo>/decisions.md` |

When in doubt, **start with single-repo**. Promoting it later is provided for in
the format; splitting up a badly placed cross-repo one is not.

Numbering is local to each log. To cite across logs, use the path prefix:
`decisions/ADR-013`, `repos/<repo>/ADR-007`.

## The format

```markdown
### ADR-NNN: One-line title

- **Date**: YYYY-MM-DD
- **Status**: Proposed | Accepted | Superseded
- **Context**: what problem or situation motivates it
- **Decision**: what we decided
- **Consequences**: how the code, operations or deployment change
- **Reversibility**: how costly it would be to undo
- **Related**: refs to other ADRs
```

## How to write each field

**Context** is the field that gets done badly. It doesn't describe the solution:
it describes **the situation that made it necessary**, with data if there is any.
Whoever reads it a year from now doesn't remember the problem, and without it the
decision looks arbitrary.

Include here what was tried and didn't work, and the alternatives that were
discarded with their reason. It is the part that prevents repeating the work.

**Decision** in the past tense and affirmative: what is done now, not what is
proposed.

**Consequences** honest in both directions. An ADR that only lists advantages is
justifying a decision already made. What is lost is written down too.

**Reversibility** is the most underrated field: it says whether this is a
two-way or a one-way door, and therefore how much thought it needed.

## Supersede, don't rewrite

When a decision stops being valid **it is neither edited nor deleted**: it is
marked `Status: Superseded by <ref>` and a new one is written.

The log is history, not current state. Its value lies precisely in being able to
see that something was decided, tried and changed, and why.

To promote from single-repo to cross-repo: a new entry in the cross-repo log, the
old one marked as superseded, and the old one stays where it is.

## When finished

A commit of its own, with the number and the title:

```
docs(decisions): add ADR-NNN <title>
```

## Anti-patterns

- **Writing it afterwards, "when there is time".** The context evaporates in
  days.
- **One ADR per change.** The log stops being read if it is full of noise.
- **Writing in the future or conditional tense.** An ADR records what was
  decided, not what is being thought about. That is what `Status: Proposed` is
  for.
- **Editing an old one so it fits today's reality.** That destroys the log's only
  value.

## Related

- `/promote-to-docs`: for the rest of the information that has to survive
- `/end-session`: where it gets detected that a decision went unrecorded
