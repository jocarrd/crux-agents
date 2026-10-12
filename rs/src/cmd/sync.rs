//! crux sync — work on two machines without either falling behind.
//!
//!   crux sync            on arrival: what is on this machine, up to date, and the kernel
//!   crux sync --leave    on leaving: fails if something would stay only on this machine
//!   crux sync --hook     the same as on arrival, silent except for news;
//!                        it is what the session-start hook runs
//!
//! On arrival it only advances what can be advanced without deciding
//! anything: a clean branch behind its remote. Uncommitted changes or diverged
//! branches are reported and left alone. It never merges or rewrites.
//!
//! What it does NOT sync, on purpose: credentials (see `carry-env`) and the
//! agent's local memory, which is a draft.

use crate::error::{exit, Res};
use crate::names;
use crate::task::sync as tsync;
use crate::{die, env, files, git, person, project, sh, ui};
use serde_json::Value;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// Runs `f` over the items with up to `n` threads, results in input order.
fn parallel<T: Sync, R: Send>(items: &[T], n: usize, f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = std::sync::atomic::AtomicUsize::new(0);
    let results: std::sync::Mutex<Vec<Option<R>>> = std::sync::Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..n.min(items.len().max(1)) {
            s.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if i >= items.len() {
                    break;
                }
                let r = f(&items[i]);
                results.lock().unwrap()[i] = Some(r);
            });
        }
    });
    results.into_inner().unwrap().into_iter().map(|r| r.unwrap()).collect()
}

struct Ctx {
    root: PathBuf,
    mode: &'static str,
}

impl Ctx {
    fn name_of(&self, p: &Path) -> String {
        p.strip_prefix(&self.root)
            .map(|r| r.to_string_lossy().into_owned())
            .unwrap_or_else(|_| p.to_string_lossy().into_owned())
    }
    /// The repos in the root and those inside each project, and separately the
    /// worktrees, which share their main repo's fetch.
    fn repos(&self) -> (Vec<PathBuf>, Vec<PathBuf>) {
        let mut candidates = vec![];
        for a in project::subdirs(&self.root) {
            candidates.push(self.root.join(&a));
        }
        for a in project::subdirs(&self.root) {
            for b in project::subdirs(&self.root.join(&a)) {
                candidates.push(self.root.join(&a).join(b));
            }
        }
        let (mut main, mut worktrees) = (vec![], vec![]);
        for d in candidates.into_iter().filter(|d| d.join(".git").exists()) {
            if git::is_worktree(&d) {
                worktrees.push(d);
            } else {
                main.push(d);
            }
        }
        (main, worktrees)
    }
}

fn tracking_remote(repo: &Path) -> String {
    let branch = git::out(repo, &["symbolic-ref", "-q", "--short", "HEAD"]).unwrap_or_default();
    if let Some(r) = git::out(repo, &["config", &format!("branch.{branch}.remote")]).filter(|r| !r.is_empty()) {
        return r;
    }
    let remotes = git::out(repo, &["remote"]).unwrap_or_default();
    if remotes.lines().any(|r| r == "origin") {
        return "origin".into();
    }
    remotes.lines().next().unwrap_or("").to_string()
}

fn timed_git(repo: &Path, args: &[&str], seconds: u64) -> sh::Run {
    let mut c = git::cmd(repo);
    c.args(args).env("LC_ALL", "C");
    sh::with_timeout(&mut c, seconds)
}

/// "x" if the remote no longer exists, "?" if it could not be known: without
/// a network nothing is claimed to be missing.
fn missing_remotes(repos: &[PathBuf]) -> Vec<(char, PathBuf)> {
    let with_remote: Vec<PathBuf> =
        repos.iter().filter(|r| !git::out(r, &["remote"]).unwrap_or_default().is_empty()).cloned().collect();
    let gone =
        crate::regex!(r"(?i)repository not found|does not appear to be a git repository|repository .* does not exist");
    parallel(&with_remote, 16, |repo| {
        let r = timed_git(repo, &["ls-remote", "-q", &tracking_remote(repo)], 20);
        if r.ok() {
            None
        } else if gone.is_match(&format!("{}{}", r.stdout, r.stderr)) {
            Some(('x', repo.clone()))
        } else {
            Some(('?', repo.clone()))
        }
    })
    .into_iter()
    .flatten()
    .collect()
}

