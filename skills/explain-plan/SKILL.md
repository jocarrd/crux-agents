---
name: explain-plan
description: Present a technical proposal so that it can be decided on: what changes, what was checked to get there, what breaks if it is a mistake, which alternatives were discarded and what remains unresolved. Includes when to use a table, when a diagram and when prose. Use before implementing something non-trivial, when there are several reasonable ways to do it, or when whoever decides is not the one who will write the code.
---

# explain-plan

A plan is written **so that someone can stop it in time**: it is measured by how
long it takes the reader to see that it is wrong. The reason behind each
section: `<this-skill-directory>/references/por-que.md`.

**Use** before implementing something that touches more than one module or that
cannot be undone in five minutes, when there are several reasonable ways, or
when someone who does not write the code decides. **Do not use** on bounded and
obvious changes, nor with the work already done (then `/adr`).

## The five sections

None out of habit: if one adds nothing, it is dropped.

1. **What changes.** One sentence and the real scope: what is touched and what
   stays out. It goes on top because it is the first thing discussed.
2. **Why this way: the trace.** Not the conclusion, but **what you checked to
   get to it**: what you looked at, what you found, what ruled out the obvious
   path. Write "I checked X and it turned out Y".
3. **What breaks if I am wrong.** The reverse and its cost. If it is undone with
   a `git revert`, say so; if it involves migrating data, say it louder.
4. **Discarded alternatives, with the reason.** "X was discarded" is no use; "X
   was discarded because it forces maintaining two formats in parallel" is.
5. **What I do not know.** The open questions, explicit.

## The form

| Content | Form |
| ------- | ---- |
| Comparing options | Table |
| Flow with several actors or steps | Sequence diagram |
| Dependencies between pieces | Graph |
| States and transitions | State diagram |
| The why, the tradeoffs, the risks | Prose |
| Figures and measurements | In the text |

Draw only what is not seen by reading.

## Where it stays

Once approved, it goes to the task log: `crux task plan <file>` saves it and
marks the task as planned; the steps that come out of it, with `crux task add`.

## It closes when it is executed

When finished, the plan receives a status header: what is done, with which
commit and, above all, **what turned out different from what was planned and
why**. A plan that keeps describing as pending something already done lies like
outdated documentation. Closing is not archiving: it stays as the why.

## Anti-patterns

- The decorative diagram of four obvious boxes.
- The plan that is a list of steps without a why: it cannot be rejected.
- The full template out of habit.
- Implementation detail: variable names and signatures go in the code.
- Presenting only the conclusion, without the trace.
- The orphan plan, which nobody closes.

## Related

- `/adr` — record what is already decided
- `/ship` — the gate that reviews the plan's implementation
