# Why the gate works this way

The procedure is in `SKILL.md`. Here is the reason for each rule, for when you
need to decide whether an exception makes sense.

## The gate is graded

If it costs the same for a typo as for a schema change, it stops being invoked
within two weeks and the gate fails. A documentation-only change has no code
that can be wrong and no tests that can regress: running all nine gates on it
does not verify it any more, it only makes it more expensive.

The classifier decides because by eye everything looks small, and that is how
the very gate that was needed gets skipped.

## Sanity first, and only with what is affected

Gate 1 answers one question: was the red already there before? The affected
tests are enough for that. The whole suite is gate 6; running it in both is
paying the most expensive one twice to answer two different questions. It is
the cheapest gate and the one that saves the most time: it avoids spending half
an hour debugging a failure that was already there.

Stray artefacts in the root are dragged in by a `git add -A` without any test or
the linter seeing them.

## Conventions before quality, and quality after correctness

Conventions are usually read after writing the code, when they only serve to
reorder things. Self-assessing style without opening the document always comes
out as a yes: that is why the gate lists files and does not ask questions.

Restructuring twice is throwing the work away: a convention applied later forces
you to move what the quality gate was going to simplify, and simplifying
incorrect code is also throwing it away.

## The whole suite at the end

The fixes from gates 3 to 5 also break things, and they break exactly what you
were not looking at.

A test that already existed and turns red is usually right, and the diagnosis
is not. Editing it to make it pass erases the only proof that the change breaks
something.

## Bring up the environment only when needed

Always bringing it up kills the habit; never bringing it up lets through the
failures the tests do not see. In the task's workspace you do not collide with
your own development server.

## Documentation, in the same turn

It is the discipline that holds the whole standard together. Many changes do not
affect any doc, which is why the classifier's warning is a signal and not a
verdict.

## The receipt

Before, the agent itself wrote a sha after claiming to have verified. That does
not prove it verified: it proves it wrote a sha. That is why the checks go
through `crux ship run`, which runs the command and records the real result,
and `finish` demands the receipt sealed against HEAD.

`crux ship body` exists because the proposal description was the only artefact
of the flow that nobody checked, and it is the one that ends up in front of the
client.
