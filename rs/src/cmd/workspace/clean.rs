//! Closing and cleaning: removing a workspace, repairing the registry,
//! reconciling it with the disk and deleting merged branches.

use super::{archive_if_finished, clean_workspace, find, ignored_files, load_config, lock, Slot};
use crate::error::{exit, Res};
use crate::{die, env, files, git, project, registry, sh, ui};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Hooks are tested before a release by installing them from a kernel
/// workspace. On closing it they would point to a deleted folder and fail on
/// every message: they are reinstalled from the main checkout, and those that
/// only existed in the workspace are removed.
fn repoint_hooks(workspace: &Path, main_repo: &Path, settings: &Path) {
    let reinstalled = main_repo.join("bin/crux").is_file()
        && main_repo.join("adapters").is_dir()
        && sh::capture_cmd(
            Command::new(main_repo.join("bin/crux"))
                .args(["hooks", "install"])
                .current_dir(main_repo)
                .env("CRUX_HOME", main_repo)
                .env("CLAUDE_SETTINGS", settings),
        )
        .ok();
    if !reinstalled {
        ui::warn("the agent hooks point to this workspace: they will break when it is deleted");
        ui::info("reinstall them from the main repo: crux hooks install");
        return;
    }
    let prefix = format!("{}/", workspace.display());
    let mut s = files::read_json(settings).unwrap_or(Value::Null);
    let mut removed = 0;
    if let Some(hooks) = s.get_mut("hooks").and_then(Value::as_object_mut) {
        for groups in hooks.values_mut() {
            if let Some(list) = groups.as_array_mut() {
                for g in list.iter_mut() {
                    if let Some(h) = g.get_mut("hooks").and_then(Value::as_array_mut) {
                        let before = h.len();
                        h.retain(|x| !x.get("command").and_then(Value::as_str).unwrap_or("").contains(&prefix));
                        removed += before - h.len();
                    }
                }
                list.retain(|g| g.get("hooks").and_then(Value::as_array).is_some_and(|h| !h.is_empty()));
            }
        }
    }
    let _ = std::fs::write(settings, files::json_pretty(&s));
    ui::ok(format!("agent hooks returned to the main checkout: {}", main_repo.display()));
    if removed > 0 {
        ui::info(format!("removed {removed} that only existed in the workspace"));
    }
}

pub fn rm(argv: &[String]) -> Res {
    let Some(name) = argv.first().filter(|n| !n.is_empty()).cloned() else {
        die!("usage: crux workspace rm <name> [--include-ignored]")
    };
    let mut include_ignored = false;
    for a in &argv[1..] {
        match a.as_str() {
            "--include-ignored" => include_ignored = true,
            "--con-ignorados" => die!("--con-ignorados is now called --include-ignored"),
            other => die!("unknown option: {other}"),
        }
    }
    let w = {
        let _guard = lock()?;
        find(&name)?
    };
    let (path, repo) = (PathBuf::from(&w.path), PathBuf::from(&w.repo));
    if path.is_dir() {
        if !git::out(&path, &["status", "--porcelain"]).unwrap_or_default().is_empty() {
            die!("{} has uncommitted changes — resolve them before deleting it", path.display());
        }
        // Hooks installed from inside a workspace point at it, and on closing
        // it they cease to exist with nothing saying so.
        let settings =
            env::var("CLAUDE_SETTINGS").map(PathBuf::from).unwrap_or_else(|| env::home().join(".claude/settings.json"));
        if files::read_or_empty(&settings).contains(&format!("{}/", path.display())) {
            repoint_hooks(&path, &repo, &settings);
        }
        let repo_name = repo.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let config = load_config(project::find_docs_repo(&repo).as_deref(), &repo_name)?;
        // ENV_FILE is written by crux itself, so it is not work that is lost.
        let ignored = ignored_files(&path, &config.env_file);
        if !include_ignored && !ignored.is_empty() {
            ui::err(format!("{} has ignored files that would be lost on removal", path.display()));
            for f in ignored.iter().take(10) {
                println!("      {f}");
            }
            ui::info(format!(
                "take them out of there, or remove it anyway: crux workspace rm {name} --include-ignored"
            ));
            return exit(1);
        }
        if !config.teardown.is_empty() {
            let slot = Slot { number: w.slot, first_port: w.ports.0, name: &name, branch: &w.branch };
            let cmd = slot.fill(&config.teardown);
            if sh::status(Command::new("bash").args(["-c", &cmd]).current_dir(&path)) == 0 {
                ui::ok("teardown executed");
            } else {
                ui::warn(format!("the teardown failed — check whether resources of slot {} were left behind", w.slot));
            }
        }
        let p = path.to_string_lossy();
        if git::ok(&repo, &["worktree", "remove", &p]) || git::ok(&repo, &["worktree", "remove", "--force", &p]) {
            ui::ok("worktree removed");
        } else {
            // git stops recognising it if someone deleted its record some
            // other way; the directory still occupies the slot.
            let _ = std::fs::remove_dir_all(&path);
            git::run(&repo, &["worktree", "prune"]);
            ui::ok("directory removed (git no longer had it as a worktree)");
        }
    }
    let removed = {
        let _guard = lock()?;
        registry::update(|l| l.retain(|x| x.name != name))
    };
    if removed.is_err() {
        ui::err("the worktree is gone, but its entry is still in the registry");
        ui::info("the slot and ports stay reserved until it is removed");
        ui::info(format!("check the permissions of {} and retry: crux workspace heal", registry::path().display()));
        return exit(1);
    }
    ui::ok("slot released");
    if !w.task.is_empty() && !w.project.is_empty() {
        archive_if_finished(&w.project, &w.task);
    }
    // Only if merged: a branch with work that is nowhere else is not deleted
    // because of a preference. Here crux created the branch for this
    // workspace, so `--merged` does say its commits are in the main branch.
    let main = project::main_branch(&repo);
    let merged = git::out(&repo, &["branch", "--merged", &main])
        .unwrap_or_default()
        .lines()
        .any(|l| l.trim_start_matches(['*', '+', ' ']).trim() == w.branch);
    let has_commits =
        !git::out(&repo, &["log", "--oneline", &format!("{main}..{}", w.branch)]).unwrap_or_default().is_empty()
            || !git::out(&repo, &["log", "--oneline", "-1", &w.branch]).unwrap_or_default().is_empty();
    if env::preference_flag("CRUX_RM_DELETE_BRANCH", false) && merged && has_commits {
        if git::ok(&repo, &["branch", "-D", &w.branch]) {
            ui::ok(format!("branch {} deleted (CRUX_RM_DELETE_BRANCH)", w.branch));
        } else {
            ui::info(format!("the branch {} still exists", w.branch));
        }
    } else {
        ui::info(format!("the branch {} still exists; delete it if you no longer need it", w.branch));
    }
    Ok(())
}

