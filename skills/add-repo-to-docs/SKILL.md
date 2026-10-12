---
name: add-repo-to-docs
description: Add a new repo to a project already adopted under the standard. Creates its documentation folder, declares it in crux.json, registers it in the repo table and generates its context pointers. Use when you create or clone a new repo inside a project that already has its docs repo.
---

# add-repo-to-docs

Registers a new repo in the docs repo of a project that already follows the
standard.

## When to use

- You have just created or cloned a repo inside `~/Projects/<project>/`.
- You want the project to recognize it: documentation folder, entry in the
  contract, row in the index and context pointers.

## Preconditions

- The project already has its `<project>-docs/` with `crux.json`. If not,
  `crux adopt` or `/crux-init` first.
- The repo lives as a sibling of the docs repo. The layout convention is
  mandatory: without it, relative references stop resolving.

## Flow

### 1. Collect the data

Ask the user, if you don't have them:

- **Repo name**, exactly the same as on the remote.
- **What it does**, in one line. It goes into the index and the header of its
  documentation, so it is worth making it precise and not generic.

### 2. Run

```bash
crux add-repo <repo> --description "what it does, in one line"
```

This, in a single step:

- creates `repos/<repo>/README.md` from the kernel template;
- declares the repo in `crux.json`;
- adds its row to the table in `repos/README.md`;
- generates `AGENTS.md` and `CLAUDE.md` in the code repo, unless the project's
  profile forbids it;
- leaves the rest of the pointers verified.

### 3. Verify

```bash
crux doctor
```

It must come out conformant. If it warns that the repo is not on disk, it was
declared before being cloned: it is not an error, but the pointers have not been
created yet and `crux link` has to be run again once it is there.

### 4. Commit

```
docs(repos): add <repo>
```

Ask before pushing.

## Afterwards

The folder is born with just a README. It is filled on demand, not all at once:
when a decision affecting only that repo appears, `decisions.md`; when there is
status or blockers to remember, `notes.md`; when there is an API contract or a
visual system to explain, its topic file.

## Common errors

- **The project is not adopted yet.** Redirect to `crux adopt`.
- **The repo is outside the project's folder.** Move it first; the sibling
  convention is not optional.
- **The folder already exists with other content.** The command aborts instead of
  overwriting it. Decide whether to merge by hand or rename.

## Related

- `/crux-init`: create the docs repo of a new project
- `/crux-doctor`: verify conformance
- `/promote-to-docs`: move loose information to its place
