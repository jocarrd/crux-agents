//! crux release — publish a kernel version.
//!
//!   crux release <version>          shows what it would do and verifies, touching nothing
//!   crux release <version> --yes    tags and publishes
//!
//! The version number is bumped in VERSION **by proposal**, like any other
//! change: this command does not commit to the main branch, it only checks
//! that the version is already there and creates the tag.
//!
//! What sets this apart from a `git tag` is the third check: **before
//! publishing, it verifies that the projects consuming the kernel are still
//! conformant**. Changing the standard and breaking whoever uses it without
//! noticing is the failure a release must prevent.

use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, git, project, sh, ui};
use std::path::Path;

/// Grouped by conventional-commit type, in a fixed order: what matters most
/// to whoever updates goes first.
pub fn notes(subjects: &str) -> String {
    let re = crate::regex!(r"^(\w+)(?:\([^)]*\))?!?:\s*(.+)$");
    let types = [
        ("feat", "Features"),
        ("fix", "Fixes"),
        ("refactor", "Refactor"),
        ("docs", "Documentation"),
        ("test", "Tests"),
        ("chore", "Maintenance"),
    ];
    let order = ["Features", "Fixes", "Refactor", "Documentation", "Tests", "Maintenance", "Other"];
    let mut groups: Vec<(&str, Vec<String>)> = order.iter().map(|t| (*t, vec![])).collect();
    for line in subjects.lines().filter(|l| !l.is_empty()) {
        let (kind, text) = match re.captures(line) {
            Some(c) => (types.iter().find(|(k, _)| *k == &c[1]).map(|(_, t)| *t).unwrap_or("Other"), c[2].to_string()),
            None => ("Other", line.to_string()),
        };
        groups.iter_mut().find(|(t, _)| *t == kind).unwrap().1.push(text);
    }
    let mut out = vec![];
    for (t, items) in groups.into_iter().filter(|(_, i)| !i.is_empty()) {
        out.push(format!("### {t}"));
        out.push(String::new());
        out.extend(items.into_iter().map(|x| format!("- {x}")));
        out.push(String::new());
    }
    out.join("\n")
}

