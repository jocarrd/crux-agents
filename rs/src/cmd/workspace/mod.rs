//! crux workspace — isolated workspaces to work in parallel.
//!
//! A git worktree isolates files, but not the runtime: two agents on the same
//! repo still fight over the port, the database and the .env. This shares out
//! those resources too, with a registry so two workspaces do not take the
//! same slot.
//!
//! The worktree is created as a sibling of the original repo, not in a
//! separate directory: that is what makes the relative context pointers
//! (../<project>-docs/) keep resolving inside the isolated workspace.

mod clean;
mod create;
mod list;
mod propose;

use crate::error::{Exit, Res};
use crate::names;
use crate::task::record;
use crate::{die, env, files, git, project, registry, ui};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

/// The "workspace" section of the contract, with the repo's own section laid
/// over the common one: the front, the backend and the panel of one project
/// need different things.
pub struct Config {
    pub port_base: i64,
    pub per_slot: i64,
    pub env_file: String,
    pub env_template: Map<String, Value>,
    pub setup: String,
    pub teardown: String,
    pub install: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            port_base: 3000,
            per_slot: 10,
            env_file: String::new(),
            env_template: Map::new(),
            setup: String::new(),
            teardown: String::new(),
            install: true,
        }
    }
}

fn number(v: Option<&Value>, default: i64) -> i64 {
    let n = match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.trim().parse::<f64>().unwrap_or(0.0),
        _ => 0.0,
    };
    if n == 0.0 || n.is_nan() {
        default
    } else {
        n as i64
    }
}

fn text(v: Option<&Value>) -> Option<String> {
    v.filter(|x| !x.is_null() && *x != &Value::Bool(false) && *x != &Value::String(String::new()))
        .map(files::value_text)
}

/// A contract that cannot be read stops it: an unreadable one is not "no
/// configuration", and treating it so started workspaces on default ports.
pub fn load_config(docs: Option<&Path>, repo: &str) -> Result<Config, Exit> {
    let Some(docs) = docs else { return Ok(Config::default()) };
    let file = docs.join(names::CONTRACT);
    if !file.is_file() {
        return Ok(Config::default());
    }
    let contract = match files::read_json(&file) {
        Ok(c) => c,
        Err(e) => {
            ui::err(format!("the contract of {} is unreadable — {e}", files::name(docs)));
            return Err(Exit(1));
        }
    };
    let w = contract.get("workspace").cloned().unwrap_or(Value::Null);
    let r = w.get("repos").and_then(|x| x.get(repo)).cloned().unwrap_or(Value::Null);
    let mut env_template = w.get("env").and_then(Value::as_object).cloned().unwrap_or_default();
    for (k, v) in r.get("env").and_then(Value::as_object).cloned().unwrap_or_default() {
        env_template.insert(k, v);
    }
    let install =
        !matches!(r.get("install").filter(|x| !x.is_null()).or_else(|| w.get("install")), Some(Value::Bool(false)));
    Ok(Config {
        port_base: number(w.get("portBase"), 3000),
        per_slot: number(w.get("portsPerSlot"), 10),
        env_file: text(r.get("envFile")).or_else(|| text(w.get("envFile"))).unwrap_or_default(),
        env_template,
        setup: text(r.get("setup")).or_else(|| text(w.get("setup"))).unwrap_or_default(),
        teardown: text(r.get("teardown")).or_else(|| text(w.get("teardown"))).unwrap_or_default(),
        install,
    })
}

/// What a workspace's configuration can refer to: its slot, its ports, its
/// name and its branch.
pub struct Slot<'a> {
    pub number: i64,
    pub first_port: i64,
    pub name: &'a str,
    pub branch: &'a str,
}

impl Slot<'_> {
    /// {{SLOT}}, {{PORTn}}, {{NAME}}, {{BRANCH}}.
    pub fn fill(&self, text: &str) -> String {
        substitute(text, self.number, self.first_port, self.name, self.branch)
    }
}

fn substitute(text: &str, slot: i64, port0: i64, name: &str, branch: &str) -> String {
    let t = text.replace("{{SLOT}}", &slot.to_string()).replace("{{NAME}}", name).replace("{{BRANCH}}", branch);
    crate::regex!(r"\{\{PORT(\d+)\}\}")
        .replace_all(&t, |c: &regex::Captures| (port0 + c[1].parse::<i64>().unwrap_or(0)).to_string())
        .into_owned()
}

/// The lowest slot with its range free. Each project starts from its own
/// base, so the ranges are compared too: two projects' slots can overlap.
pub fn free_slot(list: &[registry::Workspace], base: i64, per_slot: i64) -> Option<i64> {
    let taken: Vec<i64> = list.iter().map(|w| w.slot).collect();
    let ranges: Vec<(i64, i64)> = list.iter().map(|w| w.ports).collect();
    (0..=9999).find(|s| {
        let since = base + s * per_slot;
        let until = since + per_slot - 1;
        !taken.contains(s) && !ranges.iter().any(|(a, b)| since <= *b && *a <= until)
    })
}

/// What a plain git status does not show and is deleted with the worktree:
/// the workspace's database and whatever was left by hand. What an install
/// restores, the gate receipt, the local pointer and the env file crux itself
/// writes are left out; and a file identical to the main repo's is the copy
/// the workspace was born with.
/// What a build or a dev server writes again on its own: losing it costs
/// nothing, so it does not stop a workspace from being removed.
pub fn regenerable(path: &str) -> bool {
    let dirs = crate::regex!(
        r"^(.*/)?(node_modules|\.next|\.astro|\.svelte-kit|\.nuxt|\.output|\.vercel|\.wrangler|\.cache|\.parcel-cache|dist|build|target|\.venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.gradle|\.turbo|\.nx|\.pnpm-store|coverage|\.expo|[^/]+\.egg-info|src-tauri/gen)/"
    );
    let files = crate::regex!(r"^(.*/)?([^/]*\.tsbuildinfo|next-env\.d\.ts)$");
    dirs.is_match(path) || files.is_match(path)
}

