# {{PROJECT}}

{{DESCRIPTION}}

## The project's repos

See `repos/README.md` for the complete repo → documentation folder mapping.

Filesystem layout:

```
~/Projects/{{PROJECT}}/
├── <repo-1>/
├── <repo-2>/
└── {{PROJECT}}-docs/        ← this repo
```

## How it is used

This repo is the project's cross-cutting documentation and the canonical
context for any agent. The entry point is `AGENTS.md`.

It follows the standard defined in `crux` (see `crux.json` for the version and
profile applied). Useful commands from here:

```bash
crux doctor    # verifies that the documentation meets the standard
crux link      # regenerates the code repos' pointers
```
