# Why it is done this way

The procedure is in `SKILL.md`.

## Why an emulator

It can be set up on any machine without anyone holding a phone: no cable, no
developer options, no udev rules, no manufacturer layer swallowing taps. And
the agent can start it, reset it and change its state (dark mode, font size)
by itself.

## Why without Android Studio

The emulator, the SDK and a portable JDK are what is needed, and they install
under the home without `sudo`. Android Studio adds gigabytes and a graphical
setup the agent cannot drive.

## Why hardware acceleration

Without KVM the emulator translates every instruction in software: boot takes
minutes and any GL surface stutters until it is unusable, which looks like an
app problem when it is not.

## Why `swiftshader_indirect`

Headless there is no display for the host GPU. SwiftShader renders in software
on the CPU and works the same on every machine; with a display and a decent
GPU, `-gpu host` is faster.

## Why `am kill` and not `force-stop`

Android marks a force-stopped app as stopped and does not deliver it broadcasts
—widget taps, scheduled notifications— until the user opens it by hand. `am
kill` from the home screen ends the process without that mark.

## Why compile only for x86_64

The emulator image is x86_64. Building the four architectures multiplies the
native compile time for code the emulator never runs.
