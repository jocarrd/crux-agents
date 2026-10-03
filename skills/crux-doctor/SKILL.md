---
name: crux-doctor
description: Give a project a checkup: verify that its documentation repo meets the standard (contract, mandatory structure, declared repos against those present, profile rules, ADR status, markdown links, orphan documents and skill format) and leave it conformant. Use after migrating or reorganizing documentation, when registering a new repo, when returning to a project you haven't touched in a while, or when you want to check whether something has drifted out of alignment.
---

# crux-doctor

Checks a docs repo's conformance with the standard. The standard is of little use
if you just trust that it is being followed.

## When to use

- Before closing a work session with documentation changes.
- After moving, renaming or deleting documentation files.
- When returning to a project you haven't touched in months.
- After updating the kernel, to see which projects were left out of date.

## Usage

```bash
crux doctor          # on the project in the current directory
crux doctor <dir>    # on another one
```

It exits with code 1 if there are errors. Warnings don't block.

## What it checks

1. **The contract.** That `crux.json` exists, that it has the mandatory fields,
   that the declared profile exists and which kernel version was used.
2. **The mandatory structure.** The files in the standard's floor, and that the
   Claude pointer is a link to the canonical one and not a copy that diverges.
3. **Declared repos against reality.** Repos without a documentation folder,
   undeclared folders, declared repos that aren't on disk.
4. **The profile rules.** In an own-code project, that every repo has its
   pointers. In a client one, that **nobody has written** to the foreign repo:
   that is an error, not a warning.
5. **Markdown links.** That all of them resolve inside the docs repo.
6. **The project's skills.** Frontmatter present and name consistent with the
   directory.

## How to interpret the result

**Errors**: they break the standard and have to be fixed: missing contract,
broken links, writing to foreign code, declared repo without documentation.

**Warnings**: the project is still valid, but something is drifting out of
alignment: outdated kernel version, undeclared folder, declared repo not yet
cloned. They deserve a decision, not necessarily an immediate action.

## Typical fixes

| Symptom | Fix |
| ------- | --- |
| `crux.json` missing | `crux adopt` |
| Outdated version | `crux upgrade` |
| Repo without pointer | `crux link` |
| Undeclared folder in `repos/` | `/add-repo-to-docs`, or delete it if surplus |
| Link to a file in another repo | convert it to text in backticks |

A markdown link pointing outside the docs repo is not fixed by correcting the
path: it is converted to plain text. The standard forbids them because they break
with any reorganization and end up lying, and there is no build that validates
them.

## Related

- `/end-session`: the closing ritual, which runs this as one of its steps
- `/crux-init`: create a new project under the standard
