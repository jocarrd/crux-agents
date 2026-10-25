---
name: skill-creator
description: Write a new skill that gets discovered when it should, can be followed without ambiguity and takes up little context: check first that it does not already exist, write the trigger, split between the procedure and its references, decide whether it carries a script, place it in the kernel or the project and test it with scenarios. Use when you want to turn into a procedure something you have done by hand more than twice, when a skill does not activate when it should, or when a skill has grown too long.
---

# skill-creator

A skill is a procedure that an agent finds through its description and loads in
full into its context every time it uses it. That is why it has to activate when
it should and take up as little as possible. The examples and the reason behind
each rule are in `<this-skill-directory>/references/why.md`.

## 1. Is a new skill needed?

- **Only if you have done it by hand more than twice** and the third time you
  had to work something out again. Once does not make a procedure.
- **Before creating it, check whether it already exists.** Write the sentence
  you would ask for it with and check it against the catalogue:
  `node <skill-audit-directory>/scripts/probe.mjs "the sentence"`.
  If an existing skill wins, **extend that one**; do not create another that
  competes with it.
- **One skill, one thing.** If it does three, it activates badly for all three.

## 2. The trigger

The frontmatter description is the only thing read to decide whether to
activate it. Two halves: **what it does**, in concrete terms, and **when to use
it**, with the situations and the words of whoever has the problem, not of
whoever already knows the solution.

```yaml
---
name: name-in-kebab-case        # same as the directory
description: What it does. Use when <situation>, when <another>, or when <symptom>.
---
```

## 3. The size

| | Words in `SKILL.md` |
| - | - |
| Target | 400 to 800 |
| Maximum | 1,000 (the kernel suite and `crux doctor` check it) |

`SKILL.md` carries **what the agent has to do**: steps, commands, rules,
decision tables, gotchas in one line and how to verify. Everything else goes in
`references/why.md` and is opened only if needed: the reason behind each
rule, the history of how it was discovered, the cases that gave rise to it, the
sources and the long examples. Cite the reference at the start with
`<this-skill-directory>/references/why.md`.

Write in the imperative and in short sentences. Do not narrate what the command
already says or explain what any manual covers.

## 4. The body

```markdown
# name
What it solves, in one or two sentences, and where the reference is.
When to use and when not to (repeated: not all agents read the frontmatter).
The procedure, step by step.
Gotchas.
Anti-patterns, one line each.
Related.
```

Gotchas are what is worth most: what cannot be deduced from the happy path.

## 5. Does it carry a script?

A script for the **mechanical and exact** part that repeats the same way (a
calculation, a format, a comparison). Prose for the **judgement** (what to look
at and how to interpret it). A script that encapsulates the judgement becomes a
black box.

## 6. Neutrality and place

- Do not name tools of a specific agent: describe the action.
- In the kernel no projects are named: the data goes in an adapter.
- **Boundary test:** cover the proper names. If the procedure still makes sense,
  it goes in the kernel and the project keeps an adapter; if not, it belongs to
  the project.
- An adapter has to win the sentence with the project's names and lose the
  generic one. Check it with the two sentences written before the description:
  `node <skill-audit-directory>/scripts/probe.mjs --adapter <adapter> <skill> "<generic>" "<with names>"`.

## 7. Before accepting it

1. **The description:** test with `probe.mjs` a sentence that does not come from
   the description itself. If another skill wins, or it wins by less than 15 %,
   it does not distinguish it.
2. **The size:** `wc -w SKILL.md` within budget.
3. **Three scenarios with a known answer**, in `tests/scenarios.md`: a normal
   case, an edge case and one the skill must reject, each with its `Pregunta:`
   and its `Debe:` / `No debe:` checks (regular expressions). Run them with
   `crux skill test <skill>`; if you are shortening or changing a skill, with
   `--against <ref>` and `--runs 3`: **the new one has to answer the same**. A
   regression is a lost nuance; it goes in `SKILL.md`, not in the reference.
4. **Execute it** following what it says, not what you remember.

## Anti-patterns

- Creating a skill that competes with an existing one.
- Generic description ("helps with deployments").
- Documenting the tool instead of the procedure.
- Putting the history and the why in `SKILL.md`.
- Writing it from memory without executing or testing it.
- Leaving it unmaintained: a skill that lies is followed with confidence.

## Related

- `/skill-audit` — whether a skill is in the right place and whether to merge
- `/promote-to-docs` — for what is knowledge and not procedure
