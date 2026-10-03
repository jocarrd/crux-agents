---
name: e2e
description: Write and maintain end-to-end tests that do not get abandoned: choose the few flows that really deserve them, explore the application before writing, make them resistant to layout changes and fix the one that breaks instead of disabling it. Use when a critical flow has no safety net, when a failure has reached users without anyone noticing, or when the existing suite is disabled because it fails on its own.
---

# e2e

End-to-end tests are the most expensive to write, the slowest to run and the
only ones that prove that **the whole system works together**. That combination
makes almost every suite end up disabled.

This skill is about not getting there.

## The criterion, before the tool

> **A flow deserves an e2e if its breakage is reported to you by a user and not
> by a test.**

That is the question, and it rules out almost everything. Three or four flows
per product, not forty:

- **Getting in.** Authentication, session, permissions. If this breaks, nothing
  else matters, and it breaks for causes that unit tests do not see: a key baked
  into the build, a misconfigured domain, a cookie.
- **The action that generates the value.** Publishing, buying, sending,
  booking. The one that, if it fails, is an incident.
- **The surface that cannot be simulated.** A map that renders, a payment, a
  document that gets generated.

And what does **not** deserve an e2e, however tempting: form validations, texts,
empty states, variations of the same list. Those are unit or component tests,
which cost a hundred times less.

**Ten e2e tests that run are worth more than forty disabled ones.**

## The cycle, in three roles

It is the pattern that has taken hold in the industry, and it works the same
with or without specific tools:

**1. Explore and plan.** Walk through the running application and write in
markdown what the flow does, step by step, with what is actually observed. This
plan is reviewed **before** writing anything: correcting a plan costs a minute,
correcting a suite costs an afternoon.

**2. Generate.** Turn the reviewed plan into executable tests.

**3. Repair.** When one fails: diagnose, propose the fix and run again. A broken
test is one of two things, and you have to decide which **before** touching it:
either the product broke —and then the test did its job— or the test was
fragile.

**None of the three roles produces something that can be accepted without
looking at it.** They speed up the evidence and the draft; not the decision.

## Keeping them from becoming fragile

Fragility is the real reason suites get abandoned. Four rules:

**Select by role and visible text, not by structure.** A selector tied to the
element hierarchy or to utility classes breaks with any layout tweak, without
anything having stopped working. If an element cannot be selected by what it is,
give it an explicit test attribute: that is a contract, not a patch.

**Do not add fixed waits.** An arbitrary timeout is slow when it is too long and
fails when it is too short. Wait for the condition: that the element is there,
that the request finishes, that the text changes.

**Each test creates and destroys its own data.** A test that depends on a
certain record existing works until someone deletes it. And two tests that share
state break as soon as they run in parallel.

**Isolate what you do not control.** External services, payments, email. In e2e
they are intercepted or their test environment is used: a test that fails
because someone else's API is slow tells you nothing about your product and
teaches people to ignore reds.

## Where to run them

If the project has isolated workspaces, the suite goes in its own: its own ports
and data. Sharing a database with your development environment is the fastest
way for a test to delete something of yours while you work.

## On cost

There are integrations that expose the browser to the agent very conveniently.
Before adopting them it is worth knowing that **the reported consumption is
around four times** that of doing the same through the command line for
equivalent coverage.

On a large team it may pay off. Working alone, the bottleneck is the cost per
session: **use the three-role cycle, but through the CLI**.

## When one fails at the commit gate

A red e2e stops the work, so the temptation to disable it is high. The rule:
**disabling an e2e is a decision that gets recorded**, with date and reason. A
commented-out test with no explanation is invisible debt; one disabled on
purpose and noted is a reviewable decision.

## Anti-patterns

- **Covering the happy path of everything.** Broad and shallow coverage catches
  nothing and costs on every run.
- **Writing e2e for logic.** If it can be tested without a browser, it is not an
  e2e.
- **Fixing the test without asking whether the product broke.** It is the way to
  turn a suite into decoration.
- **Suites that take so long they run only at night.** What does not run when
  something changes does not protect the change.

## Related

- `/write-tests` — everything that can be tested without a browser, which is
  almost everything
- `/visual-test` — look at the interface; complementary and much cheaper
- `/workspace` — the isolated environment where the suite runs
- `/ship` — the gate that decides when it is necessary to go this far
