# Why it is done this way

The procedure is in `SKILL.md`.

## Why a physical device

Without hardware virtualisation, the emulator runs in software and any GL
surface suffers until it is unusable.

## Why taps do not arrive

Some manufacturer layers require an extra debugging permission that in turn asks
for a manufacturer account and a SIM. The symptom is that taps do nothing, or
that the background receives the gesture instead of the control.

## Why a clean mount

Fast Refresh preserves state and does not rerun effects with stable
dependencies: the instrumentation that opens the screen would not run without
force-stopping the app.
