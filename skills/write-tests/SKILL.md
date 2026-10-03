---
name: write-tests
description: Write tests worth having: choose what deserves coverage and what doesn't, cover the painful case before the happy one, keep them deterministic and validate them in the negative. Use when tests have to be added to something that has none, when you add new behaviour, when you fix a bug and want it not to come back, when you are about to refactor something with no safety net, or when asked to raise coverage.
---

# write-tests

Writing tests is easy. Writing the ones worth having is not.

## The criterion: test what hurts if it fails

You don't test for coverage, you test for **consequence**. Before writing a test,
ask what happens if that breaks in production and nobody notices.

| Deserves a test | Doesn't |
| --------------- | ------- |
| Calculations with business rules | Getters, trivial mappings |
| Transformation of external data | A framework doing what it promises |
| Edge cases and boundary values | A constant having the value it has |
| Every bug that has already happened once | Private implementation details |
| Contracts between modules or services | Layout, unless it is measurable |
| Logic a refactor is going to move | Code that will be gone next week |

**One test per real bug.** It is the rule with the best return there is: the bug
already proved that path breaks, so the probability of it coming back is not
theoretical.

## Start with the painful case

The happy path is usually covered incidentally by use. What nobody tests is the
rest:

- Empty, null, zero, empty string, empty list.
- The maximum and the minimum, and one past each.
- Malformed input, in the wrong format, with accents, very long.
- Duplicates, reverse order, concurrency.
- The external service's error: timeout, 500, a response with a changed shape.

If you are only going to write three tests, make them from here.

## A test has to be deterministic

A test that fails one time in twenty is worse than not having it: it teaches the
team to retry without looking, and the day it fails for real nobody will believe
it.

The four sources of nondeterminism, and what to do about them:

| Source | What to do |
| ------ | ---------- |
| Time and dates | Inject the clock, never read it inside the logic |
| Randomness | Fixed seed, or inject the generator |
| Network and external services | Doubles with fixed responses; the fixture is the contract |
| Execution order and shared state | Each test creates and destroys its own |

## Validate it in the negative

**A test you have never seen fail is worthless.** It is the most common mistake
and the most expensive, because it produces false confidence.

After writing it: deliberately break what it tests, check that the test goes red
for the right reason (not because of some other error), and revert. Thirty
seconds that tell you whether the safety net exists.

## What to do when it is hard to write

A test that is hard to write is almost never a problem with the test: it is the
design giving a warning. If you need to simulate five dependencies to test one
function, that function does five things.

Before building the scaffolding, try extracting the pure logic and testing that.
The part that talks to the world stays thin and logic-free, and stops needing
complicated tests.

## Names

The test name is the first thing read when it fails in a log, months later. Make
it state **the condition and the expectation**, not the function name:

- Bad: `test_calculate`, `it("works")`
- Good: `returns zero when the list is empty`,
  `rejects the date if the end is before the start`

## Before accepting a batch

- Does any fail if I deliberately break what they test?
- Do they pass in random order and in parallel?
- Do they pass on a clean machine, without your cache or your database?
- Is any so slow that people will start skipping them?

## Anti-patterns

- **Testing the implementation instead of the behaviour.** If the test breaks on
  every refactor without anything observable changing, it is badly written.
- **One giant test that tests everything.** When it fails you don't know what
  failed.
- **Too many assertions.** Checking twenty fields just in case turns any
  legitimate change into a broken test.
- **Doubles that return whatever suits the test.** If the double doesn't look
  like the real response, the test passes and production fails.
- **Writing tests to raise a number.** Coverage is a signal, not a goal. You can
  have 90% and test nothing that matters.

## Related

- `/ship`: gates 1 and 5, which are these tests
- `/root-cause`: before writing the test for a bug, understand the bug