pub fn run(argv: &[String]) -> Res {
    // Publishing is an operation on the kernel repository, not on the
    // installed copy: from there there is neither git nor a suite to run.
    let cwd = std::env::current_dir().unwrap_or_default();
    let repo = git::toplevel(&cwd);
    let Some(repo) = repo.filter(|r| r.join("test/run.sh").is_file() && r.join(names::STANDARD).is_file()) else {
        ui::err("crux release runs from the kernel repository");
        ui::info(format!("you are in: {}", cwd.display()));
        return exit(1);
    };
    let Some(new) = argv.first().cloned().filter(|v| !v.is_empty()) else {
        die!("usage: crux release <version> [--yes]")
    };
    let mut confirmed = false;
    for a in &argv[1..] {
        match a.as_str() {
            "--yes" => confirmed = true,
            other => die!("unknown option: {other}"),
        }
    }
    if !project::is_semver(&new) {
        die!("the version must be semver: 1.2.3");
    }
    let current =
        std::fs::read_to_string(repo.join(names::VERSION)).unwrap_or_default().split_whitespace().collect::<String>();
    let last_tag = git::out(&repo, &["describe", "--tags", "--abbrev=0"])
        .map(|t| t.trim_start_matches('v').to_string())
        .unwrap_or_else(|| "0.0.0".into());
    let last_tag = if last_tag.is_empty() { "0.0.0".to_string() } else { last_tag };
    if !project::version_greater_than(&new, &last_tag) {
        die!("{new} is not later than the last published ({last_tag})");
    }
    println!("release {current} → {new}");
    println!();
    let failures = std::cell::Cell::new(0);
    let failure = |m: String| {
        ui::err(m);
        failures.set(failures.get() + 1);
    };

    let branch = git::out(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    if branch != "main" {
        failure(format!("you are on branch {branch}, not main"));
    }
    if !git::out(&repo, &["status", "--porcelain"]).unwrap_or_default().is_empty() {
        failure("there are uncommitted changes".into());
    }
    if !git::out(&repo, &["log", "--oneline", "@{u}.."]).unwrap_or_default().is_empty() {
        failure("there are unpushed commits".into());
    }
    if git::ok(&repo, &["rev-parse", &format!("v{new}")]) {
        failure(format!("tag v{new} already exists"));
    }
    if current != new {
        failure(format!("VERSION says {current}: bump it to {new} by proposal before tagging"));
    }
    // `crux release` runs the installed copy's code, not the repo's:
    // publishing with an old copy publishes with the old publisher.
    let installed = env::config_value_in(&env::config_file(), "CRUX_HOME")
        .and_then(|h| std::fs::read_to_string(Path::new(&h).join(names::VERSION)).ok())
        .map(|v| v.split_whitespace().collect::<String>())
        .unwrap_or_default();
    if !installed.is_empty() && installed != new {
        failure(format!(
            "the installed kernel is {installed}: reinstall it before publishing {new} ('bash install.sh')"
        ));
    }
    if failures.get() == 0 {
        ui::ok(format!("repo ready: main, clean, up to date and with VERSION at {new}"));
    }

    // The suite also tests this command: without this guard they would call
    // each other endlessly.
    if env::var("CRUX_IN_TESTS").is_some() {
        ui::info("suite skipped: running from the suite itself");
    } else {
        let r = sh::capture_in(&repo, "./test/run.sh", &[]);
        let out = format!("{}{}", r.stdout, r.stderr);
        if r.ok() {
            let n = crate::regex!(r"[0-9]+ (aserciones|assertions)")
                .find_iter(&out)
                .last()
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            ui::ok(format!("suite green ({n})"));
        } else {
            failure("the suite does not pass:".into());
            let lines: Vec<&str> = out.lines().collect();
            for l in &lines[lines.len().saturating_sub(5)..] {
                println!("      {l}");
            }
        }
    }

    // The projects that consume the kernel: the check that justifies this
    // being a command and not a `git tag`.
    let root = env::projects_root();
    let mut consumers = 0;
    for p in project::subdirs(&root) {
        for d in project::subdirs(&root.join(&p)).into_iter().filter(|d| d.ends_with("-docs")) {
            let docs = root.join(&p).join(&d);
            if !docs.join(names::CONTRACT).is_file() {
                continue;
            }
            consumers += 1;
            let r = super::call_quiet(&cwd, "doctor", &[&docs.to_string_lossy()]);
            if r.ok() {
                ui::ok(format!("{d} conformant"));
            } else {
                failure(format!("{d} stops meeting the standard with this version:"));
                for l in format!("{}{}", r.stdout, r.stderr).lines().filter(|l| l.starts_with("error")).take(5) {
                    println!("      {l}");
                }
            }
        }
    }
    if consumers == 0 {
        ui::warn(format!("no project consumes the kernel in {}: nothing to verify", root.display()));
    }

    let last_one = git::out(&repo, &["describe", "--tags", "--abbrev=0"]).unwrap_or_default();
    let range = if last_one.is_empty() { "HEAD".to_string() } else { format!("{last_one}..HEAD") };
    let notes = notes(&git::out(&repo, &["log", "--format=%s", &range]).unwrap_or_default());
    println!();
    println!("Release notes{}:", if last_one.is_empty() { String::new() } else { format!(" (since {last_one})") });
    println!();
    for l in notes.split('\n') {
        println!("  {l}");
    }
    println!();
    if failures.get() > 0 {
        ui::err(format!("{} checks fail: not publishing", failures.get()));
        return exit(1);
    }
    if !confirmed {
        ui::ok(format!("all ready to publish {new}"));
        ui::info(format!("to do it: crux release {new} --yes"));
        return Ok(());
    }
    sh::status(git::cmd(&repo).args(["tag", "-a", &format!("v{new}"), "-m", &format!("{new}\n\n{notes}")]));
    sh::status(git::cmd(&repo).args(["push", "-q", "origin", &format!("v{new}")]));
    ui::ok(format!("v{new} published"));
    // Without this the notes only exist in the tag message, which nobody reads.
    if sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok() {
        if sh::capture_in(&repo, "gh", &["release", "create", &format!("v{new}"), "--title", &new, "--notes", &notes])
            .ok()
        {
            ui::ok(format!("notes published in release v{new}"));
        } else {
            ui::warn(format!("could not publish the notes: 'gh release create v{new} --notes ...' by hand"));
        }
    } else {
        ui::info("gh not authenticated: the notes stay in the tag");
    }
    println!();
    ui::info("projects align with 'crux upgrade' when their turn comes");
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn notes_group_by_type_in_a_fixed_order() {
        let n = super::notes("fix: b\nfeat(x): a\nwhatever");
        assert_eq!(n, "### Features\n\n- a\n\n### Fixes\n\n- b\n\n### Other\n\n- whatever\n");
    }
}
