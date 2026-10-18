---
name: flow
description: The complete cycle of a development task: the order of its seven steps, why each one exists and what you pay for skipping it. It does not replace them, it chains them. Use when receiving any non-trivial development task —touching code, building a feature, fixing something, following the project's conventions— and before planning anything, especially if you are going to work in parallel with another session on the same repo.
---

# flow

The order in which the cycle's skills are used. The why of each step and what it
costs to skip it are in `<this-skill-directory>/references/por-que.md`.

**Applies** to any task that is going to produce a commit. **Does not apply** to
questions or code reading, to obvious one-line changes (a typo, a config value)
or to an emergency in production, where the incident playbook rules and the
order is recovered afterwards. If in doubt, apply it.

**Long waits run in the background.** The suite, the gate, the CI, a deployment,
a sub-agent: launch it in the background, say it is running and carry on with
work that does not touch the tree being tested, such as another task, the next
fix or the proposal text. Commit before launching the gate: the receipt is for
HEAD, and editing while it runs tests something other than what gets committed.

## 1. Understand the terrain

If you do not know the repo: `/repo-map`. If the project follows the standard,
its documentation comes first: `repos/<repo>/` in the docs repo. Code is not
written to find out how something works.

## 2. Isolate the space

```bash
crux workspace new <task-name>
```

The branch is created here, before touching a line, with its worktree, its ports
and its database. It also opens the task log, which is filled in while working
(`crux task`). Skip it only if you are sure nobody else works on that repo; the
command warns if another space is open.

## 3. Plan before touching code

- `/grill` if the request leaves decisions open.
- `/explain-plan` for any task that is not obvious. If it will be built from
  the text alone, it goes through the builder check first; if the work is split
  between several agents at once, each part carries its interfaces.

The plan is approved before continuing; if you are not the one who decides, ask
here. Once approved, it is saved: `crux task plan <file>`.

## 4. Develop

With the project's conventions, which are in its docs repo. During development,
not at the end:

- Tests for what hurts if it fails: `/write-tests`. A bug that can be
  reproduced, or logic whose contract is known beforehand: the test first, red
  for the right reason, then the code.
- If something breaks and you do not know why: `/root-cause` before fixing.

## 5. The gate

`/ship`. No red gate is left "for later".

### 5a. Show what can be seen

Only if the diff touches UI, after `/ship` and before pushing anything:
`/before-after` on desktop, tablet and mobile, and wait for the yes from whoever
decides. With the yes, `crux visual approve`. If there are changes afterwards,
it is shown again.

## 6. Propose

```bash
crux workspace finish <name>
crux checks --wait        # in the background
```

`finish` refuses if anything is left uncommitted or if the commit has not passed
the gate. The CI wait goes **in the background**: say that it is running and
carry on with something else.

If the CI comes back red: read only the end of the log, fix on the same branch,
run `/ship` and push. **Three attempts at most**; on the third, stop and report.
A proposal without CI is not verified, and it is said so.

### 6a. Review the proposal

`/review-pr`, from a context different from the one that wrote the change. It
launches only the specialists that `crux review` names. If the plan has a review
focus, the review starts there and then covers the rest.

### 6b. Merge, when you authorise it

```bash
crux workspace merge <name>          # shows the state
crux workspace merge <name> --yes    # merges
```

Without `--yes` it does not merge. It is only merged without asking if the
`merge:` line of the review allows it (text only, own project). With code or in
a client repo, always ask.

### 6c. Watch the deployment

If what was merged deploys itself: `/deploy-watch`, also in the background. It
is not considered published until it is seen. If it fails, revert first and
investigate afterwards with `/prod-signals` and `/root-cause`.

## 7. Close

`/end-session`: what was learned that does not stay in the code is written
where it survives the session, and the task is closed. Decisions noted with
`crux task note --why` move on their own to the docs repo when it is archived.

## Anti-patterns

- Chaining the steps without thinking: a typo does not need a plan.
- Announcing a step instead of taking it.
- Simplifying before verifying, or isolating after starting.
- Leaving a space open for weeks.

## Related

`/repo-map`, `/workspace`, `/grill`, `/explain-plan`, `/write-tests`,
`/root-cause`, `/ship`, `/before-after`, `/review-pr`, `/merge-conflicts`,
`/deploy-watch`, `/prod-signals`, `/end-session`.