/// The registry repairs itself. An entry whose folder and branch no longer
/// exist holds nothing: someone removed the worktree on their own. If the
/// branch is still alive there may be work: it warns and leaves it.
pub fn heal(quiet: bool) -> Res {
    if !registry::path().is_file() {
        return Ok(());
    }
    let list = match registry::read() {
        Ok(l) => l,
        Err(e) => die!("{e}"),
    };
    let mut retired = 0;
    // A reservation whose creator is still running is about to get its folder:
    // removing it would lose a workspace another process is creating.
    for w in list.into_iter().filter(|w| !Path::new(&w.path).exists() && !w.being_created()) {
        if Path::new(&w.repo).is_dir()
            && git::ok(Path::new(&w.repo), &["rev-parse", "--verify", "-q", &format!("refs/heads/{}", w.branch)])
        {
            if !quiet {
                ui::warn(format!(
                    "'{}' has no folder, but its branch {} is still alive: not removing",
                    w.name, w.branch
                ));
            }
            continue;
        }
        {
            let Ok(_guard) = registry::lock(50) else { continue };
            let n = w.name.clone();
            let _ = registry::update(|l| l.retain(|x| x.name != n));
        }
        retired += 1;
        if !quiet {
            ui::ok(format!("'{}' removed from the registry: no folder, no branch", w.name));
        }
        if !w.task.is_empty() && !w.project.is_empty() {
            // Quietly: heal runs before other commands, and archiving notices
            // are theirs to give.
            let _quiet = QuietStdout::new();
            archive_if_finished(&w.project, &w.task);
        }
    }
    if quiet {
        if retired > 0 {
            ui::info(format!("registry repaired: {retired} workspace(s) with no folder or branch removed"));
        }
    } else if retired == 0 {
        ui::ok("the registry is up to date");
    }
    Ok(())
}

/// Silences stdout while it lives: the steps it wraps print for a person, and
/// here only their outcome matters.
struct QuietStdout {
    saved: i32,
}

impl QuietStdout {
    fn new() -> Self {
        use std::io::Write;
        let _ = std::io::stdout().flush();
        // SAFETY: plain descriptor duplication; restored on drop.
        unsafe {
            let saved = libc::dup(1);
            let null = libc::open(c"/dev/null".as_ptr(), libc::O_WRONLY);
            if null >= 0 {
                libc::dup2(null, 1);
                libc::close(null);
            }
            QuietStdout { saved }
        }
    }
}

