# Why the plan works this way

The procedure is in `SKILL.md`.

## A plan is written to be stopped

A plan that says "I am going to change the cache key format" is rejected in five
seconds with "no, that breaks existing keys, use a versioned prefix". The same
fix after writing the code is a diff to review and probably revert.

## The trace

It is the section almost nobody writes and the one that makes the plan useful.
Whoever reads does not have to reconstruct your reasoning or trust it: they
verify it. And it forces specificity: when writing "I checked X and it turned
out Y" you discover the times you did not in fact check it.

## The reverse

It distinguishes a round-trip decision from a one-way one, and therefore how
much thought it needed. A `git revert` lowers the bar of the discussion.

## Alternatives with a reason

They avoid repeating the same analysis three months from now, and allow someone
to say "that reason no longer applies, let us reopen".

## What I do not know

A plan that pretends to cover everything is worse than one that points out its
gaps: the gap is still there and now it is also hidden.

## Review focus

Tests cover what someone thought of testing. The failures that get through are
the others: a race, a value nobody expected, a migration that runs twice. The
author knows best where those are while writing the plan, and the reviewer
arrives without that knowledge. Writing them down tells the review where to
look hard first. It does not replace the rest of the review, which exists for
what the author did not foresee.

## The builder check

The author reads the plan with the whole conversation in their head and fills
every gap without noticing. An agent that builds from the text has only the
text, and when something is missing it guesses. A reader with no context finds
those gaps in minutes, before they become a diff built on an assumption.

## Interfaces only when split

Two agents working in parallel do not see each other's code until the end. If
the contract between their parts is not fixed beforehand, each invents its own
and the integration fails. With a single builder that contract is decided in
the code and writing it in the plan only duplicates it, which is why it is
conditional.

## The form

A table allows deciding at a glance, which is the goal. A sequence diagram
avoids reconstructing the order from memory; a graph shows at once what is not
seen by reading. The why and the risks do not fit in a table without losing the
nuance, and three numbers do not need axes. A diagram conveys the same as prose
at lower cost, when there is something to draw.

## Closing the plan

A plan approved and executed without deviations is rare. The deviations are
decisions made with the code in front of you and more information than when it
was written; if they are not written down, exactly what was costly to discover
is lost. It is the same rule as keeping code and documentation in sync, applied
to the document you produced yourself.

## The anti-patterns

A flow of four obvious boxes makes the plan look deeper than it is. A list of
steps says nothing debatable. The full template out of habit is the failure mode
of RFCs: sections that add nothing get filled in, the detail goes up and people
stop reading them; five short sections get read, twelve do not. Without the
trace, approving is trusting, and trusting is not reviewing.