fn departure(ctx: &Ctx) -> Res {
    let mut stuck = 0;
    let mut warnings = 0;
    println!("what would stay only on this machine");
    println!();
    let (main, worktrees) = ctx.repos();
    for repo in main.iter().chain(worktrees.iter()) {
        let name = ctx.name_of(repo);
        if git::out(repo, &["remote"]).unwrap_or_default().is_empty() {
            ui::warn(format!("{name}: no remote, everything it has lives only here"));
            stuck += 1;
            continue;
        }
        let dirty = git::out(repo, &["status", "--porcelain"]).map(|s| s.lines().count()).unwrap_or(0);
        if dirty > 0 {
            ui::err(format!("{name}: {}", ui::count(dirty, "uncommitted file", "uncommitted files")));
            stuck += 1;
        }
        // A commit made with a detached HEAD is in no branch, so the branch
        // review below does not see it.
        if !git::ok(repo, &["symbolic-ref", "-q", "HEAD"])
            && git::ok(repo, &["rev-parse", "-q", "--verify", "HEAD"])
            && git::out(repo, &["for-each-ref", "--contains", "HEAD", "refs/heads", "refs/remotes"])
                .unwrap_or_default()
                .is_empty()
        {
            ui::err(format!(
                "{name}: detached HEAD with commits that are in no branch — create one: git switch -c <branch>"
            ));
            stuck += 1;
        }
        // Branches from the main repo only: worktrees share them.
        if git::is_worktree(repo) {
            continue;
        }
        for line in git::out(repo, &["for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads"])
            .unwrap_or_default()
            .lines()
        {
            let (b, up) = line.split_once('\t').unwrap_or((line, ""));
            if up.is_empty() {
                // Untracked: only safe if some remote already contains it.
                if git::out(repo, &["branch", "-r", "--contains", b]).unwrap_or_default().is_empty() {
                    ui::err(format!("{name}: branch {b} is in no remote"));
                    stuck += 1;
                }
            } else if !git::ok(repo, &["rev-parse", "-q", "--verify", up]) {
                // It tracked a branch that no longer exists: almost always a
                // proposal merged with squash.
                warnings += 1;
            } else {
                let ahead: usize = git::out(repo, &["rev-list", "--count", &format!("{up}..{b}")])
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0);
                if ahead > 0 {
                    ui::err(format!("{name}: {b} has {} not pushed", ui::count(ahead, "commit", "commits")));
                    stuck += 1;
                }
            }
        }
        let stash = git::out(repo, &["stash", "list"]).map(|s| s.lines().count()).unwrap_or(0);
        if stash > 0 {
            ui::warn(format!(
                "{name}: {} — they do not travel; turn them into a branch if you want them there",
                ui::count(stash, "stash", "stashes")
            ));
        }
    }
    // With the remote deleted, the local references still say everything is
    // pushed: git does not find out until it asks.
    let missing = missing_remotes(&main);
    for (_, r) in missing.iter().filter(|(k, _)| *k == 'x') {
        ui::err(format!("{}: its remote no longer exists — what it has lives only here", ctx.name_of(r)));
        stuck += 1;
    }
    let unchecked: Vec<&PathBuf> = missing.iter().filter(|(k, _)| *k == '?').map(|(_, r)| r).collect();
    if !unchecked.is_empty() {
        ui::warn("could not check whether the remotes still exist for:");
        for r in unchecked {
            ui::info(ctx.name_of(r));
        }
    }
    // Tasks publish themselves when written, but a write without a network
    // stays pending: retried here.
    let projects = tsync::projects_with_tasks();
    let results = parallel(&projects, 8, |p| tsync::sync_project(p, false).ok());
    for r in results.into_iter().flatten() {
        let p = r.get("project").and_then(Value::as_str).unwrap_or("");
        match r.get("status").and_then(Value::as_str).unwrap_or("") {
            "no-transport" => ui::warn(format!("{p}: their tasks have no docs repo to travel through: they stay on this machine")),
            "no-remote" => ui::warn(format!("{p}: its docs repo has no remote: the tasks stay on this machine")),
            "public" => ui::warn(format!("{p}: its repo is public: tasks are not published there and stay on this machine (\"tasks\": {{\"sync\": true}} in crux.json to force it)")),
            _ => {}
        }
    }
    for p in tsync::pending_projects() {
        ui::err(format!("{p}: unpublished tasks — the other machine will not see them"));
        stuck += 1;
    }
    // What the agent learned about the person, still only in its local memory.
    let cwd = std::env::current_dir().unwrap_or_default();
    if person::dir().is_some() && !super::call_quiet(&cwd, "memory", &["--check"]).ok() {
        let brief = super::call_quiet(&cwd, "memory", &["--brief"]);
        let first = format!("{}{}", brief.stdout, brief.stderr).lines().next().unwrap_or("").to_string();
        let msg = first.split_once(' ').map(|(_, r)| r.trim_start().to_string()).unwrap_or_default();
        ui::err(format!(
            "agent memory: {} — 'crux memory'",
            if msg.is_empty() { "there are memories that should be in git".into() } else { msg }
        ));
        stuck += 1;
    }
    println!();
    if warnings > 0 {
        ui::info(format!(
            "{} a branch deleted from the remote (merged, almost surely): they do not block",
            ui::count(warnings, "branch tracks", "branches track")
        ));
    }
    if stuck == 0 {
        ui::ok("nothing trapped: you can carry on on the other machine");
        return Ok(());
    }
    ui::err(format!("{} would not reach the other machine", ui::count(stuck, "thing", "things")));
    ui::info("push them, or consciously decide they stay here");
    exit(1)
}

