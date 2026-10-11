# Security

crux installs hooks that run on every agent session and commands that run
`git` against your repositories. A flaw there runs with your user's
permissions, so reports are welcome.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through
[GitHub's security advisories](https://github.com/jocarrd/crux/security/advisories/new).

Include what an attacker can do, the steps to reproduce it and the crux
version (`crux --version`). You will get an answer within a week.

## What counts

- A hook or command that runs code from a repository or a file it should only
  read.
- A command that writes outside the paths it is meant to touch, or deletes
  data without asking.
- Credentials or `.env` values that end up in a commit, a log or the agent's
  context.

Bugs in what an agent does while following a skill are usually not security
issues. Open a normal issue for those.
