---
name: grill
description: Interrogate the decision-maker until exhausting a plan's decision tree, before writing code. Questions come in rounds, numbered and with the answer you recommend; the agent looks up facts and the user makes decisions. Use before starting something that can be done in several reasonable ways, when the brief arrives in two sentences and a lot has to be built, when you notice you are filling gaps on your own, or when the user says "pregúntame", "hazme preguntas" or "antes de ponerte, aclaremos".
---

# grill

The most expensive failure in development is building well what wasn't wanted.
And it is almost never detected at the start: it is detected when the result is
shown.

A brief arrives with gaps. The agent fills them in alone and in silence, because
filling them is faster than asking. Every gap filled by eye is a bet, and a
single one going wrong throws away the afternoon's work.

This skill turns those gaps into questions before they cost anything.

## The tree and its frontier

A plan is a tree of decisions: each one opens the ones that hang from it. You
can't ask about the PDF format if you don't yet know whether there will be a PDF.

The **frontier** is the decisions whose prerequisites are already resolved: what
can be asked **now** without guessing answers you haven't heard yet.

Work in rounds:

1. Compute the frontier.
2. Ask **the whole** frontier at once.
3. Wait for the answers. Don't move on without them.
4. The answers push the frontier outward and unlock what depended on them. Go
   back to step 1.

A question whose answer depends on another that is still open **in this round**
belongs to the next round. Slipping it in forces the user to answer twice or to
invent a condition.

It ends when the frontier is empty: all branches visited, nothing assumed in
silence.

## How a round is phrased

Each question is numbered, with a title, and **with the answer you recommend**.
The recommendation is not optional: it forces the agent to commit and lets the
user say "yes" instead of writing a reply.

```
❓ **Q1 — <short title>**

<the body of the question: context, options, what changes depending on the
answer. It can run to several paragraphs>

➡️ <what you recommend and why, in one or two sentences>

---

❓ **Q2 — <short title>**

…
```

If the agent has a closed-options control, use it when the alternatives are few
and mutually exclusive, with the recommended one first. For everything else, the
format above.

## The rule that holds it all up

> **The agent looks up facts. The user makes decisions.**

If a frontier question needs a fact about the environment (which version is
installed, whether that endpoint exists, how many rows that table has), that is
**not asked**: it is looked at. Asking it spends the user's turn on something the
agent resolves with a command, and on top of that gets an answer from memory
instead of a fact.

Don't block on it. An exploration in progress is an unresolved prerequisite, so
only the questions that hang from it wait; the rest of the frontier is asked
right away.

## When to stop

This skill is expensive in user turns, so it has a ceiling:

- **Two or three rounds** for a normal change. If you are on the fifth, either
  the brief is huge and has to be split, or you are asking things you should be
  looking at.
- **No question whose answer doesn't change what you are going to do.** If you
  build the same thing with both possible answers, the question is superfluous.
- **No confirming what was already said.** If it is in the brief, it is decided.

## Afterwards

The result of an interrogation is an agreement, and an agreement that only lives
in the conversation is lost when the session closes. Move it to where it belongs:

- `/explain-plan` if the proposal has to be presented before building it.
- `/adr` if along the way an alternative was discarded for a reason that isn't
  obvious.
- `crux task` if the work will last more than one session.

Don't start building until the user confirms you are in agreement.

---

*The mechanism of the tree, the frontier and the rounds is adapted from the
`grilling` skill of [mattpocock/skills](https://github.com/mattpocock/skills),
MIT license.*
