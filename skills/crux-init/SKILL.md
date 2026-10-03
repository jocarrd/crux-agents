---
name: crux-init
description: Bootstrap the documentation repo of a new project under the standard, or formalize one that lives without documentation. Creates the repo on the remote, materializes the minimal structure from the kernel templates, writes the crux.json contract and generates the pointers for the code repos. Use when you are starting a project or want to put an existing one under the standard.
---

# crux-init

Creates the docs repo of a new project following the standard.

## When to use

- You are starting a project and want its documentation set up from day one.
- You have a project that lives without documentation and want to formalize it.

If the project **already has** a docs repo with content, use `crux adopt`, which
registers it without touching what is already there.

## Preconditions

- The kernel installed on this machine (`crux version` responds).
- `gh` authenticated, unless you use `--no-remote`.

## Flow

### 1. Collect the data

Ask the user:

1. **Project name**, in lowercase kebab-case. It will also be the name of the
   parent folder, so it is best if it is short.
2. **Description**, one line.
3. **Repos that already exist**, if any.
4. **Profile**: `multi-repo` if the code is your own, `client-repo` if the code
   belongs to a client and can't be touched.
5. **Visibility** of the docs repo: private by default.

The profile is the decision with the most consequences: it determines whether
the code repos are written to or not, and which rules the verification enforces.
When in doubt, ask explicitly instead of assuming.

### 2. Run

```bash
crux init <project> \
  --description "..." \
  --repos "repo-a,repo-b" \
  --profile multi-repo
```

The command creates the repo on the remote, clones it, materializes the structure
from the templates, writes `crux.json`, makes the initial commit and generates
the pointers for the repos it finds on disk.

It is deterministic: it comes from the kernel templates, not from files being
reproduced by hand. Two runs give the same tree.

### 3. Verify

```bash
crux doctor
```

It must come out conformant before accepting the bootstrap.

### 4. Explain to the user what they now have

- Where each thing ended up and which folders will appear later, on demand:
  `architecture/`, `conventions/`, `operations/` and `topics/<topic>/` only when
  the project needs them.
- That the code repos are placed as siblings of the docs repo.
- That `/add-repo-to-docs` exists for adding a new one.

## Common errors

- **The repo already exists on the remote.** Decide between another name or
  cleaning up by hand; the command doesn't delete anything that isn't its own.
- **The name is not kebab-case.** The command rejects it on purpose: half the
  convention depends on the folder being named exactly like the project.
- **The project already had documentation.** This is not the command; it is
  `crux adopt`.

## Related

- `/add-repo-to-docs`: register a repo in an already set up project
- `/crux-doctor`: verify conformance
- `/end-session`: the closing ritual that keeps all this alive