/// Every remote in parallel: in series, with dozens of repos, the
/// session-start hook is slow enough to notice. Returns the repos that did not
/// answer.
fn fetch_all(repos: &[PathBuf]) -> Vec<PathBuf> {
    parallel(repos, 16, |repo| {
        if timed_git(repo, &["fetch", "-q", "--all", "--prune", "--tags"], 30).ok() {
            return None;
        }
        // With --all, one failing secondary remote is enough to fail everything.
        let remote = tracking_remote(repo);
        if !remote.is_empty() && timed_git(repo, &["fetch", "-q", "--prune", "--tags", &remote], 30).ok() {
            return None;
        }
        Some(repo.clone())
    })
    .into_iter()
    .flatten()
    .collect()
}

/// True if every uncommitted change is inside the block crux link generates:
/// an older kernel leaves it rewritten, and the remote brings it regenerated.
fn only_generated_changes(repo: &Path) -> bool {
    let block = crate::regex!(r"<!-- crux:begin[\s\S]*?crux:end -->");
    let changed = git::out(repo, &["diff", "--name-only", "HEAD"]).unwrap_or_default();
    for f in changed.lines() {
        if f != names::AGENTS && f != names::CLAUDE {
            return false;
        }
        let now = files::read_or_empty(&repo.join(f));
        if !block.is_match(&now) {
            return false;
        }
        let head = git::out(repo, &["show", &format!("HEAD:{f}")]).unwrap_or_default();
        let strip = |t: &str| block.replacen(t, 1, "").into_owned();
        if strip(&(head + "\n")).trim_end() != strip(&now).trim_end() {
            return false;
        }
    }
    true
}

