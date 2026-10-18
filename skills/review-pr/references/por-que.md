# Why the review works this way

The procedure is in `SKILL.md`. Here is the reason for each rule.

## `/ship` does not cover it

A change can pass `/ship` clean and still be incomplete: the tests the author
wrote prove what the author thought of. The typical case is fixing a hole
through the door where it was found, while the same input arrives through
another that nobody looked at.

## Independent context

A thread that has just defended every decision is not in a position to refute
them: it tends to confirm what it already concluded and carries its earlier
reasoning along as if it were evidence.

The plan's review focus is the one thing from the author that does go in: the
failures they expect, which no test covers. It is checked first and does not
replace the rest, because the review is there for what the author did not
foresee.

## `crux review` prepares, it does not review

It gathers the material so the review does not depend on someone remembering to
collect it. The conventions are not provided by any command: they are written
in the repo's documentation and cannot be guessed.

## Why not every specialist is launched

Each one costs between 20,000 and 50,000 tokens depending on the size of the
change. Four on every proposal multiply the cost of reviewing by five, and most
would find nothing: a styles change has no queries or permissions. With the
split by diff, typo fixes launch none, a screen launches the UI one, and an
endpoint with a session or a migration launch two or three, which is where they
pay for themselves because the failure does not show in a screenshot.

Not every project deserves the same ceremony; that is why rigor moves the
thresholds.

## The order of the walkthrough

Each step depends on the previous one. Completeness is the question that pays
off most: a partial fix is worse than none, because it closes the matter in
everyone's head. A test that passes with and without the fix proves nothing,
and checking it takes a minute. Tests that pin the implementation turn any
future refactor into rewriting tests.

Debt is looked at separately because code written with assistance tends to add
redundancy in every change, and the diff looks clean because each piece, on its
own, is.

## Confirmed and well-written findings

"Consider improving error handling" sounds like a review and says nothing: whoever
reads it does not know whether to touch anything or where. A review with three
true findings gets read in full; one with fifteen, four of which are noise,
teaches people to ignore the next one.

## Two rounds at most

A third pass does not converge: it chases what the previous one broke, and each
pass finds something new because it looks at everything again.

## Telling it

A comment in a thread nobody opens until the following week ends up archived
and nothing more. Without the why, everything seems equally urgent and whoever
decides cannot prioritise. If it is not said what was reviewed without finding
anything, silence reads as "I did not look"; a review with no declared scope
reads as if it covered everything. After merging, whatever is found is already
part of the repo's code.
