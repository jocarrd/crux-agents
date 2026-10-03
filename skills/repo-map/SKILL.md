---
name: repo-map
description: Build, in a few minutes, the map of a repo you don't know or haven't touched in months: where execution enters, what layers exist, where each kind of thing lives, what conventions it follows and which zones are best not touched without warning. Use when returning to a dormant repo, entering someone else's, before a big task, or when the documentation isn't enough to orient you.
---

# repo-map

Orient yourself before touching anything. The goal is to know **where to look**
for the task in front of you, without having to understand the whole repo.

## When to use

- You return to a repo you haven't touched in months.
- You enter one you didn't write.
- You are about to take on a change that crosses several layers.

## When not to use

- You already have documentation for the repo and the task is small: read it and
  go.
- The task touches a file you already know.

If the project follows the standard, **always start with its documentation**
(`repos/<repo>/`). This is for when that documentation doesn't exist, has fallen
short, or you want to verify it against reality.

## The walkthrough, in this order

**1. Where execution enters.** Entry points say more than any README: server
startup, routing, commands, scheduled jobs, queue consumers. Everything else
hangs from there.

**2. How it is brought up and how it is tested.** The declared scripts and the
container configuration. This answers the practical question: what do I need
running to see anything.

**3. The shape of the tree.** Which top-level folders exist and what each means.
Here you see whether the project follows a layered architecture, a domain-based
one, or none.

**4. Where the domain is.** The code that holds the business rules, not the code
that talks to the world. It is usually the smallest part and the most important:
if you have to understand only one thing, it is this.

**5. The boundaries.** What is called over HTTP, what shares a database, what
depends on external services. Boundaries are where the interesting bugs live and
where a change propagates to other repos.

**6. The real conventions.** Not the declared ones: the ones you can see. How
files are named, how errors are handled, how dependencies are injected, where the
tests go. A change that respects them goes unnoticed; one that doesn't annoys
everyone.

**7. The sensitive zones.** What a careless change breaks at high cost:
migrations, authentication, public contracts, artifact generation, anything with
persistent state. It is worth knowing which they are before touching, not after.

## Signals worth looking at in the history

- **The files that change the most** are usually the heart of the repo, or its
  pain point.
- **The ones nobody has changed in years** are either very stable or dead code.
  Check which of the two before trusting them.
- **The size of recent commits** says how whoever maintains it works.

## What to produce

A short summary, not a treatise. One page at most:

- What the repo does, in one line.
- Entry points, with their path.
- The three or four folders that matter and what lives in each.
- How it is brought up locally.
- Boundaries to the outside.
- Sensitive zones.
- **What you haven't understood**, stated explicitly.

That last point is the most valuable and the one that is always omitted. A map
that pretends to cover everything is worse than one that points out its gaps.

## Afterwards

If the repo belongs to a project under the standard and this information wasn't
written down, **write it**: `repos/<repo>/README.md` or the relevant topic file.
Having done the work twice for not noting it the first time is exactly what the
standard exists to avoid.

## Anti-patterns

- **Reading the code in alphabetical order.** You follow the execution, not the
  listing.
- **Trusting the documentation without verifying a single thing.** A quick check
  against the code reveals whether it is alive or mummified.
- **Producing an exhaustive map.** Nobody reads it, including you a month from
  now.

## Related

- `/promote-to-docs`: so the map survives the session
- `/root-cause`: to find a specific failure
