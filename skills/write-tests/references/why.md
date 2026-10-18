# Reasons behind test-first

The procedure is in `SKILL.md`.

## The bug

The red test is the proof that you understood the bug; the green one, the
proof that you fixed it. Without it, "fixed" means "I no longer see it".

## The known contract

When what goes in and what comes out is known before the code, writing it down
first makes the test check the contract and not whatever the code happened to
do. A test written afterwards tends to copy the implementation, mistakes
included.

## Why not always

Forcing test-first where the contract does not exist yet produces tests that
get rewritten with every change. While an approach is being explored, the test
pins down a shape that is about to move, and the cost of rewriting it is paid
on every iteration without catching anything.
