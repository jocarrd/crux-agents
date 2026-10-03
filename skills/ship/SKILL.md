---
name: ship
description: Quality gate before committing, graded by what the diff touches: classify the change to know which gates apply, confirm the affected tests are green, read the full diff, review correctness, look for the simplest implementation, run the whole suite, validate in the real environment only if the change touches an observable surface, check whether any documentation has drifted and commit. Use when you finish a piece of work and are about to commit, or when you want a serious review of what you have done so far.
---

# ship

A chain of gates before committing. It stops as soon as one fails. The reason
behind each rule is in `<this-skill-directory>/references/por-que.md`; read it
if you doubt one or are about to propose an exception.

## 0. Which gates are needed

First of all:

```bash
bash <this-skill-directory>/scripts/diff-scope.sh
```

It says which gates apply, which tests to run in gate 1 and whether the
environment has to be brought up. The classifier decides, not your judgement.

| What the diff touches | Gates |
| --------------------- | ----- |
| Text only (documentation, licences, `.gitignore`) | 2, 8, 9 |
| Code not visible from outside | 1 to 6, 8, 9 |
| Observable surface: UI, API, data, dependencies, integration | all |

## 1. Sanity

Run the affected tests (the classifier's `tests:` line), not the whole suite,
before looking at anything. If they were already red, it is not your diff: say
so and stop.

If the report has `artifacts:` (screenshots, dumps, stray temporaries in the
root), take them out of the stage or add them to `.gitignore`. They are never
committed.

## 2. Read the diff

All of it. Check that it does exactly what was intended. Stop and ask if there
are files that were beside the point, formatting mixed with logic, dead code or
debugging leftovers.

## 3. Correctness

Edge cases, nulls, unhandled errors, inverted conditions, concurrency. If there
is an automatic review, it goes here.

## 4. Conventions

```bash
bash <this-skill-directory>/scripts/conventions.sh
```

It lists the convention documents that apply and concrete signals (repeated
literals, types in constants files, redeclared catalogues). The signals are
heuristics; **opening the documents it lists is not optional**.

## 5. Quality

Only now: is there a simpler way? Reuse what exists, abstraction at the right
level, names that say what they do.

## 6. Regression

The whole suite, after the fixes from 3 to 5.

**A test that already existed and turns red is not edited to make it pass.**
Stop and say so. It is only changed if whoever decides confirms that behaviour
is no longer wanted.

## 7. Reality, only if gate 0 asks for it

| What the diff touches | What to validate |
| --------------------- | ---------------- |
| UI | See it in the viewports that matter; then `/before-after` so whoever decides approves it |
| API | Call the affected endpoints, not just their tests |
| Data | That the migration applies **and rolls back** |
| Dependencies | That it starts from scratch, not from your cache |

Bring up the environment in the task's workspace.

## 8. Documentation drift

If the change invalidates any documentation, it is updated in the same turn.
The classifier's warning is a signal, not a verdict.

## 9. Commit

Conventional commit, imperative and lowercase, with a body that explains the
why. One type of change per commit.

## Leaving a record

The checks run through crux, which records the real result:

```bash
crux ship gate                  # what quality.gate in the contract declares
crux ship run -- <command>      # a single check
crux ship seal                  # after the commit
```

`seal` refuses if anything is left red and closes the receipt against HEAD.
`crux workspace finish` does not open the proposal without that receipt.
`finish --skip-gate` exists only to obey whoever decides, never to save
yourself a step.

`.crux-ship` goes in the repo's `.gitignore`.

## Before publishing the proposal

```bash
crux ship body <file with the body>
```

It looks for the tool's signature and, in `client-repo` profile, any mention of
our tooling.

## Anti-patterns

- Deciding the gates by eye instead of with gate 0.
- Running all nine on a documentation change.
- Starting at 3: without 1 you do not know whether the red is yours.
- Closing 4 without opening the document.
- Simplifying (5) before verifying (3).
- Skipping 6 because the change was small.
- Considering 7 passed without having seen the screen or called the endpoint.
- Committing with a gate red.

## Related

- `/workspace` — the isolated environment for gate 7
- `/visual-test` — the visual review for gate 7
- `/end-session` — closing the session