impl Drop for QuietStdout {
    fn drop(&mut self) {
        use std::io::Write;
        let _ = std::io::stdout().flush();
        if self.saved >= 0 {
            // SAFETY: restores the descriptor saved in new().
            unsafe {
                libc::dup2(self.saved, 1);
                libc::close(self.saved);
            }
        }
    }
}

/// Archived tasks expire: the description is in the proposal and the
/// decisions in the docs repo. The date is in the file name, not in the
/// modification time, which changes with any copy.
fn expire_tasks(confirmed: bool) -> Res {
    let days =
        env::var("CRUX_TASKS_RETENTION_DAYS").unwrap_or_else(|| env::preference("CRUX_TASKS_RETENTION_DAYS", "180"));
    let Ok(n) = days.parse::<i64>() else { die!("CRUX_TASKS_RETENTION_DAYS has to be a number of days: '{days}'") };
    let cutoff = (chrono::Utc::now() - chrono::Duration::days(n)).format("%Y-%m-%d").to_string();
    let date = crate::regex!(r"^\d{4}-\d{2}-\d{2}$");
    let dir = env::tasks_dir();
    let mut old = vec![];
    for p in project::subdirs(&dir) {
        let mut names: Vec<String> = std::fs::read_dir(dir.join(&p).join("done"))
            .map(|e| {
                e.flatten()
                    .map(|x| x.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.ends_with(".md"))
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        for n in names {
            let d: String = n.chars().take(10).collect();
            if date.is_match(&d) && d < cutoff {
                old.push(dir.join(&p).join("done").join(n));
            }
        }
    }
    if old.is_empty() {
        return Ok(());
    }
    println!("tasks archived more than {days} days ago ({}):", old.len());
    for f in &old {
        println!(
            "      {}/{}",
            f.parent().unwrap().parent().unwrap().file_name().unwrap().to_string_lossy(),
            f.file_stem().unwrap().to_string_lossy()
        );
    }
    if confirmed {
        // Noted as removed, or the other machine's replica would bring them
        // back. With their creation date, read before deleting them.
        for f in &old {
            let created = files::read_or_empty(f)
                .lines()
                .find_map(|l| l.strip_prefix("created: ").map(String::from))
                .unwrap_or_default();
            let removed = f.parent().unwrap().parent().unwrap().join(".removed");
            let mut text = files::read_or_empty(&removed);
            text.push_str(&format!("done/{} {created}\n", files::name(f)));
            let _ = std::fs::write(&removed, text);
            let _ = std::fs::remove_file(f);
        }
        ui::ok(format!("{} expired tasks deleted", old.len()));
    } else {
        ui::info("to delete them: crux workspace gc --yes");
    }
    println!();
    Ok(())
}

/// The registry and the disk drift apart both ways: an entry whose worktree
/// someone deleted by hand, and a worktree that never made it into the
/// registry. `prune` looks at branches; this looks at workspaces.
pub fn gc(argv: &[String]) -> Res {
    let (mut confirmed, mut include_disk) = (false, false);
    for a in argv {
        match a.as_str() {
            "--yes" => confirmed = true,
            "--include-disk" => include_disk = true,
            "--con-disco" => die!("--con-disco is now called --include-disk"),
            other => die!("unknown option: {other}"),
        }
    }
    let _ = registry::init();
    let root = env::projects_root();
    let list = registry::read().unwrap_or_default();
    let without: Vec<String> = list.iter().filter(|w| !Path::new(&w.path).exists()).map(|w| w.name.clone()).collect();
    let registered: Vec<&str> = list.iter().map(|w| w.path.as_str()).collect();
    let mut candidates = vec![];
    for a in project::subdirs(&root) {
        if a.contains("-ws-") {
            candidates.push(root.join(&a));
        }
        for b in project::subdirs(&root.join(&a)).into_iter().filter(|b| b.contains("-ws-")) {
            candidates.push(root.join(&a).join(b));
        }
    }
    candidates.sort();
    let unregistered: Vec<PathBuf> = candidates
        .into_iter()
        .filter(|d| {
            !registered.contains(&d.to_string_lossy().as_ref())
                && git::ok(d, &["rev-parse", "--git-dir"])
                && git::is_worktree(d)
        })
        .collect();
    expire_tasks(confirmed)?;
    if without.is_empty() && unregistered.is_empty() {
        ui::ok("registry and disk agree");
        return Ok(());
    }
    if !without.is_empty() {
        println!("registry entries with no worktree on disk ({}):", without.len());
        for n in &without {
            println!("      {n}");
        }
        println!();
    }
    if !unregistered.is_empty() {
        println!("worktrees on disk that the registry does not know ({}):", unregistered.len());
        for w in &unregistered {
            let note = if clean_workspace(w, "") { "" } else { "  (with work inside)" };
            println!("      {}{note}", files::name(w));
        }
        println!();
    }
    if !confirmed {
        ui::info("to remove the orphan entries: crux workspace gc --yes");
        if !unregistered.is_empty() {
            ui::info("and the worktrees, if they are clean: crux workspace gc --yes --include-disk");
        }
        return Ok(());
    }
    for n in &without {
        let Ok(_guard) = registry::lock(50) else { continue };
        let _ = registry::update(|l| l.retain(|x| x.name != *n));
        ui::ok(format!("{n} removed from the registry"));
    }
    if !include_disk {
        if !unregistered.is_empty() {
            ui::info("the disk is not touched without --include-disk");
        }
        return Ok(());
    }
    for w in &unregistered {
        let base = files::name(w);
        if !clean_workspace(w, "") {
            ui::warn(format!("{base} has unpushed work: it stays"));
            continue;
        }
        let repo = git::main_repo(w).unwrap_or_default();
        if git::ok(&repo, &["worktree", "remove", &w.to_string_lossy()]) {
            ui::ok(format!("{base} removed from disk"));
        } else {
            ui::warn(format!("could not remove {base}: do it with 'git worktree remove'"));
        }
    }
    Ok(())
}

/// A branch merged by squash does not appear in `git branch --merged`: asking
/// the proposal is the only reliable thing. `--merged` is true for any branch
/// pointing at an ancestor of the main one —a fresh one, or develop right
/// after its release— so it alone would delete them without asking.
fn branches_with_merged_pr(repo: &Path) -> Option<Vec<String>> {
    let slug = sh::capture_in(repo, "gh", &["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
    if !slug.ok() || slug.out().is_empty() {
        return None;
    }
    let r = sh::capture(
        "gh",
        &[
            "pr",
            "list",
            "--repo",
            &slug.out(),
            "--state",
            "merged",
            "--limit",
            "200",
            "--json",
            "headRefName",
            "-q",
            ".[].headRefName",
        ],
    );
    Some(r.stdout.lines().map(String::from).collect())
}

pub fn prune(argv: &[String]) -> Res {
    let confirmed = argv.first().map(String::as_str) == Some("--yes");
    let Some(repo) = git::toplevel(&std::env::current_dir().unwrap_or_default()) else {
        die!("this runs inside a repo")
    };
    if !(sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok()) {
        die!("an authenticated gh is needed to know which proposals were merged");
    }
    let main = project::main_branch(&repo);
    let Some(merged) = branches_with_merged_pr(&repo) else { die!("could not ask gh which proposals were merged") };
    let long_lived =
        crate::regex!(r"^(develop|development|staging|stage|next|production|prod|release|release/.*|hotfix/.*)$");
    let mut names: Vec<String> =
        git::out(&repo, &["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes/origin"])
            .unwrap_or_default()
            .lines()
            .map(|b| b.strip_prefix("origin/").unwrap_or(b).to_string())
            .collect();
    names.sort();
    names.dedup();
    // No long-lived branches: even with a merged proposal, deleting them
    // breaks the flow of whoever uses them.
    let integrated: Vec<String> = names
        .into_iter()
        .filter(|b| !b.is_empty() && *b != main && !long_lived.is_match(b) && merged.contains(b))
        .collect();
    if integrated.is_empty() {
        ui::ok("there are no merged branches to clean");
        return Ok(());
    }
    println!("branches with their proposal already merged ({}):", integrated.len());
    for b in &integrated {
        println!("      {b}");
    }
    println!();
    if !confirmed {
        ui::info("to delete them, here and on the remote: crux workspace prune --yes");
        return Ok(());
    }
    let in_use: Vec<String> = git::out(&repo, &["worktree", "list", "--porcelain"])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("branch refs/heads/").map(String::from))
        .collect();
    let mut cleaned = 0;
    for b in &integrated {
        if in_use.contains(b) {
            ui::info(format!("{b} is used by a worktree: it stays"));
            continue;
        }
        // A failing deletion —the branch only existed locally, or is no
        // longer on the remote— must not take the rest of the pass with it.
        let local = git::ok(&repo, &["branch", "-D", b]);
        let remote = git::ok(&repo, &["push", "-q", "origin", "--delete", b]);
        if local || remote {
            cleaned += 1;
        }
    }
    ui::ok(format!("{cleaned} of {} branches cleaned", integrated.len()));
    Ok(())
}
