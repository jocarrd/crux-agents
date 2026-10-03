---
name: prod-signals
description: Read what is happening in production (logs, errors, container status, availability) from the read-only sources the project declares, grouping repeated errors so they fit in the context. Use when something fails in production, after a deployment that misbehaves, before debugging a failure that only happens on the server, or when asked whether the site or the API is throwing errors.
---

# prod-signals

Debugging a production failure starting from what someone tells you is starting
from the version with the least data. Production already knows what fails, how
many times and since when: it is in its logs.

The problem is that a log is thousands of nearly identical lines. This reads
them, keeps what looks like a problem and groups the ones that differ only in
dates, numbers or identifiers. What reaches the context is a twenty-line summary,
not the log.

## What the project declares

The sources are **read-only commands**, in the project's `crux.json`:

```json
"observability": {
  "sources": [
    { "name": "app", "command": "ssh <host> docker logs --since {since} <container>" },
    { "name": "containers", "command": "ssh <host> docker ps --format '{{.Names}} {{.Status}}'" },
    { "name": "web", "command": "<platform CLI> logs <project> --since {since}" }
  ]
}
```

`{since}` is replaced by the requested window. **Never a command that writes,
restarts or deletes**: this is launched without asking, so it has to be
launchable without consequences.

The contract belongs to the team and lives in the documentation repo, so nothing
is blocked. If it has uncommitted changes, the script warns before running: a
command edited by hand and forgotten runs all the same.

Credentials don't go in the command: they go in the machine's configuration
(`~/.ssh/config`, the CLI session). `crux.json` is in git.

## How it is used

```bash
bash <this-skill-directory>/scripts/signals.sh                 # all, last hour
bash <this-skill-directory>/scripts/signals.sh --since 24h app # one source, one day
bash <this-skill-directory>/scripts/signals.sh --all containers
```

`--all` removes the error filter: for status sources, where every line matters.

Output: `0` read, `1` some source didn't respond, `2` the project declares no
sources.

## What to do with the summary

1. **The most repeated group is not always the important one.** A warning that
   appears on every request for months is noise; an error that started twenty
   minutes ago is the news. Compare against an earlier window (`--since 24h`
   versus `--since 1h`) before concluding.
2. **Cross it with the latest deployment.** If the error starts right after a
   deployment, that deployment's diff is the first suspect.
3. **Continue with `/root-cause`**, which is where it is reproduced and fixed.
   This gives the starting point, not the diagnosis.

## What it costs

What is read from the log doesn't enter the context: the summary does, which has
a cap on groups per source (`--max`, 15 by default). A query is around a few
thousand tokens, versus the hundreds of thousands of dumping the log.

## What this is not

It is not an alerting system and doesn't watch production continuously. It is
launched when there is a reason. Having an agent watching production around the
clock only pays off with traffic and a team behind it; at the scale of a few
people, what pays off is that when someone asks, the answer takes a minute.

If the project already has alerts (an uptime monitor, an error service), the
alert is the natural trigger: whoever receives it launches this.

## Anti-patterns

- **Dumping the whole log into the context.** It doesn't fit, and what matters
  gets lost.
- **Declaring commands that write.** This runs without confirmation.
- **Concluding from a single window.** Without comparing, you don't know whether
  the error is new.
- **Putting credentials in `crux.json`.** It is in git.

## Related

- `/root-cause`: the next step, with the summary in front of you
- `/deploy-watch`: when the signal appears right after deploying
- `/runbook`: when the incident has been resolved and has to be written down
