---
name: eval-fixtures
description: Test functionality built on a language model, where the output is not deterministic and an exact-equality test is useless: separate what can be asserted, validate structure instead of text, build a set of cases with judged outputs and watch for regressions. Use when the project has a chatbot, text generation, extraction, classification or tool calling, and you want to be able to change the prompt or the model without breaking anything blindly.
---

# eval-fixtures

A normal test is no good for generated output: two runs don't give the same
result, and even if they did, the correct answer is not unique. But **most real
failures are structural**, and those can be caught.

## The three layers

Different things are tested in each, and confusing them is the usual mistake.

**1. Deterministic: everything around the model.**
Prompt assembly, response parsing, schema validation, error and timeout
handling, tool routing. Here the model is replaced by a double with fixed
responses and tested like any other code. **This is where most bugs are** and
where almost nobody looks.

**2. Structural: the shape of the output.**
With the real model, but without comparing text: the response meets the schema,
the required fields are there, types and ranges are valid, the tools called exist
and receive arguments of the right shape, no identifiers are made up.

This layer is cheap, stable and **catches the real regressions**: when the model
or the prompt changes, the first thing to break is the shape.

**3. Quality: the content.**
A set of cases with their expected output and an acceptance criterion. It is not
equality: it is a threshold. Here you measure whether the response is grounded
in the data it was given, whether it answers what was asked and whether it
respects the domain's rules.

## The set of cases

It is the asset, more than the tests. It is built **from real failures**, not by
imagining examples:

- Every time someone reports a bad response, it goes into the set.
- Every domain edge case you discover goes in.
- The cases where the correct answer is "I don't know": the most forgotten and
  the ones that do the most damage when the model makes things up.

Each case stores: the input, the context it was given, what the response must
satisfy and why. That "why" is what allows the criterion to be reviewed when the
product changes.

Start with twenty well-chosen cases. Two hundred generated without criterion are
no more valuable and cost money on every run.

## What can be asserted unambiguously

Even if the output is free-form, there are almost always hard assertions:

- **It doesn't invent data**: every number, name or identifier in the response
  appears in the context it was given.
- **It respects limits**: it doesn't promise what the product doesn't do, doesn't
  give advice the policy forbids.
- **It is consistent**: the same question with the same context doesn't give
  contradictory answers between runs.
- **It fails well**: without enough data, it says it doesn't know instead of
  filling in.

Start with these. They are objective and cover the most expensive damage.

## Watching for regressions

The value appears when you change something: prompt, model, version, retrieved
context. Without a baseline, every change is a bet.

Save the result of the set as a reference and compare. What matters is **which
cases used to pass and now don't**. A change that raises the average and breaks
three cases that worked is usually a bad change.

## Cost

These tests cost money and time per run, so they don't go in the same place as
the normal tests:

- Layer 1 always runs: it is free and fast.
- Layers 2 and 3 run **when something that affects them changes** (prompt, model,
  context retrieval) and before deploying. Not on every commit.

## Anti-patterns

- **Comparing the output with exact text.** It always breaks and proves nothing.
- **Testing only the happy path.** What sinks an assistant is what it does when
  it doesn't know.
- **Trusting only the average score.** It hides exactly the regressions you are
  looking for.
- **An invented set of cases.** The cases you think of are not the ones that
  fail; the ones reported to you are.
- **Testing the model instead of your system.** Whether the model can add is not
  your problem; whether your prompt gives it the right data is.

## Related

- `/write-tests`: layer 1 is this, with a double in the middle
- `/root-cause`: when a specific response comes out wrong and you need to
  understand why
