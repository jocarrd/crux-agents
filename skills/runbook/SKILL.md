---
name: runbook
description: Write the procedure for an incident that has just been resolved, in a form that can be executed with the system down — symptom as it is reported, how to confirm it, the commands, how to verify it was fixed and when to escalate. Use right after fixing something in production, when resolving a problem cost you rebuilding what you already knew, or when someone asks what to do if it happens again.
---

# runbook

A runbook is not written to document an incident. It is written **so that next
time nobody has to think**.

> **A runbook is measured by how long it takes someone in a hurry to get from the
> symptom to the command.**

## When to use

- Right after resolving something in production. **It is the only good moment**:
  cold, you remember the cause, not the three commands you ruled out.
- When fixing something has forced you to rediscover what you already knew.
- When someone asks what to do if it happens again.

## When not to use

- **The problem has a fix.** A runbook for something that can be eliminated is
  accepting that it will repeat. First ask whether it can be fixed; the runbook
  is for what does not depend on you or is not worth fixing.
- **The procedure repeats across several projects.** Then what you have is a
  skill. Cover the proper names: if it still makes sense, there is a pattern.
- **It has happened once and you do not know why.** What you have is an anecdote.
  Note it in the repo's notes and wait for the second time.

## The five parts

None is optional. The two that always get dropped are the two that hurt most.

### 1. Symptom

How it looks **from outside**, in the words of whoever suffers it. "El login no
hace nada" before the technical name of the failure: it is what someone types
when searching for it, and whoever is searching does not yet know the cause.

A runbook titled with its cause is only found by someone who no longer needs it.

### 2. Confirm

How to tell it apart from what resembles it. **It is the step that saves the most
time** and the one most often omitted, because by the time you write it you
already know what the problem was and it seems obvious.

It was not. If two different causes give the same symptom, this is where they
are separated, and without this part the wrong remedy is applied with full
confidence.

### 3. Act

The commands, in order, copyable. **Each step is a command, not a story.** If a
step needs a paragraph of explanation, either the step is badly chosen or the
explanation goes elsewhere and the runbook links.

What has to be decided is stated: what to look at to choose between two branches,
which value is normal and which is not.

### 4. Verify

How to know it was fixed, with a check that is executed. Without this, what is
not resolved is declared resolved, the incident is closed and it comes back half
an hour later.

If the effect takes time to propagate —a cache, a DNS, a CDN—, say how long.

### 5. Escalate

When to stop trying. A runbook without an exit turns every incident into a race
with no finish line, and at three in the morning that is what turns a ten-minute
outage into a two-hour one.

It goes with what to do then: who is notified, what is switched off, what is
said.

## Procedure

1. **Recover what you have just done.** The shell history, not memory. That is
   where the real commands are, including those that did not work.
2. **Keep the short path.** What you ruled out does not go in `Act`; if ruling it
   out was costly, it goes in `Confirm` as a way to tell cases apart.
3. **Write the symptom last**, when you already know what it was, but word it as
   if you did not.
4. **Check the commands.** Copied from the history, with the real paths,
   unabbreviated. A runbook with a command that does not run is worse than none.
5. **Link it from the symptom index**, if the project has one. A runbook that
   does not show up when you search does not exist.

## Where it goes

In `operations/` of the project's docs repo. One per file when the procedure is
long; grouped by system when they are short and share context.

The symptom index —the playbook— is the entry point: it lists what is seen and
which runbook it leads to. It is what gets opened first when something fails.

## Anti-patterns

- **The runbook that explains.** If it starts by telling the architecture, it has
  turned into documentation. The explanation goes in `architecture/`.
- **The step that says "check the logs".** Check what, where, looking for what. A
  step that has to be interpreted is not a step.
- **Writing it cold, the following week.** A plausible reconstruction comes out
  with the details changed. The detail is exactly the value.
- **The runbook that expires silently.** Paths, ports and third-party limits
  change. If the project marks the last verification, it is marked.

## Related

- `/root-cause` — before: understand what is happening. This is after
- `/adr` — when what was learned changes a decision, not just a procedure
- `/skill-creator` — when the procedure turns out to be worth it for several
  projects
