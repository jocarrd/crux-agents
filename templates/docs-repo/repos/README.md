# repos/

Documentation specific to each {{PROJECT}} repo. One folder per repo, named the
same as the repo on GitHub.

| Folder | Repo | What it does |
| ------ | ---- | ------------ |
| | | |

## Conventions inside each folder

- `README.md` — the repo's index: what it does, which docs live here, where the code is
- `decisions.md` — decisions that affect only this repo
- Other topical docs as needed: `architecture.md`, `api.md`,
  `design-system.md`, `notes.md`…

## Path rules

The paths that appear in these docs are **relative to the root of the described
repo** and are written in backticks, without linking. Each doc must include
this line in its header:

```
> Paths relative to the root of `<repo-name>/`.
```
