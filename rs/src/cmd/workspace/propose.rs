//! Proposing the work of a workspace and merging it.

use super::find;
use crate::args::Parser;
use crate::cmd::ship;
use crate::error::{exit, Res};
use crate::names;
use crate::task::record;
use crate::{die, env, files, git, policy, project, sh, task, ui};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

fn short(s: &str) -> String {
    s.chars().take(8).collect()
}

/// The gate records the commit it verified, what was run and with which
/// result: earned, not declared. The shortcut exists, but it is asked for and
/// it shows.
fn check_gate(path: &Path, head: &str) -> Res {
    let receipt = path.join(names::GATE_RECEIPT);
    if !receipt.is_file() {
        ui::err("this commit has not passed the quality gate");
        ui::info("pass it: crux ship run -- <command>, then crux ship seal");
        ui::info("if skipping it is really needed: --skip-gate");
        return exit(1);
    }
    let text = files::read_or_empty(&receipt);
    let commands = ship::receipt_commands(&text);
    let failed = ship::receipt_failures(&text);
    let sealed = ship::sealed_sha(&text).unwrap_or_default();
    if commands == 0 {
        ui::err("the gate receipt records not a single command run");
        ui::info("a bare sha does not prove anything was verified: crux ship run -- <command>");
        return exit(1);
    }
    if !failed.is_empty() {
        ui::err(format!("the receipt records {} in red", ui::count(failed.len(), "check", "checks")));
        for f in &failed {
            println!("      {f}");
        }
        return exit(1);
    }
    if sealed != head {
        ui::err("this commit has not passed the quality gate");
        if !sealed.is_empty() {
            ui::info(format!("the receipt is for {}, and HEAD is {}", short(&sealed), short(head)));
        }
        ui::info("pass it again and close with: crux ship seal");
        return exit(1);
    }
    let Some(kernel) = ship::receipt_kernel(&text).filter(|k| !k.is_empty()) else {
        ui::err("the receipt does not say which crux version sealed it");
        ui::info("seal it again: crux ship seal");
        return exit(1);
    };
    let version = env::crux_version();
    if kernel != version {
        ui::err(format!("the receipt was sealed with crux {kernel} and now {version} is running"));
        ui::info("the gate rules may have changed: pass it again");
        return exit(1);
    }
    ui::ok(format!("gate passed on {} with {} (crux {kernel})", short(head), ui::count(commands, "check", "checks")));
    Ok(())
}

/// Generated files do not count: nobody reads them line by line.
fn written_lines(path: &Path, range: &str) -> usize {
    let locks =
        crate::regex!(r"(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|go\.sum)$");
    let generated = crate::regex!(r"(^|/)(dist|build|vendor|generated|__snapshots__)/|\.(min\.(js|css)|snap)$");
    git::out(path, &["diff", "--numstat", range])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.splitn(3, '\t').collect();
            if f.len() < 3 || f[0] == "-" || locks.is_match(f[2]) || generated.is_match(f[2]) {
                return None;
            }
            Some(f[0].parse::<usize>().unwrap_or(0) + f[1].parse::<usize>().unwrap_or(0))
        })
        .sum()
}

fn plan_lines(record_file: &Path) -> usize {
    record::read(record_file)
        .map(|d| record::content(d.section("Plan")).lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0)
}

