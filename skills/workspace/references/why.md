# Why workspaces are the way they are

The procedure is in `SKILL.md`.

## The runtime is what gets forgotten

A worktree separates the files and seems enough. But two processes sharing a
port do not start, and two sharing a database start, work and trample each
other's data. It is worse than a merge conflict because it gives no warning.
Filling in the contract's `workspace` section is the difference between being
able to launch two tasks and being able to launch five. If two spaces read the
same `.env`, isolating ports and database is of no use.

## Why the worktree goes next to the repo

The standard rests the context pointers on relative paths
(`../<project>-docs/`). From a directory outside the project those paths do not
resolve, and the space's agent would be left without the project's context.

## The branch name

The space's name is local; the branch's is published. In a client's repo,
`ws/<name>` would end up visible with our naming and in the language of the
name.

## Client profiles

A worktree creates a branch in the origin repo, and that is writing into someone
else's code. Needing `--force` makes it a decision.

## Parallel

Two tasks on the same file end in a conflict that you resolve. Migrations go
alone because the schema is shared as soon as the branches come together again.
`fix-login` tells you what is inside two days from now; `ws-3` does not.

## The closed main branch

The `pre-push` rejects direct pushes to main in code repos and in the kernel. A
`--no-verify` skips it: the real protection is on the server side, and in a
private repo without a paid plan it is not available. It covers carelessness,
which is the real case. Docs repos are pushed directly, as their rule says.

## Why `merge` asks for `--yes` and `rm` leaves the branch

The decision to merge belongs to a person; the command only makes sure it
arrives informed. The space is disposable and the work is not, which is why the
branch survives `rm`. The shortcut of deleting by hand leaves the entry in the
registry and the task unclosed.
