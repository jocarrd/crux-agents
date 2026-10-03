---
name: merge-conflicts
description: Resolve a merge or rebase left half done, hunk by hunk, by the intent of each side and not by what looks right on screen; then run the repo's checks and finish the operation. Use when git leaves unresolved conflicts, when a rebase stops midway, when `<<<<<<<` markers appear in files, or when the user says they have a conflict, don't know which branch wins or have got tangled up in the merge.
---

# merge-conflicts

A conflict is not resolved by reading both versions and picking the one that looks
better. Both looked fine when they were written. What has to be recovered is
**why** each one was written, and that is not in the hunk.

**Never `--abort`.** Aborting throws away the work of understanding the conflict
and leaves it the same for next time. If it truly has to be aborted, the user
decides.

## 1. See where you are

```bash
git status
git log --oneline --graph --left-right HEAD...MERGE_HEAD   # merge
git log --oneline REBASE_HEAD                              # rebase
git diff --name-only --diff-filter=U                       # conflicted files
```

In a rebase, `ours` and `theirs` are the opposite of how you read them: `ours` is
the branch you are rebasing onto, `theirs` is your commit. Checking this before
resolving anything avoids resolving the whole conflict on the wrong side.

## 2. Find the primary source for each side

For each conflict, find out what intent each version carried:

```bash
git log --oneline -3 <sha-of-that-side> -- <file>
git show <sha>                     # the full commit, with its message
gh pr list --search <sha> --state all   # the PR that brought it
```

The commit message, the PR and the issue are worth more than the code. If the
commit says "fix: the middleware loads on Edge again", that change has a reason
that isn't visible in the diff and gets lost if you discard it.

**If you can't find one side's intent, ask.** Resolving blindly is the way to
reintroduce the failure that commit fixed.

## 3. Resolve hunk by hunk

- **Keep both intents** whenever possible. Most conflicts are two compatible
  changes that touched neighbouring lines.
- **If they are incompatible**, the one that meets the declared goal of the merge
  wins, and the other is noted as an accepted cost.
- **Don't invent new behaviour.** A conflict exists so that two changes that
  already existed survive. Improving the code along the way goes in a separate
  commit.
- **Generated files are not resolved by hand.** `package-lock.json`, Prisma
  clients, snapshots: they are regenerated. `git checkout --ours` on the file and
  then the command that generates it.

## 4. Run the repo's checks

A resolved merge compiles but doesn't work more often than it seems: each side was
coherent on its own and the union isn't.

Find out what the repo checks and run it, normally in this order: typecheck,
tests, formatting. In a repo with `/ship`, run it.

## 5. Finish

```bash
git add -A && git commit        # merge: don't rewrite the default message
git rebase --continue           # rebase: until no commits remain
```

In a rebase, conflicts can appear in several commits in a row. Go back to step 1
with each one.

---

*Adapted from the `resolving-merge-conflicts` skill of
[mattpocock/skills](https://github.com/mattpocock/skills), MIT license.*
