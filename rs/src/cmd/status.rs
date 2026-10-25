//! crux status — what is open right now, across all projects.
//!
//!   crux status            the projects, their workspaces and the unpublished work
//!   crux status --check    also runs each project's doctor; exits 1 if anything fails
//!
//! `doctor` answers for one project. This answers for the morning: where the
//! work was left, which workspaces are still alive and what is pushed nowhere.
//! No network: what cannot be known locally is not asked.

use crate::error::{exit, Res};
use crate::names;
use crate::task::remind;
use crate::{env, files, git, project, registry, sh, ui};
use std::collections::{BTreeSet, HashMap};
use std::path::Path;

fn cut(t: &str, n: usize) -> String {
    t.chars().take(n).collect()
}

pub fn run(argv: &[String]) -> Res {
    let check = argv.first().map(String::as_str) == Some("--check");
    let root = env::projects_root();
    let problems = projects(&root, check);
    let live = workspaces(&root);
    tasks_elsewhere(&live);
    unpublished_work(&root);
    // --check exists to hook it to something automatic: it has to be able to fail.
    if check && problems > 0 {
        return exit(1);
    }
    Ok(())
}

/// Returns how many projects have problems.
fn projects(root: &Path, check: bool) -> usize {
    println!("projects in {}", root.display());
    println!();
    let (mut projects, mut problems) = (0, 0);
    for p in project::subdirs(root) {
        for d in project::subdirs(&root.join(&p)).into_iter().filter(|d| d.ends_with("-docs")) {
            let docs = root.join(&p).join(&d);
            if !docs.join(names::CONTRACT).is_file() {
                continue;
            }
            projects += 1;
            let c = match project::read_contract(&docs) {
                Ok(c) => c,
                Err(e) => {
                    println!("  {p:<14} unreadable contract — {e}");
                    ui::info(format!("fix it or see what is wrong: crux doctor {}", docs.display()));
                    problems += 1;
                    continue;
                }
            };
            let version = files::get_str(&c, "crux").unwrap_or_else(|| "?".into());
            let repos = files::str_list(c.get("repos")).len();
            let mut state = String::new();
            if check {
                let r = super::call_quiet(&docs, "doctor", &[&docs.to_string_lossy()]);
                if !r.ok() {
                    problems += 1;
                }
                let out = format!("{}{}", r.stdout, r.stderr);
                state = out.trim_end().lines().last().unwrap_or("").to_string();
                if state.starts_with("conformant") || state.starts_with("conforme") {
                    state = "conformant".into();
                }
            }
            let tail = if state.is_empty() { String::new() } else { format!("  ·  {state}") };
            println!("  {p:<14} crux {version:<8} {repos} repos{tail}");
        }
    }
    if projects == 0 {
        ui::info("none under that root ('install.sh --projects-dir' if it is not yours)");
    }
    problems
}

fn workspaces(root: &Path) -> Vec<registry::Workspace> {
    println!();
    println!("workspaces");
    println!();
    let heal = super::call_quiet(&std::env::current_dir().unwrap_or_default(), "workspace", &["heal", "--quiet"]);
    for l in heal.stdout.lines() {
        println!("  {l}");
    }
    let live: Vec<registry::Workspace> = registry::read().unwrap_or_default();
    if !registry::path().is_file() {
        println!("  none");
        return live;
    }
    if live.is_empty() {
        println!("  none");
    }
    // The columns fit the longest name: a fixed width pushes the long ones out
    // of line.
    let name_w = live.iter().map(|w| w.name.chars().count()).max().unwrap_or(0);
    let branch_w = live.iter().map(|w| w.branch.chars().count()).max().unwrap_or(0);
    for w in &live {
        let alive = if Path::new(&w.path).is_dir() { "" } else { "  (no worktree)" };
        let archived =
            if task_archived(w) { format!("  (task archived: crux workspace rm {})", w.name) } else { String::new() };
        println!("  {:<name_w$}  {:<branch_w$}  slot {}{alive}{archived}", w.name, w.branch, w.slot);
    }
    branches_gone(&live);
    unregistered_worktrees(root, &live);
    if sh::exists("gh") {
        proposals_without_receipt(&live);
    }
    live
}

