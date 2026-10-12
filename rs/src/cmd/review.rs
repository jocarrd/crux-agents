//! crux review — gathers the material for reviewing a proposal.
//!
//!   crux review [--base <branch>] [--repo <dir>]
//!
//! It does not review: it prepares. `/review-pr` does the review with this in
//! front of it, so it does not depend on someone remembering to gather the
//! diff, the proposal and the checks.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::{die, git, sh, ui};
use serde_json::Value;
use std::path::{Path, PathBuf};

mod scope;

fn head(title: &str) {
    let p = ui::palette();
    println!();
    println!("{}── {title} {}", p.dim, p.off);
}

fn indent(text: &str) {
    for l in text.lines() {
        println!("      {l}");
    }
}

pub fn run(argv: &[String]) -> Res {
    if argv.first().map(String::as_str) == Some("scope") {
        let cwd = std::env::current_dir().unwrap_or_default();
        return match scope::report(&cwd, &cwd, argv.get(1).map(String::as_str)) {
            Ok(text) => {
                print!("{text}");
                Ok(())
            }
            Err(e) => {
                eprintln!("error: {e}");
                exit(1)
            }
        };
    }
    let mut repo = std::env::current_dir().unwrap_or_default();
    let mut base = String::new();
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--base" => base = p.value(),
            "--repo" => repo = PathBuf::from(p.value()),
            other => die!("unknown option: {other}"),
        }
    }
    let Some(repo) = (if repo.is_dir() { git::toplevel(&repo) } else { None }) else {
        die!("not a git repo: {}", repo.display())
    };
    let _ = std::env::set_current_dir(&repo);
    let g = |args: &[&str]| git::out(&repo, args).unwrap_or_default();
    let branch = g(&["rev-parse", "--abbrev-ref", "HEAD"]);
    if base.is_empty() {
        base = g(&["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).replacen("refs/remotes/", "", 1);
        if base.is_empty() {
            for c in ["origin/main", "origin/master", "main", "master"] {
                if git::ok(&repo, &["rev-parse", "--verify", "--quiet", c]) {
                    base = c.into();
                    break;
                }
            }
        }
    }
    if base.is_empty() {
        die!("cannot find the base branch — pass it with --base");
    }
    if g(&["rev-parse", &branch]) == g(&["rev-parse", &base]) {
        die!("{branch} is at the same commit as {base}: there is nothing to review");
    }
    let mut name = crate::files::name(&repo);
    if git::is_worktree(&repo) {
        if let Some(m) = git::main_repo(&repo) {
            name = crate::files::name(&m);
        }
    }
    println!("review of {branch} over {base} — {name}");
    println!();

    head("commits");
    indent(&g(&["log", "--oneline", &format!("{base}..{branch}")]));
    head("files");
    indent(&g(&["diff", "--stat", &format!("{base}...{branch}")]));
    let dirty: Vec<String> = g(&["status", "--porcelain"]).lines().take(5).map(String::from).collect();
    if !dirty.is_empty() {
        ui::warn("there are uncommitted changes: they are not part of the proposal");
        indent(&dirty.join("\n"));
    }

    if sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok() {
        let pr = sh::capture(
            "gh",
            &["pr", "view", &branch, "--json", "number,title,mergeable,mergeStateStatus,statusCheckRollup"],
        );
        match serde_json::from_str::<Value>(&pr.stdout) {
            Ok(d) if pr.ok() => {
                head("proposal");
                let s = |k: &str| {
                    d.get(k)
                        .map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string()))
                        .unwrap_or_else(|| "undefined".into())
                };
                println!("      #{} {}", s("number"), s("title"));
                println!("      {} · {}", s("mergeable"), s("mergeStateStatus"));
                let checks = d.get("statusCheckRollup").and_then(Value::as_array).cloned().unwrap_or_default();
                if checks.is_empty() {
                    println!("      no automatic checks — nothing blocking it is not the same as verified");
                }
                for c in checks {
                    let state = ["conclusion", "state"]
                        .iter()
                        .find_map(|k| c.get(*k).and_then(Value::as_str).filter(|v| !v.is_empty()))
                        .unwrap_or("?")
                        .to_lowercase();
                    let label =
                        c.get("name").or_else(|| c.get("context")).and_then(Value::as_str).unwrap_or("undefined");
                    println!("      {state:<10} {label}");
                }
            }
            _ => ui::info(format!("no open proposal for {branch}")),
        }
    }

    // Objective signals. Not verdicts: the places to look first. Each one has
    // shown up in a real review as the finding nobody saw.
    head("signals");
    let mut has_signal = false;
    let mut signal = |m: String| {
        has_signal = true;
        ui::warn(m);
    };
    let files = g(&["diff", "--name-only", &format!("{base}...{branch}")]);
    let not_code = crate::regex!(r"\.(md|txt|json|ya?ml|lock)$|^docs/");
    let test_path = crate::regex!(r"(?i)(^|/)(test|tests|spec|__tests__)/|\.(test|spec)\.[a-z]+$");
    let code: Vec<&str> = files.lines().filter(|f| !f.is_empty() && !not_code.is_match(f)).collect();
    let tests: Vec<&str> = files.lines().filter(|f| test_path.is_match(f)).collect();
    if !code.is_empty() && tests.is_empty() {
        signal("touches code and touches no test".into());
    }
    // A console.log in a test is its way of reporting, not unfinished work.
    let code_paths: Vec<&str> = code.iter().copied().filter(|f| !test_path.is_match(f)).collect();
    let mut diff_args = vec!["diff".to_string(), format!("{base}...{branch}"), "--".to_string()];
    diff_args.extend(code_paths.iter().map(|s| s.to_string()));
    let diff_refs: Vec<&str> = diff_args.iter().map(String::as_str).collect();
    let added: String =
        g(&diff_refs).lines().filter(|l| l.starts_with('+') && !l.starts_with("+++")).collect::<Vec<_>>().join("\n");
    let marker_re = crate::regex!(r"\b(TODO|FIXME|XXX|HACK|console\.log|debugger|binding\.pry)\b");
    let mut markers: Vec<String> = marker_re.find_iter(&added).map(|m| m.as_str().to_string()).collect();
    markers.sort();
    markers.dedup();
    if !markers.is_empty() {
        signal(format!("adds unfinished-work markers: {}", markers.join(" ")));
    }
    let secret_re = crate::regex!(r#"(?i)(api[_-]?key|secret|token|password|passwd)["']?\s*[:=]\s*["'][^"']{8,}"#);
    if secret_re.is_match(&added) {
        signal("there seem to be credentials in the diff — check it first".into());
    }
    let dep_re =
        crate::regex!(r"(?i)package\.json|.*\.lock$|requirements.*\.txt|pyproject\.toml|go\.mod|Cargo\.toml|Gemfile");
    let deps: Vec<&str> = files.lines().filter(|f| dep_re.is_match(f)).collect();
    if !deps.is_empty() {
        signal(format!("changes dependencies: {} ", deps.join(" ")));
    }
    for f in files.lines().filter(|f| Path::new(f).is_file()) {
        let n = std::fs::read_to_string(f).map(|t| t.matches('\n').count()).unwrap_or(0);
        if n > 700 {
            signal(format!("{f} ends up at {n} lines"));
        }
    }
    let large: Vec<String> = g(&["diff", "--numstat", &format!("{base}...{branch}")])
        .lines()
        .filter_map(|l| {
            let p: Vec<&str> = l.split('\t').collect();
            let (a, d) = (p.first()?.parse::<i64>().unwrap_or(0), p.get(1)?.parse::<i64>().unwrap_or(0));
            (a + d > 400).then(|| format!("{} ({a}+/{d}-)", p.get(2).unwrap_or(&"")))
        })
        .collect();
    if !large.is_empty() {
        signal(format!("large changes to review in one sitting: {} ", large.join(" ")));
    }
    if !has_signal {
        ui::ok("no automatic signal");
    }

    // Which specialist reviewers it deserves and who merges it. The diff
    // decides, not the mood of the moment: by eye everything looks low risk.
    head("risk and specialists");
    let text = match scope::report(&repo, &repo, Some(&base)) {
        Ok(t) => t,
        Err(e) => die!("could not classify the proposal: error: {e}"),
    };
    indent(&text.lines().filter(|l| !l.starts_with("base:")).collect::<Vec<_>>().join("\n"));

    head("the diff, to read in full");
    println!("      git diff {base}...{branch}");
    println!();
    ui::info("this is the material, not the review: the review is /review-pr");
    Ok(())
}