pub fn finish(argv: &[String]) -> Res {
    let Some(name) = argv.first().filter(|n| !n.is_empty()).cloned() else {
        die!("usage: crux workspace finish <name> [--title \"...\"] [--skip-gate]")
    };
    let (mut title, mut skip_gate) = (String::new(), false);
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--title" => title = p.value(),
            "--skip-gate" => skip_gate = true,
            "--sin-puerta" => die!("--sin-puerta is now called --skip-gate"),
            other => die!("unknown option: {other}"),
        }
    }
    let w = find(&name)?;
    let (path, branch, repo) = (PathBuf::from(&w.path), w.branch.clone(), PathBuf::from(&w.repo));
    if !path.is_dir() {
        die!("the workspace '{name}' is no longer on disk");
    }
    ensure_committed(&path)?;
    let commits = unproposed_commits(&path, &branch);
    if commits == 0 {
        die!("there is nothing to propose in {branch}");
    }
    let head = git::head_sha(&path).unwrap_or_default();
    if skip_gate {
        ui::warn("proposal opened WITHOUT passing the quality gate, at explicit request");
    } else {
        check_gate(&path, &head)?;
    }
    let record_file = task::file_for_workspace(&w.path).filter(|f| f.is_file());
    if let Some(f) = &record_file {
        warn_if_no_steps(f);
    }
    check_against_main(&path)?;
    // The base comes from the contract, the remote or the local one: assuming
    // origin/main stops finish halfway, with the branch already pushed.
    let main = project::main_branch(&path);
    let base =
        if git::has_ref(&path, &format!("refs/remotes/origin/{main}")) { format!("origin/{main}") } else { main };
    warn_about_size(&path, &format!("{base}...{branch}"), record_file.as_deref());

    let docs = project::find_docs_repo(&path);
    let profile = docs.as_deref().and_then(|d| project::contract_field(d, "profile")).unwrap_or_default();
    let language = policy::commit_language(&profile, docs.as_deref());
    let log = git::out(&path, &["log", "--format=- %s", &format!("{base}..{branch}")]).unwrap_or_default();
    let gate = if skip_gate { None } else { Some(head.as_str()) };
    let body = proposal_body(&path, record_file.as_deref(), &language, &log, gate);
    check_body(&path, &body, record_file.as_deref())?;
    if let Some(d) = docs.as_deref() {
        check_origin(&path, &repo, d)?;
    }
    if sh::status(git::cmd(&path).args(["push", "-q", "-u", "origin", &branch])) != 0 {
        die!("could not push {branch}");
    }
    ui::ok(format!("{branch} pushed ({})", ui::count(commits, "commit", "commits")));
    let url = if sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok() {
        open_proposal(&path, &base, &branch, &title, commits, &body)
    } else {
        String::new()
    };
    if url.is_empty() {
        ui::info(format!("open the proposal on your provider from the branch {branch}"));
    } else {
        ui::ok(format!("proposal opened: {url}"));
        if let Some(f) = &record_file {
            let _ = record::edit(f, true, |d| {
                d.set_text("pr", &url);
                record::advance(d, record::Status::Proposed);
                Ok(())
            });
        }
    }
    println!();
    ui::info("review it before asking for human review: /review-pr");
    ui::info(format!("once it is merged: crux workspace rm {name}"));
    Ok(())
}

/// Nothing leaves a workspace uncommitted: what stays out of git does not
/// reach review. The gate's own files are local state.
fn ensure_committed(path: &Path) -> Res {
    let gate_files = crate::regex!(r" \.crux-(ship|visual)$");
    let pending: Vec<String> = git::out(path, &["status", "--porcelain"])
        .unwrap_or_default()
        .lines()
        .filter(|l| !gate_files.is_match(l))
        .map(String::from)
        .collect();
    if pending.is_empty() {
        return Ok(());
    }
    ui::err(format!("uncommitted changes remain in {}", path.display()));
    for p in &pending {
        println!("      {p}");
    }
    exit(1)
}

/// What is in no remote yet goes into the proposal. The branch's own remote
/// copy does not count: a finish cut off after pushing leaves it there.
fn unproposed_commits(path: &Path, branch: &str) -> usize {
    git::out(path, &["log", "--oneline", branch, "--not", &format!("--exclude=*/{branch}"), "--remotes"])
        .map(|s| s.lines().count())
        .unwrap_or(0)
}

/// This is where context is lost: the session that knew why each thing was
/// done ends. It warns before pushing, when it can still be noted.
fn warn_if_no_steps(record_file: &Path) {
    if !record::summary(&record::read(record_file).unwrap_or_default()).steps.is_empty() {
        return;
    }
    ui::warn("the task is closed without a single step noted");
    ui::info(format!("only the objective is left in {}", record_file.display()));
    ui::info("what you measured and what you discarded along the way is recovered by nobody");
    ui::info("note it now: crux task add \"<step>\" · crux task note \"<decision>\" --why \"<why>\"");
}

