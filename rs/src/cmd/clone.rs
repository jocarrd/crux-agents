//! crux clone — bring a whole project to a new machine.
//!
//!   crux clone <project> [--from <template|url>] [--parent <dir>]
//!
//! Clones the docs repo, reads its contract and clones the repos it declares.
//! Two things come from the contract and not from an assumption: the list of
//! repos —which in a hand-written guide goes stale as soon as you add one— and
//! **where they are cloned from**, which can differ for documentation and code.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::{die, env, files, git, project, sh, ui};
use std::path::{Path, PathBuf};

/// A machine set up before the project existed keeps its repos wherever they
/// were cloned back then. Cloning again leaves two copies of the same repo,
/// and sync keeps advancing the old one.
fn clone_elsewhere(parent: &Path, url: &str) -> Option<PathBuf> {
    let wanted = project::normalize_git_url(url);
    let mut candidates = vec![];
    for a in project::subdirs(parent) {
        candidates.push(parent.join(&a));
    }
    for a in project::subdirs(parent) {
        for b in project::subdirs(&parent.join(&a)) {
            candidates.push(parent.join(&a).join(b));
        }
    }
    candidates.into_iter().find(|d| {
        d.join(".git").is_dir()
            && project::normalize_git_url(&git::remote_url(d, "origin").unwrap_or_default()) == wanted
    })
}

pub fn run(argv: &[String]) -> Res {
    let Some(arg) = argv.first().filter(|a| !a.is_empty()) else {
        die!("usage: crux clone <project> [--from <template|url>] [--parent <dir>]")
    };
    let mut from = String::new();
    let mut parent = env::projects_root();
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--from" => from = p.value(),
            "--parent" => parent = PathBuf::from(p.value()),
            other => die!("unknown option: {other}"),
        }
    }
    let name = arg.rsplit('/').next().unwrap_or(arg);
    let project_name = name.strip_suffix("-docs").unwrap_or(name).to_string();
    let root = parent.join(&project_name);
    let docs = root.join(format!("{project_name}-docs"));

    println!("cloning {project_name}");
    println!();
    let _ = std::fs::create_dir_all(&root);

    // The docs repo, which knows the rest. Fetching it needs a URL, and there
    // is no contract yet to give it: the user passes it, or the machine
    // default is used.
    if docs.join(".git").is_dir() {
        ui::ok(format!("{project_name}-docs already there"));
    } else {
        let tmpl = if from.is_empty() { project::remote_template().unwrap_or_default() } else { from.clone() };
        if tmpl.is_empty() {
            ui::err(format!("I do not know where to fetch {project_name}-docs from"));
            ui::info("pass it with --from 'git@your-remote:org/{repo}.git' (or the full URL),");
            ui::info("or set a default with CRUX_REMOTE in ~/.crux/config");
            return exit(1);
        }
        let url = tmpl.replace("{repo}", &format!("{project_name}-docs"));
        if sh::status(std::process::Command::new("git").args(["clone", "-q", &url]).arg(&docs)) != 0 {
            die!("could not clone from {url}");
        }
        ui::ok(format!("{project_name}-docs"));
    }
    if !project::contract_file(&docs).is_file() {
        die!("{project_name}-docs is not adopted (no crux.json): clone the rest by hand");
    }
    let contract = project::contract_lenient(&docs).unwrap_or_default();
    let profile = files::get_str(&contract, "profile").unwrap_or_else(|| "?".into());

    let (mut failed, mut without_remote, mut elsewhere) = (vec![], vec![], vec![]);
    for repo in files::str_list(contract.get("repos")) {
        if repo.is_empty() {
            continue;
        }
        // The name comes from crux.json and is joined into a path; a contract
        // that arrives cloned never went through add-repo's check.
        if !project::valid_name(&repo) {
            ui::warn(format!("invalid repo name in the contract: {repo}"));
            continue;
        }
        let dir = root.join(&repo);
        if dir.join(".git").is_dir() {
            ui::info(format!("{repo} already there"));
            continue;
        }
        let Some(url) = project::remote_url(&contract, &repo) else {
            without_remote.push(repo);
            continue;
        };
        if let Some(existing) = clone_elsewhere(&parent, &url) {
            elsewhere.push(format!(
                "{repo} is already at {} — move it: mv {} {}",
                existing.display(),
                existing.display(),
                dir.display()
            ));
            continue;
        }
        if sh::capture("git", &["clone", "-q", &url, &dir.to_string_lossy()]).ok() {
            ui::ok(&repo);
        } else {
            failed.push(format!("{repo}  ({url})"));
        }
    }
    if !without_remote.is_empty() {
        println!();
        ui::warn(format!("no remote declared: {}", without_remote.join(" ")));
        ui::info(format!("add \"remote\" to {project_name}-docs/crux.json, or an override in remote.repos"));
    }
    if !elsewhere.is_empty() {
        println!();
        ui::warn("already cloned outside the project, not cloned again:");
        for f in &elsewhere {
            ui::info(f);
        }
    }
    if !failed.is_empty() {
        println!();
        ui::warn("could not clone:");
        for f in &failed {
            ui::info(f);
        }
        // In a client project the code is normally in another organization:
        // this is information, not a failure.
        if profile == "client-repo" {
            ui::info(format!("profile {profile}: the code usually lives on the client's remote, clone it yourself"));
        } else {
            ui::info("check the name or the permissions");
        }
    }

    let docs_s = docs.to_string_lossy().into_owned();
    println!();
    super::call("link", &[&docs_s]);
    println!();
    super::call("doctor", &[&docs_s]);
    // Bringing a project over without hooking anything leaves a copy that
    // looks ready and is not: everything that upholds the standard is
    // automatic. Done with the repos on disk, since per-repo hooks need them.
    println!();
    if super::call_quiet(&docs, "hooks", &["install"]).ok() {
        ui::ok("hooks installed");
    } else {
        ui::warn(format!("could not install the hooks — do it with 'crux hooks install' from {project_name}-docs"));
    }
    // And the MCP servers the project declares, for the same reason.
    let declares_mcp = contract.get("mcp").and_then(|m| m.as_object()).is_some_and(|m| !m.is_empty());
    if declares_mcp {
        if super::call_quiet(&docs, "mcp", &["install"]).ok() {
            ui::ok("MCP servers written");
        } else {
            ui::warn(format!(
                "could not write the MCP servers — do it with 'crux mcp install' from {project_name}-docs"
            ));
        }
    }
    println!();
    println!("done: {}", root.display());
    if docs.join("operations/machine-onboarding.md").is_file() {
        ui::info(format!("project credentials and secrets: {project_name}-docs/operations/machine-onboarding.md"));
    }
    Ok(())
}
