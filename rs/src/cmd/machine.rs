//! crux doctor --machine — checks that this machine can run the system.
//!
//! Projects are checked with `crux doctor`. This checks the other thing: the
//! tools, authentications and paths the skills depend on. It is the
//! difference between finding out that something is missing now or in the
//! middle of an incident.
//!
//! What is indispensable is reported as an error; what only some skills need,
//! as a warning, saying what you will be unable to do.

use crate::agent_hooks::Hook;
use crate::error::{exit, Res};
use crate::{env, files, registry, sh, ui};
use serde_json::Value;
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Tally {
    errors: Cell<u32>,
    warns: Cell<u32>,
}

impl Tally {
    fn fail(&self, m: impl AsRef<str>) {
        ui::err(m);
        self.errors.set(self.errors.get() + 1);
    }
    fn note(&self, m: impl AsRef<str>) {
        ui::warn(m);
        self.warns.set(self.warns.get() + 1);
    }
    fn needed(&self, cmd: &str, what: &str) {
        if sh::exists(cmd) {
            ui::ok(cmd)
        } else {
            self.fail(format!("missing {cmd} — {what}"))
        }
    }
    fn optional(&self, cmd: &str, what: &str) {
        if sh::exists(cmd) {
            ui::ok(cmd)
        } else {
            self.note(format!("no {cmd} — you will not be able to: {what}"))
        }
    }
}

fn hook_commands(settings: &Value) -> Vec<String> {
    let mut out = vec![];
    if let Some(groups) = settings.get("hooks").and_then(Value::as_object) {
        for list in groups.values() {
            for g in list.as_array().into_iter().flatten() {
                for h in g.get("hooks").and_then(Value::as_array).into_iter().flatten() {
                    out.push(h.get("command").and_then(Value::as_str).unwrap_or("").to_string());
                }
            }
        }
    }
    out
}

fn entries(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|e| e.flatten().map(|x| x.path()).collect()).unwrap_or_default()
}