/// A branch that clashes with the main one goes out as a proposal that cannot
/// be merged. Checked with the latest from the remote; offline, it goes on.
fn check_against_main(path: &Path) -> Res {
    let main = project::main_branch(path);
    if !git::ok(path, &["fetch", "-q", "origin", &main]) || !git::has_ref(path, &format!("refs/remotes/origin/{main}"))
    {
        return Ok(());
    }
    let r = git::run(
        path,
        &["merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", &format!("origin/{main}")],
    );
    if !r.ok() {
        ui::err(format!("the branch clashes with origin/{main}"));
        for l in r.stdout.lines().skip(1) {
            println!("      {l}");
        }
        ui::info(format!("rebase and pass the gate again: git rebase origin/{main}"));
        return exit(1);
    }
    let behind: usize = git::out(path, &["rev-list", "--count", &format!("HEAD..origin/{main}")])
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if behind > 0 {
        ui::warn(format!(
            "origin/{main} has {} that this branch lacks; they do not clash",
            ui::count(behind, "commit", "commits")
        ));
    }
    Ok(())
}

/// More than 400 written lines is not reviewed well in one sitting; and a
/// change over 100 with no plan in the record is precisely the one nobody
/// could stop in time.
fn warn_about_size(path: &Path, range: &str, record_file: Option<&Path>) {
    let lines = written_lines(path, range);
    if lines > 400 {
        ui::warn(format!("the proposal has {lines} written lines: over 400, what can be reviewed well at once"));
        ui::info("if it can be split into units that work on their own, split it into chained proposals");
        ui::info("if not, say in the description why it goes whole");
    }
    if record_file.is_some_and(|f| lines > 100 && plan_lines(f) == 0) {
        ui::warn(format!("{lines} written lines and the task has no plan"));
        ui::info("if it was approved in the conversation, save it: crux task plan <file>");
    }
}

/// The description comes from the task if it says what changes; if not, from
/// the commits. In the language of what is published in the repo. `gate` is
/// the commit the gate passed on, or None when it was skipped: then the
/// proposal says so, because false evidence misleads more than missing
/// evidence.
fn proposal_body(path: &Path, record_file: Option<&Path>, language: &str, log: &str, gate: Option<&str>) -> String {
    let mut body = record_file
        .and_then(|f| record::read(f).ok())
        .map(|d| record::proposal_body(&d, language, log))
        .unwrap_or_default()
        .trim_end_matches('\n')
        .to_string();
    let (changes, gate_line) = match (language, gate) {
        ("es", None) => ("Cambios", "Abierta SIN pasar la puerta de calidad, a petición explícita.".to_string()),
        ("es", Some(head)) => ("Cambios", format!("Puerta de calidad pasada sobre {}.", short(head))),
        (_, None) => ("Changes", "Opened WITHOUT passing the quality gate, at explicit request.".to_string()),
        (_, Some(head)) => ("Changes", format!("Quality gate passed on {}.", short(head))),
    };
    if body.is_empty() {
        body = format!("{changes}:\n\n{log}\n\n---\n{gate_line}");
    } else if gate.is_none() {
        body = format!("{body}\n\n---\n{gate_line}");
    }
    // The visual review goes in if it is for the commit being proposed; old
    // screenshots are not published as current, but they do not block.
    if path.join(names::VISUAL_RECEIPT).is_file() {
        let r = crate::cmd::call_quiet(path, "visual", &["section", "--publish", "--lang", language]);
        let out = format!("{}{}", r.stdout, r.stderr);
        if r.ok() {
            body = format!("{body}\n\n{}", out.trim_end_matches('\n'));
            ui::ok("visual review added to the proposal");
        } else {
            ui::warn("the visual review does not go into the proposal");
            for l in out.lines() {
                println!("      {l}");
            }
        }
    }
    body
}

/// The body goes through the same filter as ship body before anything
/// leaves, so a body with a credential inside does not even push.
fn check_body(path: &Path, body: &str, record_file: Option<&Path>) -> Res {
    let tmp = std::env::temp_dir().join(format!("crux-body.{}", std::process::id()));
    if let Err(e) = crate::files::write(&tmp, &format!("{body}\n")) {
        die!("{e}");
    }
    let filter = crate::cmd::call_quiet(path, "ship", &["body", &tmp.to_string_lossy()]);
    let _ = std::fs::remove_file(&tmp);
    if filter.ok() {
        return Ok(());
    }
    ui::err("the proposal body does not pass the filter");
    for l in format!("{}{}", filter.stdout, filter.stderr).lines() {
        println!("      {l}");
    }
    ui::info(format!(
        "it comes from the task record: {}",
        record_file.map(|f| f.display().to_string()).unwrap_or_default()
    ));
    exit(1)
}

