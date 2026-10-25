#!/usr/bin/env node
// Runs the binary built for this machine with the same arguments. There is no
// postinstall: installing the package touches nothing until crux is run.
"use strict";
const { spawnSync } = require("node:child_process");
const { chmodSync, existsSync, statSync } = require("node:fs");
const { join } = require("node:path");

const platform = `${process.platform}-${process.arch}`;
const bin = join(__dirname, "..", "vendor", `crux-${platform}`);
if (!existsSync(bin)) {
  console.error(`crux has no binary for ${platform}: it ships for Linux and macOS, on x64 and arm64.`);
  console.error("It can be built from source: https://github.com/jocarrd/crux");
  process.exit(1);
}
// Some installers unpack without the executable bit.
try {
  if ((statSync(bin).mode & 0o111) === 0) chmodSync(bin, 0o755);
} catch {
  // A read-only global install: spawning reports the real error below.
}
const run = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (run.error) {
  console.error(`cannot run ${bin}: ${run.error.message}`);
  process.exit(1);
}
if (run.signal) process.kill(process.pid, run.signal);
process.exit(run.status ?? 1);
