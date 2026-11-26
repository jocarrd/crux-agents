//! `crux __install`: what install.sh does once it has the binary. Idempotent.
//!
//! Projects consume the kernel through a per-version copy: linked to the
//! working copy, they would use whatever is in it at any moment, and a
//! half-finished branch would change the behaviour of every project.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, files, git, project, skills, ui};
use regex::Regex;
use serde_json::Value;
use std::path::{Path, PathBuf};

include!("../../kernel_pieces.rs");

/// The kernel this binary was built from: without a clone, it is what gets
/// installed.
static PACK: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/kernel.pack"));

/// The version this binary carries, whether or not it is installed yet.
pub fn packed_version() -> String {
    packed()
        .find(|(p, _, _)| p == names::VERSION)
        .map(|(_, _, b)| String::from_utf8_lossy(b).split_whitespace().collect())
        .unwrap_or_default()
}

fn packed() -> impl Iterator<Item = (String, u32, &'static [u8])> {
    let mut rest = PACK;
    std::iter::from_fn(move || {
        let mut line = || {
            let n = rest.iter().position(|b| *b == b'\n')?;
            let l = String::from_utf8_lossy(&rest[..n]).into_owned();
            rest = &rest[n + 1..];
            Some(l)
        };
        let path = line()?;
        let mode = u32::from_str_radix(&line()?, 8).ok()?;
        let len: usize = line()?.parse().ok()?;
        let bytes = rest.get(..len)?;
        rest = &rest[len..];
        Some((path, mode, bytes))
    })
}

fn unpack(target: &Path) -> Result<(), String> {
    for (path, mode, bytes) in packed() {
        let file = target.join(&path);
        if let Some(d) = file.parent() {
            std::fs::create_dir_all(d).map_err(|e| format!("cannot create {}: {e}", d.display()))?;
        }
        std::fs::write(&file, bytes).map_err(|e| format!("cannot write {}: {e}", file.display()))?;
        std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(mode))
            .map_err(|e| format!("cannot set the mode of {}: {e}", file.display()))?;
    }
    Ok(())
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(from)?;
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(from)?;
        let _ = std::fs::remove_file(to);
        return std::os::unix::fs::symlink(target, to);
    }
    if meta.is_dir() {
        std::fs::create_dir_all(to)?;
        for e in std::fs::read_dir(from)?.flatten() {
            copy_tree(&e.path(), &to.join(e.file_name()))?;
        }
        return Ok(());
    }
    std::fs::copy(from, to).map(|_| ())
}

/// The agent hooks carry the version in their path: without this, sessions
/// keep running the previous kernel until someone reinstalls the hooks.
fn move_hooks(file: &Path, kernels: &Path, target: &Path, plugin_dirs: bool) -> Result<usize, String> {
    let mut s = files::read_json(file).map_err(|e| format!("{} cannot be read: {e}", file.display()))?;
    let k = regex::escape(&kernels.to_string_lossy());
    let old = Regex::new(&format!("{k}/[^/]+/adapters/")).unwrap();
    let new = format!("{}/adapters/", target.display());
    let mut n = 0;
    if let Some(hooks) = s.get_mut("hooks").and_then(Value::as_object_mut) {
        for groups in hooks.values_mut() {
            for g in groups.as_array_mut().into_iter().flatten() {
                for h in g.get_mut("hooks").and_then(Value::as_array_mut).into_iter().flatten() {
                    let cmd = h.get("command").and_then(Value::as_str).unwrap_or("").to_string();
                    let moved = old.replace_all(&cmd, regex::NoExpand(&new)).into_owned();
                    if moved != cmd {
                        h.as_object_mut().unwrap().insert("command".into(), Value::String(moved));
                        n += 1;
                    }
                }
            }
        }
    }
    if plugin_dirs {
        let dirs_re = Regex::new(&format!("{k}/[^/:]+/adapters/")).unwrap();
        if let Some(e) = s.get_mut("env").and_then(Value::as_object_mut) {
            if let Some(dirs) = e.get(crate::names::agents::PLUGIN_DIRS).and_then(Value::as_str).map(String::from) {
                let updated = dirs_re.replace_all(&dirs, regex::NoExpand(&new)).into_owned();
                if updated != dirs {
                    e.insert(crate::names::agents::PLUGIN_DIRS.into(), Value::String(updated));
                    n += 1;
                }
            }
        }
    }
    if crate::cmd::hooks::strip_retired(&mut s) {
        n += 1;
    }
    if n > 0 {
        files::write(file, &files::json_pretty(&s))?;
    }
    Ok(n)
}