/// Advances the current branch if it is behind and there is nothing to decide.
fn advance(ctx: &Ctx, repo: &Path) -> Option<String> {
    let name = ctx.name_of(repo);
    let up = git::out(repo, &["rev-parse", "--abbrev-ref", "@{u}"])?;
    if !git::ok(repo, &["rev-parse", "-q", "--verify", &up]) {
        return None;
    }
    let count = |range: String| {
        git::out(repo, &["rev-list", "--count", &range]).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0)
    };
    let behind = count(format!("HEAD..{up}"));
    if behind == 0 {
        return None;
    }
    let ahead = count(format!("{up}..HEAD"));
    let dirty = || !git::out(repo, &["status", "--porcelain", "--untracked-files=no"]).unwrap_or_default().is_empty();
    let mut restored = "";
    if ahead == 0 && dirty() && only_generated_changes(repo) {
        let changed: Vec<String> =
            git::out(repo, &["diff", "--name-only", "HEAD"]).unwrap_or_default().lines().map(String::from).collect();
        let mut args = vec!["checkout", "-q", "HEAD", "--"];
        args.extend(changed.iter().map(String::as_str));
        if git::ok(repo, &args) {
            restored = " (the crux block of the pointers was discarded: it comes regenerated)";
        }
    }
    if ahead > 0 {
        return Some(format!("diverged\t{name}: the local branch and {up} have diverged ({ahead} here, {behind} there) — you decide how to join them"));
    }
    if dirty() {
        return Some(format!(
            "dirty\t{name}: is {} behind, but has uncommitted changes — I leave it alone",
            ui::count(behind, "commit", "commits")
        ));
    }
    // In C: the message is compared, and git translates it.
    let r = sh::capture_cmd(git::cmd(repo).args(["merge", "-q", "--ff-only", &up]).env("LC_ALL", "C"));
    let output = format!("{}{}", r.stdout, r.stderr);
    if r.ok() {
        return Some(format!("ok\t{name}: {}{restored}", ui::count(behind, "new commit", "new commits")));
    }
    if output.contains("untracked working tree files would be overwritten") {
        let files: Vec<&str> = output
            .lines()
            .filter(|l| l.starts_with(|c: char| c.is_whitespace()))
            .map(str::trim_start)
            .take(3)
            .collect();
        return Some(format!(
            "dirty\t{name}: an untracked file here clashes with one that is arriving — move it and retry: {} ",
            files.join(" ")
        ));
    }
    Some(format!("failed\t{name}: could not advance to {up} — {}", output.lines().next().unwrap_or("")))
}

/// The other local branches behind their remote: without this, on switching
/// to main on the other machine work started on the old state. `fetch .` does
/// not advance a branch in use in a worktree nor one that diverged.
fn advance_the_rest(ctx: &Ctx, repo: &Path) -> Vec<String> {
    let name = ctx.name_of(repo);
    let current = git::out(repo, &["symbolic-ref", "-q", "HEAD"]).unwrap_or_default();
    let mut out = vec![];
    for line in
        git::out(repo, &["for-each-ref", "--format=%(refname)\t%(upstream)", "refs/heads"]).unwrap_or_default().lines()
    {
        let (b, up) = line.split_once('\t').unwrap_or((line, ""));
        if up.is_empty() || b == current || !git::ok(repo, &["rev-parse", "-q", "--verify", up]) {
            continue;
        }
        let count = |range: String, d: usize| {
            git::out(repo, &["rev-list", "--count", &range]).and_then(|s| s.parse::<usize>().ok()).unwrap_or(d)
        };
        let behind = count(format!("{b}..{up}"), 0);
        if behind == 0 || count(format!("{up}..{b}"), 1) != 0 {
            continue;
        }
        if git::ok(repo, &["fetch", "-q", ".", &format!("{up}:{b}")]) {
            out.push(format!(
                "ok\t{name}: {}, {}",
                b.trim_start_matches("refs/heads/"),
                ui::count(behind, "new commit", "new commits")
            ));
        }
    }
    out
}

fn docs_repos(root: &Path) -> Vec<(String, PathBuf)> {
    let mut out = vec![];
    for p in project::subdirs(root) {
        for d in project::subdirs(&root.join(&p)).into_iter().filter(|d| d.ends_with("-docs")) {
            let docs = root.join(&p).join(d);
            if docs.join(names::CONTRACT).is_file() {
                out.push((p.clone(), docs));
            }
        }
    }
    out
}

