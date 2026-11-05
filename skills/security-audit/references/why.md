# Why the audit works this way

The procedure is in `SKILL.md`; the method in `upstream/security-audit/METHOD.md`.

## Why an adapter and a verbatim copy

The method is 3,115 words and the kernel's limit for a `SKILL.md` is 1,000.
Cutting it would remove the steps that make its results reliable, such as the
independent verifier and the write-isolation procedure. Keeping it untouched also
makes each update a diff against the source that anyone can read. Its
`SKILL.md` is renamed `METHOD.md` because the kernel treats every `SKILL.md` as a
skill, and this one must not be offered as a second entry or checked against the
limit.

## Why the cost comes first

One unit of coverage is one agent, and every candidate takes one or two more. On
a large repository that is a real bill, and the person paying should choose the
scope. Upstream supports a `budget` for this reason.

## Why one target per run

The ledger, the prior-run logic and the coverage statement are per repository.
Several repositories in one run blur what was actually covered.

## Why the results stay outside the repository

A list of open vulnerabilities with their source paths is a guide to attacking
the project. Upstream defaults to an external directory, and this keeps it.

## Why secrets stay closed

Reading a credential to check it puts it in the agent's context and transcript,
which is a leak of its own. A secret's presence is established from its path and
history.
