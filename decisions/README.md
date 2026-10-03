# Kernel decisions

This is where **why** the kernel is the way it is gets recorded. The rules live
in `STANDARD.md`; the reason they were chosen lives here.

These are not the same as a project's decisions: they affect every project that
consumes the kernel, so changing them has a cost that is worth having written
down before reopening the debate.

## Format

The same one the standard imposes on projects, so there are not two:

```markdown
### ADR-NNN: Title

- **Date**: YYYY-MM-DD
- **Status**: Proposed | Accepted | Superseded
- **Context**: what problem or situation motivates it
- **Decision**: what we decided
- **Consequences**: how the kernel and the projects that consume it change
- **Reversibility**: how expensive it would be to undo
- **Related**: refs to other ADRs
```

Sequential numbering. When superseding, the old one is marked, not deleted.