/// Repos a project's contract declares and that are not on disk: added from
/// the other machine.
fn fetch_new_repos(ctx: &Ctx) -> Vec<String> {
    let mut out = vec![];
    for (p, docs) in docs_repos(&ctx.root) {
        let contract = match project::read_contract(&docs) {
            Ok(c) => c,
            Err(e) => {
                out.push(format!("failed\t{p}: crux.json unreadable, I do not know which repos it declares — {e}"));
                continue;
            }
        };
        let missing = || -> Vec<String> {
            files::str_list(contract.get("repos"))
                .into_iter()
                .filter(|r| project::valid_name(r) && !ctx.root.join(&p).join(r).join(".git").exists())
                .collect()
        };
        let before = missing();
        if before.is_empty() {
            continue;
        }
        let cloned = super::call_quiet(&ctx.root, "clone", &[&p, "--parent", &ctx.root.to_string_lossy()]).ok();
        // clone warns and carries on when a repo cannot be fetched, as in a
        // client's repo: what is still missing is what says how it went.
        let after = missing();
        let brought: Vec<&String> = before.iter().filter(|r| !after.contains(r)).collect();
        if !brought.is_empty() {
            out.push(format!(
                "new\t{p}: brought in {}",
                brought.iter().map(|r| r.as_str()).collect::<Vec<_>>().join(", ")
            ));
        }
        if !after.is_empty() {
            let why = if cloned { "" } else { ", and clone failed" };
            out.push(format!("warning\t{p}: still missing {}{why} — 'crux clone {p}' says why", after.join(", ")));
        }
    }
    out
}

/// A repo moved to another owner keeps answering at its old URL through the
/// provider's redirect; what breaks is opening a proposal.
fn moved_remotes(ctx: &Ctx) -> Vec<String> {
    let mut out = vec![];
    for (p, docs) in docs_repos(&ctx.root) {
        let Ok(contract) = project::read_contract(&docs) else { continue };
        for repo in files::str_list(contract.get("repos")).into_iter().filter(|r| project::valid_name(r)) {
            let dir = ctx.root.join(&p).join(&repo);
            if !dir.join(".git").exists() {
                continue;
            }
            let (Some(real), Some(declared)) = (git::remote_url(&dir, "origin"), project::remote_url(&contract, &repo))
            else {
                continue;
            };
            if project::normalize_git_url(&real) != project::normalize_git_url(&declared) {
                out.push(format!("warning\t{p}/{repo}: origin is {real} and crux.json declares {declared} — git -C {} remote set-url origin {declared}", dir.display()));
            }
        }
    }
    out
}

/// The kernel is updated from its clone, and only to a published version: the
/// main branch's VERSION may be ahead of the latest tag.
fn kernel_up_to_date(ctx: &Ctx) -> Option<String> {
    let clone = env::kernel_clone(&ctx.root)?;
    let new = files::read_or_empty(&clone.join(names::VERSION)).split_whitespace().collect::<String>();
    let current = env::crux_version();
    if !project::is_semver(&new)
        || !project::version_greater_than(&new, &current)
        || !git::ok(&clone, &["rev-parse", "-q", "--verify", &format!("refs/tags/v{new}")])
    {
        return None;
    }
    if env::var("CRUX_SYNC_NO_INSTALL").as_deref() == Some("1") {
        return Some(format!("kernel\tcrux {new} available (installation disabled)"));
    }
    // In dev mode the kernel already is the clone.
    if env::config_value_in(&env::config_file_redirectable(), "CRUX_MODE").is_some_and(|m| m.starts_with("dev")) {
        return None;
    }
    // This process has its own CRUX_HOME; inherited, the new hooks would
    // point at the old kernel.
    let home = env::home();
    let installed =
        sh::capture_cmd(Command::new("bash").arg(clone.join("install.sh")).current_dir(&home).env_remove("CRUX_HOME"))
            .ok();
    let kernel = home.join(format!(".crux/kernel/{new}"));
    let hooked = installed
        && sh::capture_cmd(
            Command::new(kernel.join("bin/crux"))
                .args(["hooks", "install"])
                .current_dir(&home)
                .env("CRUX_HOME", &kernel),
        )
        .ok();
    Some(if hooked {
        format!("kernel\tcrux {current} → {new}, with its hooks")
    } else {
        format!("failed\tkernel: could not install crux {new} — run '{}/install.sh' by hand", clone.display())
    })
}