/// The `crux` on the PATH. It belongs to no installation: it runs the one
/// CRUX_DIR names; else the one that claimed the folder of the agent running
/// it, read from the variable each agent opens its folder with; else ~/.crux
/// (ADR-027). Any agent works the same way: no agent's settings are touched.
const DISPATCHER: &str = r#"#!/usr/bin/env bash
# Written by crux install. Every crux installation on this machine shares this
# command: it runs the one CRUX_DIR names; inside an agent, the one that agent's
# folder belongs to (its crux-installation file); otherwise ~/.crux.
dir="${CRUX_DIR:-}"
for agent in "${CLAUDE_CONFIG_DIR:-}" "${CODEX_HOME:-}"; do
  if [[ -z "$dir" && -n "$agent" && -f "$agent/crux-installation" ]]; then
    dir="$(head -n 1 "$agent/crux-installation")"
  fi
done
dir="${dir:-$HOME/.crux}"
if [[ ! -x "$dir/bin/crux" ]]; then
  echo "crux: no installation in $dir (CRUX_DIR): install one there, or unset CRUX_DIR" >&2
  exit 127
fi
exec "$dir/bin/crux" "$@"
"#;

pub fn run(argv: &[String]) -> Res {
    let (mut dry, mut dev, mut remote, mut projects_dir) = (false, false, String::new(), String::new());
    let mut identity: Vec<(&str, String)> = Vec::new();
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--dry-run" => dry = true,
            "--dev" => dev = true,
            "--remote" => remote = p.value(),
            "--projects-dir" => projects_dir = p.value(),
            "--git-name" => identity.push((crate::names::vars::GIT_NAME, p.value())),
            "--git-email" => identity.push((crate::names::vars::GIT_EMAIL, p.value())),
            "--gh-config-dir" => identity.push((crate::names::vars::GH_CONFIG, p.value())),
            _ => {}
        }
    }
    if dry {
        std::env::set_var(crate::names::vars::DRY_RUN, "1");
    }
    // The installed command points CRUX_HOME at the kernel copy it runs: that
    // is not a clone, and taking it for one deleted it before copying from it.
    let installed = env::kernels_dir();
    let clone = env::var(crate::names::vars::HOME)
        .map(PathBuf::from)
        .filter(|h| h.join(names::VERSION).is_file())
        .filter(|h| !h.canonicalize().unwrap_or_else(|_| h.clone()).starts_with(&installed));
    if dev && clone.is_none() {
        die!("--dev links a kernel clone: run it from one, through install.sh");
    }
    let origin = clone.clone().unwrap_or_default();
    let version = match &clone {
        Some(c) => files::read_or_empty(&c.join(names::VERSION)),
        None => packed()
            .find(|(p, _, _)| p == names::VERSION)
            .map(|(_, _, b)| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default(),
    }
    .split_whitespace()
    .collect::<String>();
    // This version is part of a path that is deleted below: a VERSION with ../
    // would delete whatever was there.
    if !project::is_semver(&version) {
        die!("VERSION is not a valid version: '{version}'");
    }
    // In dev everything hangs off this directory: if it is a worktree,
    // closing it leaves the machine without skills.
    if dev && clone.is_some() && git::is_worktree(&origin) {
        ui::err(format!("this is a kernel worktree: {}", origin.display()));
        ui::info("in dev the skills would hang off an ephemeral directory");
        ui::info(format!(
            "install from the main checkout ({}), or without --dev",
            git::main_repo(&origin).unwrap_or_default().display()
        ));
        return exit(1);
    }
    if clone.is_some() && git::is_worktree(&origin) {
        ui::warn(format!(
            "installing from a worktree: the copy will be of branch {}",
            git::out(&origin, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default()
        ));
    }
    // Before anything is written, the kernel copy included: an agent folder
    // another installation already serves stops the install here, with
    // nothing of this one left behind.
    let claimed = match crate::installation::claim_agents() {
        Ok(c) => c,
        Err(e) => die!("{e}"),
    };
    let home = env::home();
    let mut kernel = origin.clone();
    if !dev && !dry {
        let target = env::kernels_dir().join(&version);
        // The binary goes with the copy: the kernel of a version runs the
        // commands of that version. Read before the target is emptied, since
        // installing again from the installed command runs from inside it.
        let binary = env::var(crate::names::vars::BIN)
            .map(PathBuf::from)
            .or_else(|| std::env::current_exe().ok())
            .unwrap_or_default();
        let binary_bytes = match std::fs::read(&binary) {
            Ok(b) => b,
            Err(e) => die!("cannot read the binary {}: {e}", binary.display()),
        };
        let _ = std::fs::remove_dir_all(&target);
        let _ = std::fs::create_dir_all(&target);
        if clone.is_none() {
            if let Err(e) = unpack(&target) {
                die!("{e}");
            }
        }
        for piece in KERNEL_PIECES.iter().filter(|_| clone.is_some()) {
            let from = origin.join(piece);
            if from.exists() {
                if let Err(e) = copy_tree(&from, &target.join(piece)) {
                    die!("could not copy {piece} to {}: {e}", target.display());
                }
            }
        }
        let core = target.join("bin/crux-core");
        if let Err(e) = std::fs::create_dir_all(target.join("bin")).and_then(|_| std::fs::write(&core, &binary_bytes)) {
            die!("could not copy the binary to {}: {e}", core.display());
        }
        let _ = std::fs::set_permissions(&core, std::os::unix::fs::PermissionsExt::from_mode(0o755));
        kernel = target;
        std::env::set_var(crate::names::vars::HOME, &kernel);
    }
    println!("crux {version} — {}", kernel.display());
    if dev {
        ui::warn("dev mode: projects will use your working copy, as it is at any moment");
    }
    if dry {
        ui::warn("dry-run: nothing is written");
    }
    println!();
    if !claimed.is_empty() {
        ui::ok(format!("agents this installation serves: {}", claimed.join(", ")));
    }

    // The root is deduced from the kernel clone, not from the copy: the
    // copy's parent is the kernels directory and contains no project.
    let config = env::config_file();
    let mut root_text = "deduced from where the kernel clone is";
    let from_flag = !projects_dir.is_empty();
    let mut root = projects_dir.clone();
    if root.is_empty() {
        if let Some(mut declared) = env::config_value_in(&config, env::PROJECTS_DIR_KEY) {
            // Older installs wrote the kernels directory as the root.
            if Path::new(&declared) == env::kernels_dir() {
                ui::warn("the declared root was the kernels directory: fixing it");
                declared.clear();
            }
            if !declared.is_empty() {
                root = declared;
                root_text = "kept from the previous install";
            }
        }
    }
    let root = match (root.is_empty(), &clone) {
        (false, _) => root,
        (true, Some(c)) => env::root_of_kernel_clone(c).display().to_string(),
        (true, None) => {
            root_text = "the default";
            env::default_projects_root().display().to_string()
        }
    };
    // The agent folders this installation serves, read before the config is
    // rewritten: from the environment, or kept from the previous install, so
    // reinstalling from a plain terminal does not move it to ~/.claude.
    let agents = [
        (crate::names::agents::CLAUDE_CONFIG_DIR, env::claude_config_dir()),
        (crate::names::agents::CODEX_HOME, env::codex_home_dir()),
    ];
    if !dry {
        let _ = std::fs::create_dir_all(env::crux_dir());
        let previous = match files::read_if_exists(&config) {
            Ok(t) => t,
            Err(e) => die!("{e} — the lines you added there would be lost"),
        };
        let previous_remote = previous.lines().find(|l| l.starts_with("CRUX_REMOTE=")).map(String::from);
        // Lines the person added are theirs and survive the rewrite.
        let managed = crate::regex!(
            r"^(CRUX_HOME|CRUX_MODE|CRUX_REMOTE|CRUX_PROJECTS_DIR|CLAUDE_CONFIG_DIR|CODEX_HOME|CRUX_GIT_NAME|CRUX_GIT_EMAIL|CRUX_GH_CONFIG_DIR)=|^# Generated by crux install\.sh$"
        );
        let kept: Vec<&str> = previous.lines().filter(|l| !managed.is_match(l) && !l.is_empty()).collect();
        let mut text = format!(
            "# Generated by crux install.sh\nCRUX_HOME=\"{}\"\nCRUX_MODE=\"{}\"\n",
            kernel.display(),
            if dev { "dev" } else { "release" }
        );
        if !remote.is_empty() {
            text.push_str(&format!("CRUX_REMOTE=\"{remote}\"\n"));
        } else if let Some(r) = previous_remote {
            text.push_str(&format!("{r}\n"));
        }
        text.push_str(&format!("{}=\"{root}\"\n", env::PROJECTS_DIR_KEY));
        for (key, dir) in &agents {
            text.push_str(&format!("{key}=\"{}\"\n", dir.display()));
        }
        for (key, _) in crate::names::vars::IDENTITY {
            let given = identity.iter().rev().find(|(k, _)| *k == key).map(|(_, v)| v.clone());
            if let Some(v) = given.or_else(|| env::config_value_in(&config, key)) {
                text.push_str(&format!("{key}=\"{v}\"\n"));
            }
        }
        for k in kept {
            text.push_str(&format!("{k}\n"));
        }
        if let Err(e) = std::fs::write(&config, text) {
            die!("cannot write {}: {e}", config.display());
        }
    }
    ui::ok(format!("config in {}", config.display()));
    ui::info(format!("projects root: {root}"));
    if !from_flag {
        ui::info(format!("({root_text}; change it with --projects-dir)"));
    }

    // The installation's own command, inside its folder, and the one on the
    // PATH that every installation shares and that hands over by CRUX_DIR.
    let own = env::installation_bin_dir();
    let bin_dir = env::command_dir();
    if !dry {
        let _ = std::fs::set_permissions(kernel.join("bin/crux"), std::os::unix::fs::PermissionsExt::from_mode(0o755));
        let _ = std::fs::create_dir_all(&own);
        let _ = std::fs::remove_file(own.join("crux"));
        if let Err(e) = std::os::unix::fs::symlink(kernel.join("bin/crux"), own.join("crux")) {
            die!("cannot leave the command in {}: {e}", own.display());
        }
        let _ = std::fs::create_dir_all(&bin_dir);
        let shared = bin_dir.join("crux");
        let _ = std::fs::remove_file(&shared);
        if let Err(e) = std::fs::write(&shared, DISPATCHER) {
            die!("cannot write {}: {e}", shared.display());
        }
        let _ = std::fs::set_permissions(&shared, std::os::unix::fs::PermissionsExt::from_mode(0o755));
    }
    ui::ok(format!("command in {}/crux, run through {}/crux", own.display(), bin_dir.display()));
    let on_path = std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d == bin_dir));
    if !on_path {
        ui::warn(format!("{} is not on your PATH — add it to use 'crux' directly", bin_dir.display()));
    }

    skills::materialize(&kernel.join("skills"), "kernel");
    // A skill the kernel retired or renamed leaves a link to nothing behind,
    // and the agent keeps offering it.
    skills::prune();
    ui::ok("kernel skills materialized (Claude + Codex)");
    if !dev && !dry {
        let settings = env::claude_settings();
        if settings.is_file() {
            let n = match move_hooks(&settings, &env::kernels_dir(), &kernel, true) {
                Ok(n) => n,
                Err(e) => die!("{e} — the agent hooks still run the previous kernel"),
            };
            if n > 0 {
                ui::ok(format!("agent hooks moved to {version} ({n})"));
            }
        }
        let codex = env::codex_home_dir().join("hooks.json");
        if codex.is_file() {
            let n = match move_hooks(&codex, &env::kernels_dir(), &kernel, false) {
                Ok(n) => n,
                Err(e) => die!("{e} — the Codex hooks still run the previous kernel"),
            };
            if n > 0 {
                ui::ok(format!("Codex hooks moved to {version} ({n})"));
            }
        }
    }
    if skills::codex_global(&kernel) {
        ui::ok("global Codex context in ~/.codex/AGENTS.md");
    }
    if !dry && super::call_quiet(&home, "profile", &["link"]).ok() {
        ui::ok("person's profile loaded into the agents");
    }
    println!();
    if dev {
        println!("Dev mode: linked to {}", kernel.display());
        println!("To go back to an immutable version: install.sh");
    } else {
        println!("Installed {version} in {}", kernel.display());
        println!("Your projects use that copy, not your working copy: when the kernel changes, run the install again.");
        println!("To develop the kernel itself: install.sh --dev");
    }
    println!();
    // On a new machine the step is bootstrap: adopt needs a docs repo that is
    // not on disk yet.
    println!("Next step: on a new machine, 'crux bootstrap'; on one you already used, 'crux sync'.");
    println!("For a new project: 'crux init <project>'; for a docs repo that exists, 'crux adopt'.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::move_hooks;
    use std::path::Path;

    #[test]
    fn moving_the_hooks_takes_out_the_ones_this_version_no_longer_ships() {
        let dir = std::env::temp_dir().join(format!("crux-move-hooks-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("settings.json");
        let old = "/k/0.87.1/adapters/claude/hooks";
        std::fs::write(
            &file,
            format!(
                r#"{{"hooks":{{"PreToolUse":[{{"matcher":"Bash","hooks":[
                    {{"type":"command","command":"{old}/scope-guard.sh"}},
                    {{"type":"command","command":"{old}/destructive-guard.sh"}}]}}]}}}}"#
            ),
        )
        .unwrap();
        move_hooks(&file, Path::new("/k"), Path::new("/k/0.88.0"), false).unwrap();
        let after = std::fs::read_to_string(&file).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!after.contains("scope-guard"), "{after}");
        assert!(after.contains("/k/0.88.0/adapters/claude/hooks/destructive-guard.sh"), "{after}");
    }
}
