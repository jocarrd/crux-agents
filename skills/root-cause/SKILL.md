---
name: root-cause
description: Debug with discipline: reproduce before touching anything, measure instead of assuming, narrow the search space by bisection and separate the symptom from the cause. Use when something fails and you don't know why, when a previous fix didn't hold, when the failure only happens in production, or when you are about to propose a solution without having understood the problem.
---

# root-cause

The most common mistake when debugging is **proposing the fix before understanding
the problem**. It usually works just well enough the first time to hide the real
cause, which reappears a month later wearing a different face.

## The rule

> **No fix is proposed until you can explain why it fails and prove it.**

If you can't reproduce it or point to the line, you are still investigating, even
if you have a very convincing theory.

## 1. Reproduce

Without reproduction there is no debugging: there is guessing. And you can't tell
whether your fix worked either, because you have nothing to check it with.

Write **the minimal case that fails**: what input, what prior state, what
sequence. If it only fails sometimes, that intermittency is a datum, not an
obstacle: it points to timing, ordering, concurrency or cache.

If it doesn't reproduce locally but does in another environment, the difference
between the two environments **is the main clue**. List it: versions, variables,
data, permissions, latency, time zone.

If it only fails in production, **start with what production already knows**:
`/prod-signals` summarises its logs and says which error, how many times and
since when. It is more reliable data than the account of whoever saw it.

## 2. Measure, don't assume

Every claim during debugging needs evidence behind it. "The parameter must be
arriving wrong" is not enough: print the parameter.

Instrument the whole path before looking at the detail: what goes in, what comes
out of each layer, what was called and with what. Most hard bugs are solved on
seeing that **the data was already wrong three layers earlier**.

## 3. Narrow by bisection

The most profitable technique and the least used.

- **In time**: if it used to work, find the commit that broke it. Bisecting the
  history gives the answer in a few steps.
- **In space**: split the system in half and check which side the failure is on.
  Repeat. Ten layers are covered in three or four tests.
- **In the data**: reduce the input until removing one more thing makes the
  failure disappear. What remains is the cause.

## 4. Separate symptom from cause

Ask "and why does that happen?" until the answer is something you can change and
that explains **all** the observed symptoms, not just the one that was reported.

Signs you have stopped at the symptom:

- The fix is a special case for one particular input.
- It adds a defensive check without knowing who sends the data wrong.
- You couldn't say why the bug didn't show up before.
- It works but you can't explain why.

That last one is the most dangerous: **if you don't know why it works, you don't
know when it will stop working**.

And if fixing it turns an existing test red, **don't edit it**: stop and review
the diagnosis. It is almost always the cause that is wrong, not the test.

## 5. Write down what you learned

Two outputs, and both matter:

**A test that reproduces the bug**, written before the fix and failing before it
is applied. It is the only proof that you understood the problem.

**A note where it is needed**, if the cause was something not deducible from the
code: odd behaviour in a dependency, an infrastructure setting, an assumption
that turned out false. That doesn't fit in a comment and is lost if it isn't
written in the project documentation.

## When the system isn't yours

If the code belongs to someone else, or someone else decides what counts as a
bug: **record measurements, not diagnoses**. Note what was measured, how to
reproduce it and what question it opens. Don't declare something an error or
conclude what is wrong without validation from whoever has the authority to say
so.

And always distinguish what was measured from what was read in earlier
documentation: documentation describes the intent at the time it was written, not
the current state.

## Anti-patterns

- **Changing things to see if it gets fixed.** If it works, you won't know why;
  if not, you will have muddied the ground.
- **Fixing the first symptom.** There is often a common cause behind three.
- **Accepting your own theory without checking it.** The first theory is free;
  checking it costs two minutes.
- **Debugging with a warm cache.** Half of the failures that don't reproduce come
  from a prior state you haven't cleared.

## Related

- `/write-tests`: the regression test that closes the bug
- `/prod-signals`: what the production logs say, summarised
- `/ship`: the gate that stops the fix from breaking something else