/// An origin left on a repo's old owner still pushes through the redirect,
/// and then gh takes that owner for a fork.
fn check_origin(path: &Path, repo: &Path, docs: &Path) -> Res {
    let Some(contract) = project::contract_lenient(docs) else { return Ok(()) };
    let origin = git::remote_url(path, "origin");
    let declared = project::remote_url(&contract, &files::name(repo));
    let (Some(origin), Some(declared)) = (origin, declared) else { return Ok(()) };
    if project::normalize_git_url(&origin) == project::normalize_git_url(&declared) {
        return Ok(());
    }
    ui::err(format!("origin is {origin} and crux.json declares {declared}"));
    ui::info(format!(
        "if the repo moved, align it and finish again: git -C {} remote set-url origin {declared}",
        repo.display()
    ));
    exit(1)
}

/// Opens the proposal with gh and returns its URL, or empty if gh could not.
fn open_proposal(path: &Path, base: &str, branch: &str, title: &str, commits: usize, body: &str) -> String {
    // Against the base branch: by now the branch is pushed, and --remotes
    // would leave the title empty.
    let first = git::out(path, &["log", "--format=%s", &format!("{base}..{branch}")])
        .unwrap_or_default()
        .lines()
        .last()
        .map(String::from)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| git::out(path, &["log", "-1", "--format=%s", branch]).unwrap_or_default());
    // The title is what the squash leaves in the main branch's history.
    if title.is_empty() && commits > 1 {
        ui::warn(format!("the title comes from the first of {commits} commits: \"{first}\""));
        ui::info("if it does not sum them up: gh pr edit --title \"...\", or next time finish --title \"...\"");
    }
    let title = if title.is_empty() { first.as_str() } else { title };
    // Finishing again is how commits reach an open proposal: the push already
    // updated it, and a second create only failed with gh's error.
    let open =
        sh::capture_in(path, "gh", &["pr", "view", "--json", "state,url", "--jq", ".state + \" \" + .url"]).out();
    if let Some(url) = open.strip_prefix("OPEN ") {
        ui::ok("the proposal was already open: the push updated it");
        return url.trim().to_string();
    }
    let r =
        sh::capture_cmd(Command::new("gh").args(["pr", "create", "--title", title, "--body", body]).current_dir(path));
    let url = r.out();
    // gh's error is kept: an open proposal, a mandatory template or a missing
    // permission must not read like not having gh installed.
    if url.is_empty() && !r.stderr.trim().is_empty() {
        ui::warn("gh could not open the proposal");
        for l in r.stderr.lines().take(3) {
            println!("      {l}");
        }
    }
    url
}