/// Tasks from the other machine are pulled and what stayed pending here is
/// published.
fn tasks_up_to_date() -> Vec<String> {
    let mut out = vec![];
    for p in tsync::projects_with_tasks() {
        let mut s = match tsync::sync_project(&p, true) {
            Ok(s) => s,
            Err(e) => {
                out.push(format!("failed\t{p}: tasks — {}", e.lines().next().unwrap_or("")));
                continue;
            }
        };
        if s.get("status").and_then(Value::as_str) == Some("ok") {
            let closed = tsync::reconcile(&p);
            if !closed.is_empty() {
                let pulled = s.get("pulled").cloned();
                let warnings = s.get("warnings").cloned();
                if let Ok(again) = tsync::sync_project(&p, true) {
                    s = again;
                    if let Some(v) = pulled {
                        s.insert("pulled".into(), v);
                    }
                    let mut w: Vec<Value> = warnings.and_then(|v| v.as_array().cloned()).unwrap_or_default();
                    w.extend(s.get("warnings").and_then(Value::as_array).cloned().unwrap_or_default());
                    s.insert("warnings".into(), Value::Array(w));
                }
                for c in closed {
                    out.push(format!("tasks\t{c}"));
                }
            }
        }
        for w in s.get("warnings").and_then(Value::as_array).cloned().unwrap_or_default() {
            out.push(format!("warning\t{}", files::value_text(&w)));
        }
        match s.get("status").and_then(Value::as_str).unwrap_or("") {
            "ok" => {
                let n = s.get("pulled").and_then(Value::as_u64).unwrap_or(0) as usize;
                if n > 0 {
                    out.push(format!("tasks\t{p}: {}", ui::count(n, "task pulled", "tasks pulled")));
                }
            }
            "rejected" => out.push(format!("warning\t{p}: the tasks could not be published, retrying next time")),
            _ => {}
        }
    }
    out
}

/// The profile is reloaded into the agents after advancing it: Codex keeps a
/// copy of its index that goes stale.
fn profile_up_to_date(ctx: &Ctx) -> Option<String> {
    let cwd = std::env::current_dir().unwrap_or_default();
    if person::dir().is_some() {
        if !super::call_quiet(&cwd, "profile", &["link"]).ok() {
            return Some("failed\tprofile: could not load it into the agents — 'crux profile link'".into());
        }
        return None;
    }
    // Gone since the last time: the agents stop importing it.
    if files::read_or_empty(&env::claude_config_dir().join(names::CLAUDE)).contains("crux:profile:begin") {
        super::call_quiet(&cwd, "profile", &["link"]);
    }
    if ctx.mode == "hook" || !sh::exists("gh") {
        return None;
    }
    let owner = project::default_owner();
    let name = person::repo_name();
    (!owner.is_empty() && sh::capture("gh", &["repo", "view", &format!("{owner}/{name}")]).ok())
        .then(|| format!("warning\tthe profile {owner}/{name} is not on this machine — 'crux profile clone'"))
}

/// Projects on the remote this machine does not have. Only by hand: it asks
/// the remote once per candidate.
fn missing_projects(ctx: &Ctx) -> Vec<String> {
    if ctx.mode != "arrive" || !sh::exists("gh") || !sh::capture("gh", &["auth", "status"]).ok() {
        return vec![];
    }
    let mut out = vec![];
    let mut seen = vec![];
    for o in project::search_owners() {
        for p in project::candidate_projects(&o) {
            if seen.contains(&p) || !project::has_contract(&o, &p) {
                continue;
            }
            seen.push(p.clone());
            if !ctx.root.join(&p).join(format!("{p}-docs")).is_dir() {
                out.push(format!(
                    "notice\t{p} is on the remote ({o}) and not on this machine — 'crux clone {p}' if you need it"
                ));
            }
        }
    }
    out
}

