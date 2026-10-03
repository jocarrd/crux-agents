---
name: code-health
description: Measure a repo's structural health and its trend: real duplication, long functions with branches, nesting, exports nobody imports, unused dependencies and which files churn the most. It saves a baseline to answer whether the code is worse than last time. Use when wondering about technical debt, whether this is rotting, or where to start cleaning up; before planning a refactor, when inheriting a repo, and after a stretch of generating lots of code with agents.
---

# code-health

Code review looks at **the diff**. This measures **the whole**, which is what
nobody looks at and what erodes slowly.

It matters especially when working with agents: the pattern measured across the
industry is that generated code sends **duplication** soaring, because the model
tends to repeat a solution instead of looking for the one that already exists in
the repo. It isn't noticeable in any specific diff; it is noticeable three months
later.

## Usage

```bash
node <this-skill-directory>/scripts/health.mjs [path] [--save] [--tests] [--top N]
```

No dependencies: it only needs files and git. It works on TypeScript,
JavaScript, Python, Go, Rust, Java and Ruby.

`--save` stores the baseline in `.crux-health.json`. **That is the point**: from
then on the question stops being "is this fine?" (which has no answer without
arguing over thresholds) and becomes **"is it worse than last time?"**, which
does.

Tests are left out by default. Their duplication is largely legitimate (the same
setup repeated) and drowns out that of the production code, which is the one that
matters. With `--tests` they are included.

## What it measures and how to interpret it

**Duplication.** Repeated blocks of logic, normalized so they don't depend on
formatting. It only counts what has real logic: multiline imports, object
literals and comments are filtered out, because otherwise they dominate the
report and make it useless.

> A block in two places may be chance. **In four it is a missing function.** If
> in addition it is in four files of the same module, the function is missing in
> that module.

**Long functions with branches.** Long is not the same as complex: a 1,500-line
data catalogue is not a problem. That is why only what is long **and** has
branching is reported. What is sought is "this does too many things", not "this
takes up a lot of space".

**Nesting.** Maximum depth per file. Beyond seven levels, the reader stops
holding the mental state.

**Exports nobody imports.** Dead-code candidates. **Careful**: they may be public
API consumed from outside, entry points or things used by reflection. It is a
list to review, not to delete.

**Declared and unused dependencies.** They are usually leftovers from something
that was tried. Each one is attack surface and install time.

**Most churned files.** From the git history. On its own it says nothing bad:
what is touched a lot is usually the heart of the repo.

## The reading that really matters

Cross two lists: **a file that shows up in both "most churned" and "deeply
nested" or "long function" is where the refactor pays for itself.** It is touched
a lot and hard to touch. Refactoring something complex that nobody touches is
wasted time.

## Cadence

It is not an everyday skill. It makes sense:

- Every so many weeks, to see the trend.
- Before planning a refactor, to choose **where** instead of going by intuition.
- When inheriting a repo, together with `/repo-map`.
- After a stretch of generating a lot of code.

Save the baseline the first time. Without it the report is a snapshot, and what
is valuable is the film.

## What to do with the result

1. **Duplication first.** It is the cheapest to fix and avoids the most debt:
   extracting a function is low-risk with immediate effect.
2. **Then the churned x complex crossing.** That is where the real refactor goes.
3. **Orphans and dependencies, in a separate cleanup pass.** They are background
   noise, not urgency.
4. **And what you are not going to fix, don't even look at.** A report that
   produces a wish list nobody executes stops being read.

## Anti-patterns

- **Chasing zero.** Some duplication is healthy; abstracting two things that look
  alike today but evolve differently is worse than repeating them.
- **Deleting orphan exports without checking.** It is the fastest way to break an
  external consumer.
- **Measuring without a baseline.** Absolute numbers invite arguing over
  thresholds; the trend admits no argument.
- **Turning it into a CI gate.** Blocking a commit over a structural metric
  breeds tricks, not quality. This informs decisions, it doesn't make them.

## Related

- `/ship`: the diff review, upstream of this
- `/repo-map`: orienting yourself in a repo, complementary when inheriting it
- `/write-tests`: before refactoring what this report points to
