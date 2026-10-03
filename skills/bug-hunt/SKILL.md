---
name: bug-hunt
description: Hunt for bugs nobody has reported yet in your own tooling (commands, scripts, installers) by exercising it in a disposable environment with the inputs nobody tries, and measuring each finding before proposing the fix. Use when you want to harden something that already works, before showing it to an outsider, after a large batch of changes, or when asked "busca bugs" or "a ver si esto aguanta".
---

# bug-hunt

Look for failures nobody has reported yet. `/root-cause` debugs a failure you
already have; this one finds the ones you don't know you have.

The core idea: **the happy path has already been walked by its author**. Bugs
live at the edges (the corrupt, the missing, the simultaneous, the repeated)
and in diagnostics, which are almost always less tested than the feature.

## When to use

- You are about to show the tool to an outsider and want their first hour not to
  crash.
- You just landed several changes and don't know what got misaligned.
- You want to harden something that "already works".

## When not to use

- **You have a specific failure in front of you**: that is `/root-cause`.
- **You are looking for structural debt** (duplication, huge functions): that is
  `/code-health`. This skill looks for incorrect behaviour.
- On third-party code you won't be able to fix.

## 1. A disposable environment, never the real data

First of all, a place to break things without consequences: a temporary
directory, redirected environment variables, fake credentials, local remotes
instead of real services.

If the tool writes to the user's directory, redirect that too. A hunt that dirties
the real environment ends up costing more than the bugs it finds.

## 2. Walk the real path first

Exercise the full cycle the way an outsider would, from start to finish, before
touching any edge. This calibrates what is normal and, along the way, catches
whatever is broken head-on.

## 3. Then, the edges

The ones that pay off, in order of return:

- **Corrupt configuration.** Not missing: half-corrupt. A contract file with
  truncated JSON reveals whether the program distinguishes "it isn't there" from
  "it can't be read".
- **What is missing where something was always present.** No remote, no network,
  no credential, no permissions.
- **Repeat.** Run the same thing twice. The second run reveals what gets
  duplicated, what gets overwritten and what breaks.
- **At the same time.** Launch three instances in parallel against the same
  resource.
- **Hostile names.** Spaces, accents, slashes, empty strings.
- **Inherited state.** A configuration from an earlier version, a half-migrated
  directory. It is the case only long-time users suffer, and that is why it is
  never tested.

## 4. Before calling it a bug: read the intent

Many oddities are decisions. Before fixing, look for the file header, comment or
documentation that explains why it is the way it is. If the behaviour is
deliberate but leaves the user with no way out, the fix is to **say what the next
step is**.

## 5. Measure before proposing

An improvement that looks obvious must be **measured against the real data**
before it is written. Apply the proposed change to the history and see how many
cases it affects and how many false positives it creates.

Discarding an improvement after measuring it is also work done.

## 6. One fix, one test that fails without it

For each finding, validate the test by **removing the fix** and seeing it go red.
A test that passes before and after proves nothing.

And the test has to exercise **the real command**. If you copy its logic into the
test in order to test it, you are testing the copy. When the command depends on
something external, replace that binary with a fake one on the PATH that returns
whatever is needed: that keeps the test offline while still testing the real
code.

## Gotchas that keep showing up

These are shell gotchas, but the pattern repeats in any language: **a swallowed
error becomes a false datum**.

- **Silencing error output does not cover input redirection.** The interpreter
  resolves it before running the command, and its error comes out anyway.
- **Counting lines with a tool that fails when there are none**, and chaining a
  default value onto it, produces **two** values glued together.
- **Aborting at the first error inside a loop** leaves the task half done and
  reports success: the remaining items are never even attempted.
- **Asking whether a branch is merged** does not work where merging squashes the
  commits: you have to ask about the proposal, not the graph.
- **A default derived from the install path** is right in development and wrong
  in production, and nobody notices for months.

## Close

Delete the disposable environment and check that nothing is left outside:
processes started, temporary files, branches or resources created during the
tests.

## Related

- `/root-cause`: when you already have the failure in front of you
- `/write-tests`: how to write the test that goes with the fix
- `/code-health`: structural debt, not incorrect behaviour