/// A workspace that outlived its task: archived elsewhere, or by hand, with
/// the folder still there.
fn task_archived(w: &registry::Workspace) -> bool {
    if w.task.is_empty() || w.project.is_empty() {
        return false;
    }
    let dir = crate::env::tasks_dir().join(&w.project);
    !dir.join(format!("{}.md", w.task)).exists() && crate::task::record::archived_copy(&dir, &w.task).is_some()
}

/// A workspace whose branch is no longer on the remote is almost always
/// merged work nobody closed. What git already knows of the remote.
fn branches_gone(live: &[registry::Workspace]) {
    for w in live.iter().filter(|w| Path::new(&w.path).is_dir()) {
        let tracking = git::out(
            Path::new(&w.path),
            &["for-each-ref", "--format=%(upstream:track)", &format!("refs/heads/{}", w.branch)],
        )
        .unwrap_or_default();
        if tracking.contains("gone") {
            ui::warn(format!(
                "'{}': its branch is no longer on the remote, probably merged — close it with 'crux workspace rm {}'",
                w.name, w.name
            ));
        }
    }
}

/// A worktree crux does not know about appears in no list and nothing
/// protects it.
fn unregistered_worktrees(root: &Path, live: &[registry::Workspace]) {
    let registered: Vec<&str> = live.iter().map(|w| w.path.as_str()).collect();
    let mut loose = vec![];
    for a in project::subdirs(root) {
        let first = root.join(&a);
        if a.contains("-ws-") {
            loose.push(first.clone());
        }
        for b in project::subdirs(&first).into_iter().filter(|b| b.contains("-ws-")) {
            loose.push(first.join(b));
        }
    }
    loose.sort();
    for d in loose {
        if registered.contains(&d.to_string_lossy().as_ref()) || !git::is_worktree(&d) {
            continue;
        }
        ui::warn(format!(
            "{} is a worktree crux does not know about — register it: crux workspace adopt {}",
            files::name(&d),
            d.display()
        ));
    }
}

/// A proposal opened from a branch without a receipt is the shortcut taken
/// behind the back: legitimate if a person asked for it, but it has to be
/// visible. One call per repository, all at once.
fn proposals_without_receipt(live: &[registry::Workspace]) {
    let slug_re = crate::regex!(r"^.*github\.com[:/]");
    let mut rows = vec![];
    for w in live.iter().filter(|w| Path::new(&w.path).is_dir()) {
        let Some(origin) = git::remote_url(Path::new(&w.path), "origin") else { continue };
        let slug = slug_re.replace(&origin, "").into_owned();
        let slug = slug.strip_suffix(".git").unwrap_or(&slug).to_string();
        rows.push((w, slug));
    }
    let slugs: BTreeSet<String> = rows.iter().map(|(_, s)| s.clone()).collect();
    let handles: Vec<_> = slugs.into_iter().map(|slug| std::thread::spawn(move || open_proposals(slug))).collect();
    let open: HashMap<String, HashMap<String, String>> = handles.into_iter().filter_map(|h| h.join().ok()).collect();
    for (w, slug) in rows {
        let Some(pr) = open.get(&slug).and_then(|m| m.get(&w.branch)) else { continue };
        let receipt = files::read_or_empty(&Path::new(&w.path).join(names::GATE_RECEIPT));
        let sealed = super::ship::sealed_sha(&receipt).unwrap_or_default();
        if sealed != git::head_sha(Path::new(&w.path)).unwrap_or_default() {
            ui::warn(format!("{slug}#{pr} ({}) is open and its branch has no gate receipt", w.name));
        }
    }
}

/// The open proposals of a repository: branch → number.
fn open_proposals(slug: String) -> (String, HashMap<String, String>) {
    let jq = ".[] | \"\\(.headRefName)\\t\\(.number)\"";
    let args = ["pr", "list", "--repo", &slug, "--state", "open", "--limit", "200", "--json", "number,headRefName"];
    let r = sh::capture("gh", &[&args[..], &["--jq", jq]].concat());
    let map =
        r.stdout.lines().filter_map(|l| l.split_once('\t')).map(|(a, b)| (a.to_string(), b.to_string())).collect();
    (slug, map)
}

