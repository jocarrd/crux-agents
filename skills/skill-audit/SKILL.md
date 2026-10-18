---
name: skill-audit
description: Review whether any skill of a project is really a pattern that deserves moving up to the kernel, or whether any kernel skill has filled up with special cases and should move down. Inventories the skills of all projects, measures their density of proper names and detects pairs of different projects that solve the same thing. Use when creating a new skill, and periodically at session close.
---

# skill-audit

It maintains the boundary between the kernel and the projects, and the short
catalogue: procedures locked inside a project that should move up, kernel skills
full of special cases that should move down, and skills that compete for the
same sentence. The reasons and measurements behind each threshold:
`<this-skill-directory>/references/why.md`.

**When:** when creating a skill (pattern or adapter?) and periodically at
session close.

## The test

> Cover all the proper names in the skill. If the procedure still makes sense and
> has value, there is a pattern inside.

The procedure is promoted and the project keeps an adapter with paths,
credentials and names. Two guards:

- **Two occurrences:** it is promoted when two projects genuinely need it
  (except with demonstrated high value and almost no coupling).
- **Reverse path:** a kernel skill with per-project conditionals moves down to
  `project/`.

## Audit

```bash
node <this-skill-directory>/scripts/audit.mjs
```

It walks the adopted docs repos and reports:

- **Low density of proper names** (derived from each project's `crux.json`):
  suspected of containing a pattern.
- **Pairs of different projects that describe the same thing:** the
  two-occurrences rule is already met.
- **Those that are already adapters**, separately and outside the candidates.
- **Adapters that compete with their procedure:** descriptions that overlap by
  more than 0.18, or an adapter that does not name its project in the
  description.

They are signals, not verdicts: the script points, the test decides and the
two-occurrences rule brakes. Size is watched by the description verifier: a
skill of more than 1,000 words is shortened with `/skill-creator`.

## Verify activation

```bash
node <this-skill-directory>/scripts/probe.mjs "the sentence you would ask for it with"
node <this-skill-directory>/scripts/probe.mjs --casos
node <this-skill-directory>/scripts/probe.mjs --adaptador <adapter> <kernel> "<generic sentence>" "<own sentence>"
```

- `probe` says which skill wins a sentence and **by how much**: below 15 % of the
  leader is a tie.
- `--casos` runs `casos/activacion.tsv` (real sentence → expected skill). A
  sentence without proper names has to activate the kernel, never an adapter.
- `--adaptador`: the generic sentence is won by the kernel and the own one, by
  the adapter.

It is useful for comparing two wordings and for seeing whether a change switched
a skill off. It does not predict the agent: a tie is reliable, a winner
guarantees nothing. **The sentence is written the way the job is asked for**,
not copied from the description.

## Promote

1. Separate the procedure from the data.
2. Write the kernel skill without projects or tools of any one agent.
3. Leave in the project an adapter with its own paths, credentials and gotchas
   that points to the kernel.
4. Run the new skill against the real case it came from: it has to give the same
   result.
5. Reinstall the kernel.

## Anti-patterns

- Promoting just in case: a bloated kernel is as bad as an empty one.
- Promoting without leaving an adapter.
- Ignoring the reverse path.

## Related

- `/skill-creator` — write or shorten a skill
- `/end-session` — where the periodic review hooks in
- `/promote-to-docs` — the equivalent for documentation
