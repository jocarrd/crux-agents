---
name: security-audit
description: Find real vulnerabilities in a repository with Cloudflare's multi-phase audit: map trust boundaries, hunt with isolated agents, disprove every candidate with an independent one and report only what holds. Works on source and sandboxed local checks, never on live systems. Use when asked to audit a codebase or a system for vulnerabilities, for a pen test of the code, whether a service, API or daemon is exploitable, or when a security question needs more than a look at a diff. For the security angle of one open proposal, use review-pr.
---

# security-audit

This is an adapter. The method is Cloudflare's and lives untouched in
`<this-skill-directory>/upstream/security-audit/`; read its `METHOD.md`, upstream's
`SKILL.md` renamed, and follow it. Here
are only the decisions the method leaves to whoever runs it. The reasons are in
`<this-skill-directory>/references/why.md`.

## Before starting

1. **Choose the mode.** The method separates guidance from a full audit.
   A focused question stays in guidance mode: no artifacts and no six phases.
2. **Give the cost first.** A full audit launches dozens of agents. Present the
   scope, the profile and a maximum number of agents, and wait for a yes. That
   number is the `budget` of the run. Do not start a full audit on a guess.
3. **One target per run.** A project with several repositories is several runs,
   riskiest first. Start with what receives untrusted input and holds data. Use
   `quick` or a scoped run for a first pass and say that coverage is partial.
4. **Keep the results out of the repository.** Use the default output directory
   outside the target. A report of open vulnerabilities must not reach a public
   repository, a change proposal or a chat.

## The limits do not bend

- Source and sandboxed local checks only. No probing of deployed endpoints, even
  your own and even if the owner would agree. What depends on the live system
  stays `needs_validation`, with the owner's safe way to check it.
- Do not read secrets to audit them. Environment files, credentials and keys on
  disk or in containers stay closed: a secret that may have leaked is reported
  from its path and its Git history, without printing its value.
- Without an OS-enforced sandbox, target code does not run. The lead is recorded
  as `needs_validation`. The method's validators are not target code: they
  only read the run's JSON and can run directly.

## After the report

- Only `confirmed` findings become work: one task per root cause, without the
  exploit details in a place others can read.
- Fix through the project's normal flow, with a regression test. The audit
  describes the fix and never applies it.
- Run it again after the fixes. Upstream measured that one run finds roughly half
  of what repeated runs find, so one clean run does not mean a clean system.

## Updating from upstream

`upstream/UPSTREAM.md` records the commit. To update: fetch that repository, read
the diff in full as you would any third-party change, replace `upstream/security-audit/`
without editing its files, run the two `*.test.cjs` and record the new commit. A local
change belongs in this file, never in `upstream/`.

## Related

- `review-pr` — the security angle of one proposal
- `prod-signals` — what is happening in production, read-only
