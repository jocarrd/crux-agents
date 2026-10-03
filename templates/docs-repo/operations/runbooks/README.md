# runbooks/

One file per **symptom**, named after how the problem is reported
(`login-does-nothing-after-deploy.md`, `radar-tiles-wrong-in-production.md`).
There is no generic `runbook.md` here: runbooks appear when a real incident is
resolved, not before.

A runbook is run with the system down, so it **does not explain, it acts**. The
anatomy, in this order:

1. **Symptom** — the title, as it is reported.
2. **Confirm it is this** — a command and what you expect to see; how to tell it
   from what resembles it.
3. **Act** — the commands, no prose.
4. **Verify** — how to check that it is fixed, and how long it takes to
   propagate if there is a cache or CDN in between.
5. **Escalate** — who is notified and what is switched off if it stays the same.
6. **History** — one line each time it happened.

To write it on the spot right after resolving an incident, use the `runbook`
skill.
