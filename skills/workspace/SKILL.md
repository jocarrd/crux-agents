---
name: workspace
description: Create isolated workspaces to work on several tasks of the same repo at once, splitting not only the files but also the runtime: own worktree, reserved port range, separate database and derived environment file. Use when you are about to launch several tasks in parallel on a repo, when you need to touch two branches at once without stashing, or when two processes are fighting over the same port.
---

# workspace

A worktree isolates the files, but not the runtime: two parallel tasks still
fight over the port, the database and the environment file, and the failure
shows up as silently corrupted data. This skill splits both. The reason behind
each decision: `<this-skill-directory>/references/por-que.md`.

## Usage

```bash
crux workspace new <name> [--repo <dir>] [--branch fix/something] [--task <task>] [--goal "what and why"]
crux workspace list
crux workspace finish <name>          # pushes the branch and opens the proposal
crux workspace merge <name> [--yes]   # without --yes it only shows the state
crux workspace rm <name>
crux workspace adopt <path>           # registers a worktree created by hand
```

`new` creates the worktree at `<repo>-ws-<name>` (next to the repo, so that
paths relative to the docs repo resolve), on a new branch, reserves a slot,
writes the environment file and registers the task.

**The branch is published:** by default it is `ws/<name>`; in a client repo, set
the name with `--branch` (the command warns if the profile is `client-repo`). If
the profile forbids writing outside the docs repo, `new` refuses except with
`--force`, only if the client authorises it.

## Configure the split

In `crux.json`, `workspace` section:

```json
"workspace": {
  "portBase": 3000,
  "portsPerSlot": 10,
  "envFile": ".env.local",
  "env": {
    "PORT": "{{PORT0}}",
    "ENGINE_PORT": "{{PORT1}}",
    "DATABASE_URL": "postgres://localhost/app_ws{{SLOT}}",
    "REDIS_URL": "redis://localhost:6379/{{SLOT}}"
  }
}
```

Substitutions: `{{SLOT}}`, `{{PORT0}}`…`{{PORTn}}`, `{{NAME}}` and `{{BRANCH}}`.
Without this section only ports are reserved; fill it in.

What to isolate, in order of damage: **ports**, **database** (one database or
schema per slot; in Redis, a database number), **environment file**, **volumes
and caches with state**. Shared external resources (webhooks, queues, buckets)
are not isolated: do not launch in parallel tasks that touch them.

## Before launching tasks in parallel

- Split by surface, not by file.
- A task with migrations goes alone: the schema is shared as soon as the
  branches come together.
- Name the spaces after the task (`fix-login`), not by number.

## The space's task

The log lives in `~/.crux/tasks/<project>/<task>.md`. If the task touches
another repo, another space is opened there with the same `--task`.

```bash
crux task                          # state, steps and next step
crux task add "step" "another step"   # returns T1, T2…
crux task done T1 "what proves it"
crux task next "the next thing"
crux task note "deviation from the plan"
crux task note "what was decided" --why "why" --where "where it lives" --learned "what was learned"
crux task plan <file>              # the approved plan
```

It is annotated **while working**, in the language of the repo's commits: the
proposal's description comes from there. Notes with `--why` move on their own to
`repos/<repo>/notes.md` of the docs repo when the task is archived.

## Closing the cycle

- `finish` refuses if anything is left uncommitted or if the commit has not
  passed the quality gate. The `pre-push` prevents pushing straight to the main
  branch of a code repo.
- `merge` looks at CI, conflicts and changes requested in the review, and
  **never merges without `--yes`**. If the repo has no CI, it says so: that is
  not the same as being verified.
- **A space is closed with `crux workspace rm`**, never with `git worktree
  remove` or `rm -rf` (a hook stops it). `rm` refuses if there are uncommitted
  changes, frees the worktree and the slot, and leaves the branch. If it was the
  last space of a merged task, it archives it. `merge --yes` already closes the
  space on merging.

## Related

- `/ship` — the quality gate before committing
- `/flow` — the full cycle
