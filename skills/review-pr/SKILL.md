---
name: review-pr
description: Review the code of an already-open proposal (PR) with a reviewer's judgement, not the author's: does the diff do what it says, is the fix complete, do the tests prove behaviour, does it fit what the repo already does, and what debt does it leave. Classifies the risk and launches in parallel only the specialist reviewers the diff calls for (security, data, performance, UI). Use right after opening a change proposal, before asking for human review, when you inherit another session's proposal, or when an agent wrote the change.
---

# review-pr

The review between opening the proposal and someone looking at it. `/ship` asks
whether what you did is ready; this asks whether what is being proposed is
correct and complete. The reason behind each rule is in
`<this-skill-directory>/references/por-que.md`.

## From an independent context

The review is done from a context different from the one that wrote the change:
an isolated review if the environment allows it, or a fresh session with **only
the diff and the proposal description**, without the history.

## What gets put in front of you

```bash
crux review
```

It gathers commits, the diff against the base, the proposal with its checks and
objective signals (code without tests, half-finished work, apparent
credentials, dependencies, files that grow). It also reads **the repo's
conventions** in its documentation.

## Risk and specialists

`crux review` ends with the risk and the specialists it deserves
(`crux review scope` gives that part alone):

| Risk | When | What is launched |
| ---- | ---- | ---------------- |
| low | no code, or 30 lines of code or fewer with nothing sensitive | only the general review |
| medium | ordinary code | the general one + the relevant specialists |
| high | security, data, or more than 500 lines | the general one + the relevant specialists |

Specialists: **security**, **data**, **performance** and **UI**, each with its
guide in `specialists/`. Launch **only the ones the script names**, three at
most, **in parallel and each in an isolated context**, with the diff, the
description and its guide, nothing else. They do not replace the general
review. If the script names none and you see something that calls for one,
launch that one and say why.

**Rigor** (`rigor` in `crux.json`):

- `light` (and repos without `crux.json`): specialists only on high risk;
  anything that is not high risk is merged without asking.
- `normal` (default): the above.
- `strict`: no 30-line shortcut, and it is never merged automatically.

**Who merges** is stated by the `merge:` line, and it overrides your judgement.
Only a change that is **text only** (`.md`, `.txt`, licences, `.gitignore`) in
an own project is merged without asking. CSS, styles, templates and tests count
as code: a CSS change, however small, is merged by a person. In a client repo,
always a person.

## The walkthrough

In this order:

1. **Fidelity.** Does the diff do what the proposal says, and only that? Files
   that are beside the point, formatting mixed with logic, debugging leftovers.
2. **Completeness of the fix.** Where else does this get in? Another command
   that accepts the same input without validating, another place that does the
   same calculation.
3. **Correctness.** Edge cases, empty values, unhandled errors, inverted
   conditions, order of operations. Every suspicion is reproduced before it is
   written down.
4. **Tests.** Do they exist? Do they **fail without the fix**? (revert the code,
   run, restore). Do they test behaviour or pin the implementation? Do they
   cover the failure path?
5. **Consistency.** Reinvented utilities, two ways of doing the same thing,
   names outside the convention, new dependencies for something already solved.
6. **Readability.** It is clear at first read what it does and why. Comments
   that narrate are surplus; comments that explain a why that cannot be deduced
   are missing.
7. **Debt and noise.** Duplication, needless abstractions, files that grow.
8. **Sensitive surface.** Secrets, unvalidated inputs reaching paths or queries,
   permissions, new dependencies.

## How a finding is written

```
file:line — what happens
why it matters: the concrete consequence
what fixes it: the line, not the sermon
```

Every finding is confirmed (reproduced, or citing the line that proves it)
before it goes out. **Those that are not confirmed are dropped.**

## What is done with them

- **Confirmed and clear:** fixed on the same branch, with its test, and `/ship`
  again.
- **Confirmed and debatable** (design or scope): posted on the proposal and the
  reviewer decides.
- **Doubtful:** not posted; checked first.

**Two rounds of fixes at most.** Each round reviews only what the fix touches.
If a serious finding remains after the second, stop and report what remains
open and what was tried.

## Telling whoever decides

The review ends by being told, not only left on the proposal. Per finding, in
this order: **what is wrong** (one sentence), **what you would change** (file,
line, fix; or that it is already done) and **why it matters** (the real
consequence).

- Ordered by what it would cost if it goes through.
- Separating what was fixed from what needs a decision.
- Saying what was reviewed without finding anything, and what was not reviewed.
- With no findings, it is still reported: what was looked at and by what
  criterion.

## Anti-patterns

- Reviewing in the same thread that wrote the code.
- Summarising the diff and calling it a review.
- Posting suspicions without reproducing them.
- Looking only at what the diff touches.
- Approving because the tests pass.
- Leaving it until after merging.
- Leaving the findings only on the proposal.

## Related

- `/ship` — the author's gate, upstream
- `/flow` — the full cycle; this is its step 6a
- `/root-cause` — when a finding needs debugging
- `/write-tests` — the missing test when the finding is real