/// A workspace whose task was archived looks like work in progress.
fn closed_workspaces(ctx: &Ctx, worktrees: &[PathBuf]) -> Vec<String> {
    if ctx.mode != "arrive" {
        return vec![];
    }
    let dir = env::tasks_dir();
    let mut out = vec![];
    for wt in worktrees {
        let base = files::name(wt);
        let Some((_, task)) = base.split_once("-ws-") else { continue };
        let task = base.rsplit("-ws-").next().unwrap_or(task).to_string();
        let project = crate::task::project_name_for(wt);
        if dir.join(&project).join(format!("{task}.md")).is_file() {
            continue;
        }
        let archived = std::fs::read_dir(dir.join(&project).join("done"))
            .map(|e| e.flatten().any(|x| x.file_name().to_string_lossy().ends_with(&format!("-{task}.md"))))
            .unwrap_or(false);
        if archived {
            out.push(format!(
                "notice\t{}: its task is archived — 'crux workspace rm {task}' once nothing in it is pending",
                ctx.name_of(wt)
            ));
        }
    }
    out
}

/// A task edited on both machines keeps the most recent version and saves the
/// other alongside, decided in a background publish nobody reads.
fn task_conflicts(ctx: &Ctx) -> Vec<String> {
    if ctx.mode != "arrive" {
        return vec![];
    }
    let dir = env::tasks_dir();
    let mut found = vec![];
    for p in project::subdirs(&dir) {
        for e in std::fs::read_dir(dir.join(&p)).map(|e| e.flatten().collect::<Vec<_>>()).unwrap_or_default() {
            let n = e.file_name().to_string_lossy().into_owned();
            if crate::task::sync::is_conflict_copy(&n) {
                found.push(format!("{p}/{n}"));
            }
        }
    }
    found.sort();
    found.into_iter().map(|f| format!("notice\ttask changed on both machines: {f} holds the version that lost — merge what is missing and delete it")).collect()
}

/// A project materialized with an old kernel misses what was released since.
/// Only when the minor differs: patches do not change what is materialized.
fn behind_projects(ctx: &Ctx) -> Vec<String> {
    if ctx.mode != "arrive" {
        return vec![];
    }
    let current = env::crux_version();
    let series = |v: &str| v.rsplit_once('.').map(|(a, _)| a.to_string()).unwrap_or_default();
    let mut out = vec![];
    for (p, docs) in docs_repos(&ctx.root) {
        let Some(pinned) = project::contract_field(&docs, "crux") else { continue };
        if !project::is_semver(&pinned)
            || series(&pinned) == series(&current)
            || !project::version_greater_than(&current, &pinned)
        {
            continue;
        }
        out.push(format!(
            "notice\t{p} is materialized with crux {pinned} and the kernel is {current} — 'crux upgrade' in {}",
            files::name(&docs)
        ));
    }
    out
}

fn arrival(ctx: &Ctx) -> Res {
    let (main, worktrees) = ctx.repos();
    let offline = fetch_all(&main);
    let mut lines: Vec<String> = vec![];
    for repo in &main {
        lines.extend(advance(ctx, repo));
        lines.extend(advance_the_rest(ctx, repo));
    }
    // A task resumed on the other machine moves its branch on there.
    for repo in &worktrees {
        lines.extend(advance(ctx, repo));
    }
    lines.extend(fetch_new_repos(ctx));
    lines.extend(moved_remotes(ctx));
    lines.extend(kernel_up_to_date(ctx));
    lines.extend(tasks_up_to_date());
    lines.extend(profile_up_to_date(ctx));
    lines.extend(missing_projects(ctx));
    lines.extend(closed_workspaces(ctx, &worktrees));
    lines.extend(task_conflicts(ctx));
    lines.extend(behind_projects(ctx));
    lines.retain(|l| !l.is_empty());

    if ctx.mode == "hook" {
        // In the hook, what is printed enters the agent's context: only what
        // changed or asks for a decision. A repo whose remote was deleted
        // never answers: here only none answering counts, which is offline.
        let all_offline = !offline.is_empty() && offline.len() == main.len();
        if lines.is_empty() && !all_offline {
            return Ok(());
        }
        println!("crux sync, at session start:");
        for l in &lines {
            println!("  {}", l.split_once('\t').map(|(_, t)| t).unwrap_or(l));
        }
        if all_offline {
            println!("  offline: no remote answered, the repos may not be up to date");
        }
        return Ok(());
    }
    println!("up to date with the remote — {}", ctx.root.display());
    println!();
    if lines.is_empty() {
        ui::ok("nothing new: this machine was already up to date");
    }
    for l in &lines {
        let (kind, text) = l.split_once('\t').unwrap_or(("", l));
        match kind {
            "ok" | "new" | "kernel" | "tasks" => ui::ok(text),
            "diverged" | "dirty" | "warning" => ui::warn(text),
            "notice" => ui::info(text),
            _ => ui::err(text),
        }
    }
    if !offline.is_empty() {
        println!();
        ui::warn("no answer from the remote (offline, or the remote no longer exists):");
        for r in &offline {
            ui::info(ctx.name_of(r));
        }
    }
    // Diverged and dirty ask for a decision: a script chaining this does not
    // carry on as if everything were up to date.
    if lines.iter().any(|l| ["diverged\t", "dirty\t", "failed\t", "warning\t"].iter().any(|k| l.starts_with(k))) {
        return exit(1);
    }
    Ok(())
}

