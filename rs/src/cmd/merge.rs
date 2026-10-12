//! crux merge — merges a proposal after checking it is the one you think it is.
//!
//!   crux merge <number> [--admin]
//!
//! `gh pr merge` resolves the repository from the directory you are in, so a
//! correct number in the wrong place merges another project's proposal without
//! asking anything. Here it is said out loud what is about to be merged, and
//! where, and it stops if something does not add up.

use crate::error::Res;
use crate::{die, git, project, registry, sh, task, ui};
use serde_json::Value;
use std::path::Path;
use std::process::Command;

pub fn run(argv: &[String]) -> Res {
    let num = argv.first().cloned().unwrap_or_default();
    if num.is_empty() {
        die!("usage: crux merge <proposal number>");
    }
    if !num.chars().all(|c| c.is_ascii_digit()) {
        die!("the proposal number is an integer, not '{num}'");
    }
    if !sh::exists("gh") {
        die!("gh is needed to talk to the remote");
    }
    if !sh::capture("gh", &["auth", "status"]).ok() {
        die!("gh is not authenticated");
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(repo_dir) = git::toplevel(&cwd) else { die!("this is not a git repository") };
    project::refuse_if_archived(&repo_dir)?;
    let Some(origin) = git::remote_url(&repo_dir, "origin") else {
        die!("the repository has no origin: I do not know where to look")
    };
    let slug = crate::regex!(r"^.*github\.com[:/]").replace(&origin, "");
    let slug = slug.strip_suffix(".git").unwrap_or(&slug).to_string();

    let view = sh::capture(
        "gh",
        &["pr", "view", &num, "--repo", &slug, "--json", "title,state,headRefName,baseRefName,isDraft,mergeable"],
    );
    let data: Value = match serde_json::from_str(&view.stdout) {
        Ok(v) if view.ok() => v,
        _ => die!("proposal #{num} does not exist in {slug} — are you in the right repo?"),
    };
    let field = |k: &str| match data.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(v) => v.to_string(),
        None => "undefined".into(),
    };
    let (title, status, branch, base) = (field("title"), field("state"), field("headRefName"), field("baseRefName"));
    println!("{slug}#{num} · {title}");
    println!("  {branch} → {base}");
    println!();
    if status != "OPEN" {
        die!("the proposal is {status}, not open");
    }
    if field("isDraft") == "true" {
        die!("the proposal is a draft");
    }
    let dirty = git::out(&repo_dir, &["status", "--porcelain"]).map(|s| s.lines().count()).unwrap_or(0);
    if dirty > 0 {
        ui::warn(format!(
            "{} in the repo (it does not prevent the merge)",
            ui::count(dirty, "uncommitted file", "uncommitted files")
        ));
    }
    let mut merge = Command::new("gh");
    merge.args(["pr", "merge", &num, "--repo", &slug, "--merge", "--delete-branch"]).args(&argv[1..]);
    sh::status(&mut merge);

    // The exit code is not trusted: the cleanup after the merge can fail once
    // the merge is already done.
    let merged_at =
        sh::capture("gh", &["pr", "view", &num, "--repo", &slug, "--json", "mergedAt", "-q", ".mergedAt // \"\""])
            .out();
    if merged_at.is_empty() {
        die!("proposal #{num} was not merged");
    }

    // The task of the workspace that held the branch is now merged, so a later
    // `crux workspace rm` archives it instead of leaving it open.
    let main_dir = if git::is_worktree(&repo_dir) {
        git::main_repo(&repo_dir).unwrap_or(repo_dir.clone())
    } else {
        repo_dir.clone()
    };
    let main_dir = project::normalize(&main_dir);
    let hit =
        registry::read().unwrap_or_default().into_iter().find(|w| w.branch == branch && Path::new(&w.repo) == main_dir);
    if let Some(w) = hit {
        if let Some(f) = task::file_for_workspace(&w.path) {
            if f.is_file() && task::advance_file(&f, crate::task::record::Status::Merged) {
                ui::ok(format!("task {} marked as merged", f.file_stem().unwrap().to_string_lossy()));
            }
        }
    }
    Ok(())
}