pub fn merge(argv: &[String]) -> Res {
    let Some(name) = argv.first().filter(|n| !n.is_empty()).cloned() else {
        die!("usage: crux workspace merge <name> [--yes] [--admin]")
    };
    let (mut confirmed, mut admin) = (false, false);
    for a in &argv[1..] {
        match a.as_str() {
            "--yes" => confirmed = true,
            // A protected main asks for an approval GitHub does not let the
            // author give: the admin's bypass is used only when asked for.
            "--admin" => admin = true,
            other => die!("unknown option: {other}"),
        }
    }
    if !(sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok()) {
        die!("an authenticated gh is needed to query and merge the proposal");
    }
    let w = find(&name)?;
    let path = PathBuf::from(&w.path);
    if !path.is_dir() {
        die!("the workspace '{name}' is no longer on disk");
    }
    // What is merged is the remote branch, and after it the worktree is
    // removed: a commit made after finish stayed out of main with all green.
    let dirty = git::out(&path, &["status", "--porcelain"]).unwrap_or_default();
    if !dirty.trim().is_empty() {
        die!("uncommitted changes in {}: commit them and finish again, or they stay out", path.display());
    }
    let head = git::head_sha(&path).unwrap_or_default();
    let Some(remote) = git::out(&path, &["ls-remote", "origin", &format!("refs/heads/{}", w.branch)]) else {
        die!("cannot reach origin to check that the proposal holds this branch's last commit");
    };
    let pushed = remote.split_whitespace().next().unwrap_or("");
    if pushed != head {
        let what = if pushed.is_empty() {
            "is not on the remote".to_string()
        } else {
            format!("on the remote is at {}", &pushed[..pushed.len().min(8)])
        };
        die!(
            "{} {what} and here at {}: what the proposal holds is not this — crux workspace finish {name}",
            w.branch,
            &head[..head.len().min(8)]
        );
    }
    let view = sh::capture_in(
        &path,
        "gh",
        &["pr", "view", "--json", "number,title,url,mergeable,reviewDecision,statusCheckRollup"],
    );
    let d: Value = match serde_json::from_str(&view.stdout) {
        Ok(v) if view.ok() => v,
        _ => die!("there is no open proposal for {} — run 'crux workspace finish {name}'", w.branch),
    };
    // All the signals before deciding: green checks can come with conflicts.
    let s =
        |k: &str| d.get(k).map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string())).unwrap_or_default();
    let checks = d.get("statusCheckRollup").and_then(Value::as_array).cloned().unwrap_or_default();
    let failing: Vec<String> = checks
        .iter()
        .filter(|c| {
            ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT"]
                .contains(&c.get("conclusion").and_then(Value::as_str).unwrap_or(""))
        })
        .map(|c| c.get("name").or_else(|| c.get("context")).and_then(Value::as_str).unwrap_or("").to_string())
        .collect();
    let running = checks
        .iter()
        .filter(|c| c.get("status").and_then(Value::as_str).is_some_and(|st| !st.is_empty() && st != "COMPLETED"))
        .count();
    let review = d
        .get("reviewDecision")
        .and_then(Value::as_str)
        .filter(|r| !r.is_empty())
        .unwrap_or("no review required")
        .to_string();
    let num = s("number");
    println!("proposal #{num} · {}", s("title"));
    println!("{}", s("url"));
    println!();
    let (mut blocked, mut no_ci) = (false, false);
    if checks.is_empty() {
        ui::warn("no automatic checks: the only validation is the one you passed locally");
        no_ci = true;
    } else if running > 0 {
        ui::warn(format!("{running} checks still running"));
        blocked = true;
    } else if !failing.is_empty() {
        ui::err(format!("{} checks failing: {}", failing.len(), failing.join(", ")));
        blocked = true;
    } else {
        ui::ok(format!("{} checks green", checks.len()));
    }
    match s("mergeable").as_str() {
        "MERGEABLE" => ui::ok("no conflicts"),
        "CONFLICTING" => {
            ui::err("there are conflicts to resolve");
            blocked = true;
        }
        other => ui::warn(format!("unknown merge state: {other}")),
    }
    if review == "CHANGES_REQUESTED" {
        ui::err("changes were requested in the review");
        blocked = true;
    }
    println!();
    if blocked {
        ui::err("not merging: there is something to resolve first");
        return exit(1);
    }
    if !confirmed {
        if no_ci {
            ui::ok("nothing blocks the merge, but there is no automatic safety net behind it");
        } else {
            ui::ok("all green");
        }
        ui::info(format!("to merge it: crux workspace merge {name} --yes"));
        return Ok(());
    }
    // Without --delete-branch: gh tries to switch to the base branch to delete
    // the local one, and from a worktree the base is used by another.
    let mut merge = Command::new("gh");
    merge.args(["pr", "merge", "--squash"]).current_dir(&path);
    if admin {
        merge.arg("--admin");
    }
    sh::status(&mut merge);
    // The exit code is not trusted: the cleanup can fail after the merge.
    let merged = sh::capture_in(&path, "gh", &["pr", "view", "--json", "mergedAt", "-q", ".mergedAt // \"\""]).out();
    if merged.is_empty() {
        die!("proposal #{num} was not merged");
    }
    ui::ok(format!("proposal #{num} merged"));
    if let Some(f) = task::file_for_workspace(&w.path).filter(|f| f.is_file()) {
        task::advance_file(&f, record::Status::Merged);
    }
    if git::ok(&path, &["push", "-q", "origin", "--delete", &w.branch]) {
        ui::ok("remote branch deleted");
    } else {
        ui::info("the remote branch is still there: delete it from your provider if you want");
    }
    println!();
    // Once merged the workspace has nothing left to do; leaving it alive by
    // default piles up finished workspaces.
    if env::preference_flag("CRUX_MERGE_CLOSE_WORKSPACE", true) {
        if super::clean::rm(std::slice::from_ref(&name)).is_err() {
            ui::warn(format!(
                "the workspace is still alive: close it with 'crux workspace rm {name}' when it is clean"
            ));
        }
    } else {
        ui::info(format!(
            "the workspace is still alive (CRUX_MERGE_CLOSE_WORKSPACE=false): 'crux workspace rm {name}'"
        ));
    }
    Ok(())
}