struct SyncLock(PathBuf);

impl Drop for SyncLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir(&self.0);
    }
}

/// Two arrivals at once —a session's hook and a manual sync— trampled git's
/// index. mkdir is atomic and exists everywhere.
fn take_lock(state: &Path, hook: bool) -> Option<SyncLock> {
    let lock = state.join("sync.lock");
    let mut waited = false;
    loop {
        if std::fs::create_dir(&lock).is_ok() {
            return Some(SyncLock(lock));
        }
        // A lock older than ten minutes belongs to a process that died.
        let old = std::fs::metadata(&lock)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|e| e > Duration::from_secs(600));
        if old {
            let _ = std::fs::remove_dir(&lock);
            continue;
        }
        if hook {
            return None;
        }
        if !waited {
            ui::info("another sync is running, waiting for it to finish");
            waited = true;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

pub fn run(argv: &[String]) -> Res {
    let mode = match argv.first().map(String::as_str) {
        None | Some("") => "arrive",
        Some("--leave") => "leave",
        Some("--hook") => "hook",
        _ => die!("usage: crux sync [--leave|--hook]"),
    };
    let root = env::projects_root();
    if !root.is_dir() {
        die!("the projects root does not exist: {}", root.display());
    }
    // On a freshly set-up machine ssh asks for each host's fingerprint and git
    // for a password: with no terminal, each repo waited until the timeout.
    std::env::set_var("GIT_TERMINAL_PROMPT", "0");
    std::env::set_var(
        "GIT_SSH_COMMAND",
        format!("{} -o BatchMode=yes", env::var("GIT_SSH_COMMAND").unwrap_or_else(|| "ssh".into())),
    );
    let ctx = Ctx { root, mode };
    let state = env::state_dir();
    let _ = files::mkdir_private(&state);
    match mode {
        "hook" => {
            // By hand and in a terminal, reading stdin would wait for a Ctrl-D.
            if !std::io::stdin().is_terminal() {
                let _ = std::io::Read::read_to_end(&mut std::io::stdin(), &mut vec![]);
            }
            // Several sessions opened at once would launch the same round: with
            // a marker, the first one syncs and the rest do not.
            let marker = state.join("sync-last");
            let every: u64 = env::var("CRUX_SYNC_EVERY_MIN").and_then(|v| v.parse().ok()).unwrap_or(10);
            let fresh = std::fs::metadata(&marker)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|e| e < Duration::from_secs(every * 60));
            if fresh {
                return Ok(());
            }
            let Some(_lock) = take_lock(&state, true) else { return Ok(()) };
            crate::files::touch_marker(&marker, "");
            let _ = arrival(&ctx);
            Ok(())
        }
        "leave" => departure(&ctx),
        _ => {
            let _lock = take_lock(&state, false);
            arrival(&ctx)
        }
    }
}
