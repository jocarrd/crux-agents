---
name: teach
description: Teach something across several sessions, anchored in the project's code and not in textbook examples: a directory with the reason for learning, trusted sources, lessons and a log of what has been learned. Use when the user asks you to explain a technology so they truly learn it and not just to get by, when they say "no termino de entender", "explícame bien", "quiero aprender" or "hazme una guía", and when they ask the same underlying question a second time.
---

# teach

An explanation in the chat is understood while it is read and evaporates when the
session closes. The following week the same question comes back in other words.

This skill turns those explanations into a space with state: a directory where
the reason for learning, the sources, the lessons given and what has really been
learned are kept. Each session continues the previous one.

## The rule that sets it apart from a tutorial

> **Everything is explained on the code the user has in front of them.**

A Prisma tutorial teaches `model User { id Int }`. A useful lesson teaches the
`catalogSnapshot` of *their* schema, with the real problem it solves and the rule
that only lives in a comment. The first is forgotten because it isn't used; the
second sticks because it is the code they will touch tomorrow.

Before writing any lesson, read the repo: the schema, the configuration files,
the places where the concept already appears. If the project has a docs repo,
read that too. The example comes from there.

## The workspace

The current directory is the workspace. Its state lives in these files:

- **`MISION.md`**: why they want to learn this. Without it you don't start: it is
  what decides what goes into each lesson and what is left out. If it is empty,
  the first task is to ask.
- **`FUENTES.md`**: the trusted sources, with a link and one line on what each
  contributes. The official documentation, the article by whoever designed it,
  the specification. **Don't trust what you think you remember**: look it up and
  cite it.
- **`lecciones/NNNN-<name>.md`**: the lessons, numbered.
- **`referencia/`**: what has been distilled: cheat sheets, tables, diagrams.
  What gets consulted later, without rereading the whole lesson.
- **`aprendido/NNNN-<name>.md`**: the log of what was learned. They are to
  teaching what an ADR is to architecture: the non-obvious, what was hard, what
  had to be corrected. What can be taught next comes from here.
- **`NOTAS.md`**: the user's preferences and working notes.

## Fluency and retention

Two things that get confused have to be separated:

- **Fluency**: recalling something in the moment, with the explanation in front
  of you.
- **Retention**: still having it inside six months from now.

Fluency gives a false sense of mastery. Someone who has just read a clear
explanation thinks they know it, and a week later they don't. The goal is
retention, and it is achieved with deliberate difficulty:

- **Retrieval**: make them pull it from memory before showing it to them. A
  question at the start of the next lesson is worth more than a summary.
- **Spacing**: spread it out over time instead of one long session.
- **Interleaving**: mix related topics in practice, not pure blocks.

## The lesson

A lesson teaches **one** bounded thing, tied to the mission, and is finished in
one sitting. Working memory is small: a long lesson is a lesson that doesn't get
completed.

Each lesson carries:

- An example taken from the project's code, with its path.
- One thing the user can do on finishing that they couldn't before.
- **A primary source** to go further, the best one you have found.
- A reminder that they can ask questions: the agent is the teacher, not the PDF.

When the user prefers to read it in another format, the natural destination in
this environment is one Claude Docs document per topic, which can keep being
edited between sessions. For what is printed or sent by email, the user's
convention is A5 PDF.

Run the `/redaccion` skill before delivering any long lesson.

## Closing each session

Before finishing:

1. Write the log in `aprendido/` of what was hard or surprising.
2. Distil into `referencia/` what will be consulted again.
3. Say what the next step is and why that one is next.

If the topic runs to more than two or three sessions, register it with
`crux task` so it survives the session closing.

---

*Adapted from the `teach` skill of
[mattpocock/skills](https://github.com/mattpocock/skills), MIT license. The
anchoring in the project's code and the destination of the lessons are our own.*