pub fn ignored_files(dir: &Path, own: &str) -> Vec<String> {
    let main = git::main_repo(dir);
    let crux_own = crate::regex!(r"^(\.crux-ship|\.crux-visual|CLAUDE\.local\.md$)");
    git::out(dir, &["status", "--porcelain", "--ignored=matching"])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("!! "))
        .filter(|f| !crux_own.is_match(f) && !regenerable(f) && (own.is_empty() || *f != own))
        .filter(|f| match &main {
            Some(m) if m != dir && dir.join(f).is_file() && m.join(f).is_file() => {
                std::fs::read(dir.join(f)).ok() != std::fs::read(m.join(f)).ok()
            }
            _ => true,
        })
        .map(|f| format!("!! {f}"))
        .collect()
}

/// Removed only if nothing is lost: neither uncommitted changes nor commits
/// of its own that are in no remote. Against the main branch: in a repo with
/// no remote, HEAD --not --remotes is every commit of the project.
pub fn clean_workspace(w: &Path, env_file: &str) -> bool {
    if !git::out(w, &["status", "--porcelain"]).unwrap_or_default().is_empty() || !ignored_files(w, env_file).is_empty()
    {
        return false;
    }
    let base = project::main_branch(w);
    git::out(w, &["log", "--oneline", &format!("{base}..HEAD"), "--not", "--remotes"]).unwrap_or_default().is_empty()
}

/// A task archives itself when its last workspace closes, it is already
/// merged and no step is left. Still open, or with steps to do, it stays: a
/// workspace can close to resume the task from another, and one task can take
/// several proposals.
pub fn archive_if_finished(project_name: &str, task: &str) {
    let file = env::tasks_dir().join(project_name).join(format!("{task}.md"));
    let Ok(doc) = record::read(&file) else { return };
    let others =
        registry::read().unwrap_or_default().iter().filter(|w| w.project == project_name && w.task == task).count();
    if others > 0 {
        ui::info(format!("the task '{task}' is still in {others} more workspace(s)"));
        return;
    }
    // Merged but waiting for an answer: it stays alive until it arrives.
    let waiting = doc.text("waiting_on");
    if !waiting.is_empty() {
        ui::info(format!("the task '{task}' is waiting on {waiting}: not archiving"));
        return;
    }
    let pending = record::pending(&doc);
    if pending > 0 && matches!(doc.status(), Some(record::Status::Merged | record::Status::Deployed)) {
        ui::info(format!("the task '{task}' has {pending} pending step(s): not archiving"));
        ui::info(format!("when it is finished: crux task archive --task {project_name}/{task}"));
        return;
    }
    match doc.status() {
        Some(record::Status::Merged | record::Status::Deployed) => {
            crate::task::promote_decisions(&file);
            match record::archive(&file, true) {
                Ok(_) => ui::ok(format!("task '{task}' archived")),
                Err(e) => ui::warn(format!("could not archive the task: {e}")),
            }
        }
        Some(record::Status::Closed) => {}
        _ => {
            ui::info(format!("the task '{task}' is still open ({})", doc.text("status")));
            ui::info(format!("if it is no longer going: crux task archive --task {project_name}/{task}"));
        }
    }
}

pub fn find(name: &str) -> Result<registry::Workspace, Exit> {
    if let Err(e) = registry::init() {
        die!("cannot prepare the registry: {e}");
    }
    match registry::find(name) {
        Some(w) => Ok(w),
        None => die!("the workspace '{name}' does not exist"),
    }
}

pub fn lock() -> Result<registry::Lock, Exit> {
    registry::lock(300).map_err(|e| {
        ui::err(e);
        Exit(1)
    })
}

pub fn workspace_path(name: &str) -> Option<PathBuf> {
    registry::find(name).map(|w| PathBuf::from(w.path))
}

pub fn run(argv: &[String]) -> Res {
    if argv.iter().any(|a| a == "--help" || a == "-h") {
        super::help("workspace");
        return Ok(());
    }
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    match argv.first().map(String::as_str).unwrap_or("") {
        "new" => create::new(rest),
        "list" => {
            clean::heal(true)?;
            list::list(rest)
        }
        "resume" => create::resume(rest),
        "adopt" => create::adopt(rest),
        "heal" => clean::heal(rest.first().map(String::as_str) == Some("--quiet")),
        "finish" => propose::finish(rest),
        "merge" => propose::merge(rest),
        "rm" => clean::rm(rest),
        "gc" => clean::gc(rest),
        "prune" => clean::prune(rest),
        "help" => {
            super::help("workspace");
            Ok(())
        }
        _ => {
            eprintln!("{}", crate::help::text("workspace").unwrap_or_default());
            die!("usage: crux workspace {{new|list|resume|adopt|finish|merge|rm|gc|heal|prune}}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::regenerable;

    #[test]
    fn what_builds_write_again_does_not_block_removal() {
        for p in [
            "node_modules/x/y.js",
            "web/.next/cache/a",
            "src/app.egg-info/",
            "next-env.d.ts",
            "app/next-env.d.ts",
            "src-tauri/gen/schemas/",
            "tsconfig.tsbuildinfo",
        ] {
            assert!(regenerable(p), "{p}");
        }
        for p in [".env.local", "notes.txt", "src/gen/schemas/", "my-next-env.d.ts.bak", "data.db"] {
            assert!(!regenerable(p), "{p}");
        }
    }
}