pub fn run(_argv: &[String]) -> Res {
    let t = Tally { errors: Cell::new(0), warns: Cell::new(0) };
    println!("checking the machine");
    println!();
    t.needed("git", "the whole system rests on git");
    t.needed("bash", "the git hooks and the skills' scripts are bash");

    println!();
    let config = env::config_file_redirectable();
    if config.is_file() {
        ui::ok(format!("machine config in {}", config.display()));
    } else {
        t.fail(format!("missing {} — run install.sh", config.display()));
    }
    if sh::exists("crux") {
        ui::ok("crux command on the PATH")
    } else {
        t.note("crux is not on the PATH — add ~/.local/bin")
    }
    let skills_dir = env::claude_skills_dir();
    let linked = entries(&skills_dir);
    let in_kernel = entries(&env::crux_home().unwrap_or_default().join("skills")).len();
    if linked.is_empty() {
        t.fail("no skill materialized — run install.sh");
    } else {
        ui::ok(format!("{} skills available ({in_kernel} in the kernel)", linked.len()));
    }
    let broken =
        linked.iter().filter(|p| p.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) && !p.exists()).count();
    if broken > 0 {
        t.fail(format!("{broken} broken skill links — run install.sh"));
    }

    // A hook that points at a nonexistent file does not fail: it does
    // nothing, and the system looks guarded and is not.
    let settings_file =
        env::var("CLAUDE_SETTINGS").map(PathBuf::from).unwrap_or_else(|| env::home().join(".claude/settings.json"));
    if settings_file.is_file() {
        let settings = files::read_json(&settings_file).unwrap_or(Value::Null);
        let commands = hook_commands(&settings);
        let home = env::home().to_string_lossy().into_owned();
        let broken_hooks = commands
            .iter()
            .filter(|c| {
                let p = c.strip_prefix('~').map(|r| format!("{home}{r}")).unwrap_or_else(|| c.to_string());
                let first = p.split(' ').next().unwrap_or("");
                !first.is_empty() && !Path::new(first).exists()
            })
            .count();
        if broken_hooks > 0 {
            t.fail(format!("{broken_hooks} hooks point at files that do not exist — 'crux hooks status'"));
        }
        // None at all is the case of a new machine: the kernel installed, the
        // projects fetched and nothing hooked. A warning and not an error:
        // bootstrap requires this check to pass, and bootstrap is what hooks
        // them.
        let crux_hooks = commands
            .iter()
            .filter(|c| [Hook::DocSync, Hook::CycleGuard, Hook::MemoryGuard].iter().any(|h| c.contains(h.name())))
            .count();
        if crux_hooks == 0 {
            t.note("no crux hook installed — 'crux hooks install'");
        } else {
            ui::ok(format!("{crux_hooks} session hooks installed"));
        }
    } else {
        t.note(format!("no {}: no hook is installed — 'crux hooks install'", settings_file.display()));
    }

    println!();
    t.optional("gh", "create repos with crux init (use --no-remote meanwhile)");
    if sh::exists("gh") {
        if sh::capture("gh", &["auth", "status"]).ok() {
            ui::ok("gh authenticated")
        } else {
            t.note("gh not authenticated — 'gh auth login'")
        }
    }
    t.optional("node", "prod-signals, code-health, skill-audit and the browser skills");
    t.optional("curl", "deploy-watch, checking a deployment answers");
    t.optional("python3", "visual-diff, render-loop and any image analysis");
    if sh::exists("python3") {
        if sh::capture("python3", &["-c", "import numpy, PIL"]).ok() {
            ui::ok("numpy and Pillow");
        } else {
            t.note("no numpy or Pillow — you will not be able to: compare or measure images");
        }
    }
    t.optional("pdftoppm", "compare PDFs with visual-diff");
    t.optional("docker", "deploy-fallback and the per-workspace databases");
    t.optional("adb", "device-loop, testing on an Android emulator");
    t.optional("rsync", "publish a demo with crux stg");
    if ["google-chrome", "google-chrome-stable", "chromium"].iter().any(|c| sh::exists(c)) {
        ui::ok("browser for headless");
    } else {
        t.note("no Chrome or Chromium — you will not be able to: visual-test");
    }

    // What expires on its own —an OAuth refresh token, a CLI session— belongs
    // to the machine, not to a project, and the kernel cannot name it. Whoever
    // uses it declares the check in ~/.crux/machine-checks.json. Each runs
    // with a time limit: a check that hangs is reported, it does not hang the
    // doctor.
    let checks_file = env::var("CRUX_MACHINE_CHECKS")
        .map(PathBuf::from)
        .unwrap_or_else(|| env::home().join(".crux/machine-checks.json"));
    if checks_file.is_file() {
        println!();
        let limit: u64 = env::var("CRUX_MACHINE_CHECK_TIMEOUT").and_then(|v| v.parse().ok()).unwrap_or(20);
        let parsed = files::read_json(&checks_file).and_then(|c| {
            let list = c.get("checks").and_then(Value::as_array).cloned().unwrap_or_default();
            list.into_iter()
                .map(|k| {
                    let s = |x: &str| k.get(x).and_then(Value::as_str).unwrap_or("").to_string();
                    if s("name").is_empty() || s("command").is_empty() {
                        Err("a check without name or command".to_string())
                    } else {
                        Ok((s("name"), s("command"), s("fix")))
                    }
                })
                .collect::<Result<Vec<_>, _>>()
        });
        match parsed {
            Err(e) => t.fail(format!("{} cannot be read: {e}", checks_file.display())),
            Ok(list) => {
                for (name, command, fix) in list {
                    let fix = if fix.is_empty() { String::new() } else { format!(" — {fix}") };
                    let r = sh::with_timeout(Command::new("bash").args(["-c", &command]), limit);
                    match r.code {
                        0 => ui::ok(&name),
                        124 => t.note(format!("{name}: no answer in {limit} s{fix}")),
                        _ => {
                            // The whole output on one line: a JSON error starts
                            // with a lone "{".
                            let one: String =
                                format!("{}{}", r.stdout, r.stderr).split_whitespace().collect::<Vec<_>>().join(" ");
                            let one: String = one.chars().take(120).collect();
                            t.note(format!("{name}: {one}{fix}"));
                        }
                    }
                }
            }
        }
    }

    if registry::path().is_file() {
        if let Ok(list) = registry::read() {
            let dead: Vec<&str> =
                list.iter().filter(|w| !Path::new(&w.path).exists()).map(|w| w.name.as_str()).collect();
            if !list.is_empty() {
                ui::ok(ui::count(list.len(), "registered workspace", "registered workspaces"));
            }
            if !dead.is_empty() {
                t.note(format!(
                    "workspaces in the registry without a directory: {} — 'crux workspace gc'",
                    dead.join(",")
                ));
            }
            // The registry and the disk also drift apart the other way round.
            let root = env::projects_root();
            let registered: Vec<&str> = list.iter().map(|w| w.path.as_str()).collect();
            let mut loose = 0;
            let mut candidates = vec![];
            for a in entries(&root) {
                if a.is_dir() {
                    candidates.push(a.clone());
                    candidates.extend(entries(&a).into_iter().filter(|b| b.is_dir()));
                }
            }
            for d in candidates {
                let name = d.file_name().unwrap_or_default().to_string_lossy();
                if !name.contains("-ws-") || registered.contains(&d.to_string_lossy().as_ref()) {
                    continue;
                }
                if crate::git::ok(&d, &["rev-parse", "--git-dir"]) {
                    loose += 1;
                }
            }
            if loose > 0 {
                t.note(format!("{loose} worktrees on disk that the registry does not know — 'crux workspace gc'"));
            }
        }
    }

    println!();
    let (e, w) = (t.errors.get(), t.warns.get());
    if e == 0 && w == 0 {
        let p = ui::palette();
        println!("{}ready{} — this machine can handle everything", p.green, p.off);
    } else {
        println!(
            "{e} {}, {w} {}",
            if e == 1 { "error" } else { "errors" },
            if w == 1 { "warning" } else { "warnings" }
        );
        if w > 0 && e == 0 {
            println!("Warnings do not block: they only limit which skills you can use.");
        }
    }
    if e > 0 {
        exit(1)
    } else {
        Ok(())
    }
}