/// Open tasks with no workspace on this machine —started on another, or whose
/// workspace was closed before finishing them—, and those waiting on another
/// person: not pending work of ours, but they cannot be lost sight of.
fn tasks_elsewhere(live: &[registry::Workspace]) {
    for f in remind::unreadable_tasks() {
        ui::warn(format!("unreadable task record, left out of this list: {}", f.display()));
    }
    let tasks = remind::open_tasks(None);
    let alive: BTreeSet<&str> = live.iter().filter(|w| Path::new(&w.path).exists()).map(|w| w.name.as_str()).collect();
    let without: Vec<&remind::OpenTask> = tasks
        .iter()
        .filter(|t| t.waiting.is_none() && !t.workspaces.iter().any(|w| alive.contains(w.as_str())))
        .collect();
    if !without.is_empty() {
        println!();
        println!("open tasks with no workspace on this machine");
        println!();
        for t in without {
            println!("  {:<34} {:<12} {}", format!("{}/{}", t.project, t.task), t.status, cut(&t.next, 60));
        }
        ui::info("resume them with: crux workspace resume <task>");
    }
    let waiting: Vec<(&remind::OpenTask, &crate::task::record::Waiting)> =
        tasks.iter().filter_map(|t| t.waiting.as_ref().map(|w| (t, w))).collect();
    if waiting.is_empty() {
        return;
    }
    let nudge: i64 = env::var("CRUX_WAIT_NUDGE_DAYS")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| *n > 0.0)
        .map(|n| n as i64)
        .unwrap_or(7);
    println!();
    println!("waiting for an answer");
    println!();
    for (t, w) in waiting {
        let days = remind::days_since(&w.since);
        let age = match days {
            None => String::new(),
            Some(0) => "today".into(),
            Some(1) => "yesterday".into(),
            Some(d) => format!("{d} days ago"),
        };
        let task = format!("{}/{}", t.project, t.task);
        println!("  {task:<34} to {}, {age}", w.on);
        println!("  {:<34} {}", "", cut(&w.ask, 70));
        if !w.reference.is_empty() {
            println!("  {:<34} {}", "", w.reference);
        }
        if days.is_some_and(|d| d >= nudge) {
            ui::warn(format!("{task} is past its deadline: worth a nudge"));
        }
    }
    ui::info("when the answer arrives: crux workspace resume <task>");
}

fn unpublished_work(root: &Path) {
    println!();
    println!("unpublished work");
    println!();
    let mut pending = 0;
    for p in project::subdirs(root) {
        for r in project::subdirs(&root.join(&p)) {
            let repo = root.join(&p).join(&r);
            if !repo.join(".git").exists() || git::toplevel(&repo).is_none() || git::is_worktree(&repo) {
                continue;
            }
            let branch = git::out(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_else(|| "?".into());
            let dirty = git::out(&repo, &["status", "--porcelain"]).map(|s| s.lines().count()).unwrap_or(0);
            let unpushed = if git::ok(&repo, &["rev-parse", "@{u}"]) {
                git::out(&repo, &["log", "--oneline", "@{u}.."]).map(|s| s.lines().count()).unwrap_or(0)
            } else {
                git::out(&repo, &["log", "--oneline", &format!("{}..{branch}", project::main_branch(&repo))])
                    .map(|s| s.lines().count())
                    .unwrap_or(0)
            };
            if dirty == 0 && unpushed == 0 {
                continue;
            }
            pending += 1;
            let mut detail = vec![];
            if unpushed > 0 {
                detail.push(format!("{} not pushed", ui::count(unpushed, "commit", "commits")));
            }
            if dirty > 0 {
                detail.push(ui::count(dirty, "file touched", "files touched"));
            }
            println!("  {:<34} {branch:<22} {}", format!("{p}/{r}"), detail.join(", "));
        }
    }
    if pending == 0 {
        println!("  nothing: everything is pushed");
    }
}
