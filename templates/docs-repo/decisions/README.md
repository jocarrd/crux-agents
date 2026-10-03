# Decisions (ADRs) — convention and format

This folder holds the **cross-repo registry** (`index.md`). Each repo also has
its own registry in `repos/<repo>/decisions.md` when applicable.

## Where does a new ADR go?

| If the decision affects… | It goes in… |
| ------------------------ | ----------- |
| More than one repo of the project | `decisions/index.md` |
| Only one repo | `repos/<repo>/decisions.md` |

If in doubt, start with single-repo. If it later turns out to be cross-repo, it
is promoted (see below).

## Canonical template

The same for both levels, so that an agent does not read two different formats
and treat them as different things.

```markdown
### ADR-NNN: Title

- **Date**: YYYY-MM-DD
- **Status**: one of the five in the table below
- **Context**: what problem or situation motivates it
- **Decision**: what we decided
- **Consequences**: how the code, the operation or the deployment changes
- **Reversibility**: how costly it would be to undo (always recommended: it is
  what lets you decide with a cool head whether it is worth trying)
- **Related**: refs to other ADRs or issues (optional)
```

### The statuses

| Status | Means | Reference |
| ------ | ----- | --------- |
| `Open` | A decision is needed and there is no proposal yet. `Decision` says "none" | — |
| `Proposed` | There is a proposal on the table, not yet applied | — |
| `Accepted` | In force | — |
| `Inherited` | We did not make it: it came with the code | — |
| `Superseded by <ref>` | No longer valid: another decision takes its place | mandatory, accepts several separated by commas |
| `Amended by <ref>` | Still in force, but another decision changed a part | mandatory |
| `Deprecated` | No longer applies and nothing replaces it | — |

Three of them exist because the alternative is worse:

`Amended` — a decision of which only one part changed is not superseded: the
rest still governs, and marking it as superseded makes someone discard all of
it.

`Open` — a known problem left undecided **is** information, and among the most
useful: it tells whoever arrives that there is a gap there and not an
oversight. Without this status it ends up unrecorded, which is how the same
debate repeats every six months.

`Inherited` — separates what we decided from what we found. It matters in any
project with inherited code and is mandatory in the `client-repo` profile,
where confusing the two means attributing to the client a decision of ours, or
the other way round.

Without a status for each case, the nuance ends up written as prose inside the
field, which is where no automatic reader finds it.

Rules:

- `NNN` is consecutive within the registry where it lives: each `decisions.md`
  starts at 001.
- **The `Status` field contains the status and its references, nothing else.**
  The why of the change goes in `Consequences` of the new ADR, which is the one
  that knows it.
- References are cited as "How to cite across registries" says: `ADR-014`
  within the same registry, `decisions/ADR-014` when crossing.
- `Reversibility` is set whenever possible: it is what lets you estimate the
  cost of changing your mind later, and without that datum the decision is
  judged blind. It is omitted only when it truly does not apply.

### Decisions with an expiry date

A patch that is accepted knowing it has to be removed carries one more field:

```markdown
- **Status**: Accepted
- **Sunset**: when the CMS takes over the redirects (see ADR-022)
```

`Sunset` is a field and not a status because both things are true at once: the
decision is accepted **and** has a withdrawal date. As a status you would have
to choose one of the two and lose the other.

## How to cite across registries

Numbering is local to each registry, so when crossing, the path prefix is used:

| Context | How to cite |
| ------- | ----------- |
| Within the same registry | `ADR-007` |
| Crossing registries | `decisions/ADR-013`, `repos/<repo>/ADR-007` |

## Promotion single-repo → cross-repo

When a decision that started by affecting one repo ends up affecting several:

1. Create a new entry in `decisions/index.md` with the next consecutive number,
   replicating the content and expanding the context.
2. Mark the old ADR as `Status: Superseded by decisions/ADR-NNN`.
3. **Do not delete the old ADR** — history matters.
4. Commit: `docs(decisions): promote repos/<repo>/ADR-X to cross-repo as ADR-NNN`.

## Adding an ADR

- **Cross-repo**: open `index.md`, add at the end with the next number.
  Commit: `docs(decisions): add ADR-NNN <title>`.
- **Single-repo**: open or create `repos/<repo>/decisions.md` with the minimal
  header that points to this format, and add the entry.
  Commit: `docs(repos/<repo>): add ADR-NNN <title>`.
