//! crux bootstrap — get a new machine ready to work.
//!
//!   crux bootstrap [--owner <owner>[,<owner>]] [--parent <dir>] [--only a,b] [--dry-run]
//!
//! Checks the machine, discovers all the projects and fetches them. It is
//! `crux clone` repeated, plus the two things you do not have on a blank
//! machine: knowing which projects exist and what you still have to install.
//!
//! What it does NOT do, on purpose: move credentials. SSH keys, tokens and
//! secrets are not copied from one machine to another by a tool.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, person, project, sh, ui};
use std::path::{Path, PathBuf};
use std::process::Command;

fn bring_profile(parent: &Path, owner: &str, all_repos: &[String], dry: bool) {
    let name = person::repo_name();
    println!();
    let quiet = |args: &[&str]| {
        let home = env::crux_home().unwrap_or_default();
        sh::capture_cmd(
            Command::new(std::env::current_exe().unwrap_or_default())
                .arg("profile")
                .args(args)
                .env(env::PROJECTS_DIR_KEY, parent)
                .env("CRUX_HOME", &home),
        )
        .ok()
    };
    if parent.join(&name).join("PROFILE.md").is_file() {
        ui::ok(format!("profile already in {}", parent.join(&name).display()));
        if !dry && !quiet(&["link"]) {
            ui::warn("could not load the profile into the agents — 'crux profile link'");
        }
    } else if all_repos.contains(&name) {
        if dry {
            ui::info(format!("[dry-run] would clone the profile {owner}/{name}"));
        } else if quiet(&["clone", "--owner", owner]) {
            ui::ok(format!("profile {owner}/{name} cloned and loaded into the agents"));
        } else {
            ui::warn("could not bring the profile — 'crux profile clone'");
        }
    } else {
        ui::info(format!("no profile on {owner}: 'crux profile init' creates one, so preferences travel too"));
    }
}

/// The tasks the other machines left open, which is what you sit down to
/// resume. Through the binary, so the project is looked for under `parent`.
fn bring_tasks(parent: &Path, project: &str) {
    let home = env::crux_home().unwrap_or_default();
    let out = sh::capture_cmd(
        Command::new(std::env::current_exe().unwrap_or_default())
            .args(["__task-sync", "sync", "--project", project])
            .env(env::PROJECTS_DIR_KEY, parent)
            .env("CRUX_HOME", &home),
    );
    let result = serde_json::from_str::<serde_json::Value>(&out.stdout)
        .ok()
        .and_then(|v| v.as_array().and_then(|a| a.first().cloned()));
    match result.as_ref().and_then(|r| r.get("status")).and_then(serde_json::Value::as_str) {
        Some("ok") => {
            let n = result.as_ref().and_then(|r| r.get("pulled")).and_then(serde_json::Value::as_u64).unwrap_or(0);
            if n > 0 {
                ui::ok(format!("{project}: {}", ui::count(n as usize, "task pulled", "tasks pulled")));
            }
        }
        Some("failed") | None => ui::warn(format!("could not bring the tasks of {project} — 'crux sync'")),
        // Not published on purpose (public repo, disabled, no remote).
        Some(_) => {}
    }
}

pub fn run(argv: &[String]) -> Res {
    let (mut owners_arg, mut only, mut dry) = (String::new(), String::new(), false);
    let mut parent = env::projects_root();
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--owner" => {
                if !owners_arg.is_empty() {
                    owners_arg.push(',');
                }
                owners_arg.push_str(&p.value());
            }
            "--parent" => parent = PathBuf::from(p.value()),
            "--only" => only = p.value(),
            "--dry-run" => dry = true,
            other => die!("unknown option: {other}"),
        }
    }

    // The machine, first of all: cloning twenty repos to discover afterwards
    // that something is missing is the worst way to find out.
    println!("1. the machine");
    println!();
    if super::call("machine", &[]) != 0 {
        println!();
        die!("fix the errors above and run it again");
    }
    if !sh::exists("gh") {
        die!("gh is needed to discover the projects — install it, or clone them one by one with 'crux clone'");
    }
    if !sh::capture("gh", &["auth", "status"]).ok() {
        die!("gh not authenticated — 'gh auth login' and come back");
    }
    // The first owner is yours: the profile and the loose repos are looked
    // for there.
    let owners: Vec<String> = if owners_arg.is_empty() {
        project::search_owners()
    } else {
        let mut seen = std::collections::HashSet::new();
        owners_arg.split(',').filter(|o| !o.trim().is_empty() && seen.insert(o.to_string())).map(String::from).collect()
    };
    let Some(owner) = owners.first().cloned() else {
        die!("I do not know which account to search under — pass it with --owner")
    };

    println!();
    println!("2. projects of {}", owners.join(" "));
    println!();
    let mut all_repos: Vec<String> =
        sh::capture("gh", &["repo", "list", &owner, "--limit", "300", "--json", "name", "--jq", ".[].name"])
            .stdout
            .lines()
            .map(String::from)
            .collect();
    all_repos.sort();
    all_repos.dedup();
    let filter: Vec<String> = only.split(',').filter(|x| !x.is_empty()).map(String::from).collect();
    // Both live under <parent>/<project>: two owners with the same project
    // name cannot share the machine, and the first one found keeps it.
    let mut projects: Vec<(String, String)> = vec![];
    let mut any_candidate = false;
    for o in &owners {
        for p in project::candidate_projects(o).into_iter().filter(|p| filter.is_empty() || filter.contains(p)) {
            any_candidate = true;
            if let Some((_, first)) = projects.iter().find(|(x, _)| *x == p) {
                ui::warn(format!("{o}/{p}-docs has the same name as {first}/{p}-docs — only the first one comes"));
                continue;
            }
            let label = if *o == owner { p.clone() } else { format!("{p} ({o})") };
            if project::has_contract(o, &p) {
                ui::ok(&label);
                projects.push((p, o.clone()));
            } else {
                ui::info(format!("{label}: {p}-docs has no contract — not a crux project, skipped"));
            }
        }
    }
    if !any_candidate {
        die!("no *-docs repo under {}", owners.join(" "));
    }
    if projects.is_empty() {
        die!("none carries a contract");
    }
    if dry {
        println!();
        println!(
            "would fetch {} projects to {}: {}",
            projects.len(),
            parent.display(),
            projects.iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>().join(" ")
        );
        bring_profile(&parent, &owner, &all_repos, true);
        return Ok(());
    }

    println!();
    println!("3. fetching {} projects to {}", projects.len(), parent.display());
    let (mut fetched, mut failed) = (vec![], vec![]);
    for (p, o) in &projects {
        println!();
        println!("── {p}");
        // Your own projects use the machine template as is.
        let mut args = vec![p.clone(), "--parent".into(), parent.to_string_lossy().into_owned()];
        if *o != owner {
            args.push("--from".into());
            args.push(project::template_for_owner(o));
        }
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        if super::call("clone", &refs) == 0 {
            fetched.push(p.clone());
        } else {
            failed.push(p.clone());
        }
    }

    // An environment with all the code and no credentials is not ready, and
    // the worst possible ending is one that says it is.
    println!();
    println!("4. what is missing");
    println!();
    ui::ok(format!("{} projects in {}", fetched.len(), parent.display()));
    if !failed.is_empty() {
        ui::err(format!("could not do: {}", failed.join(" ")));
    }
    let with_credentials: Vec<&String> = fetched
        .iter()
        .filter(|p| parent.join(p).join(format!("{p}-docs/operations/machine-onboarding.md")).is_file())
        .collect();
    if !with_credentials.is_empty() {
        println!();
        ui::warn("credentials to put in by hand — they are not copied from one machine to another:");
        for p in with_credentials {
            ui::info(format!("{p}  →  {p}/{p}-docs/operations/machine-onboarding.md"));
        }
    }
    bring_profile(&parent, &owner, &all_repos, false);

    // A remote repo that belongs to no project is not fetched by this, and
    // keeping quiet would leave you believing everything is there. With
    // --only the rest is left out on purpose.
    let name = person::repo_name();
    let standalone: Vec<&String> = if only.is_empty() {
        all_repos
            .iter()
            .filter(|r| **r != name)
            .filter(|r| {
                !parent.join(r).is_dir() && !project::subdirs(&parent).iter().any(|d| parent.join(d).join(r).is_dir())
            })
            .collect()
    } else {
        vec![]
    };
    if !standalone.is_empty() {
        println!();
        ui::warn(format!("repos of {owner} that belong to no project, so they do not come here:"));
        ui::info(standalone.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(" "));
        ui::info("if one is needed: git clone, or 'crux adopt' if it deserves to be a project");
    }

    // Fetching the projects and hooking nothing leaves a machine that looks
    // ready and is not. Done here, with the projects on disk, because the
    // per-repo hooks need them.
    println!();
    for p in &fetched {
        let docs = parent.join(p).join(format!("{p}-docs"));
        if !docs.join(names::CONTRACT).is_file() {
            continue;
        }
        if super::call_quiet(&docs, "hooks", &["install"]).ok() {
            ui::ok(format!("hooks installed in {p}"));
        } else {
            ui::warn(format!(
                "could not install the hooks in {p} — do it with 'crux hooks install' from its docs repo"
            ));
        }
        let declares_mcp = project::contract_lenient(&docs)
            .and_then(|c| c.get("mcp").and_then(|m| m.as_object()).map(|m| !m.is_empty()))
            .unwrap_or(false);
        if declares_mcp {
            if super::call_quiet(&docs, "mcp", &["install"]).ok() {
                ui::ok(format!("MCP servers written in {p}"));
            } else {
                ui::warn(format!("could not write the MCP servers in {p} — 'crux mcp install' from its docs repo"));
            }
        }
        bring_tasks(&parent, p);
    }
    println!();
    ui::info("'crux status' to see how everything turned out");
    if failed.is_empty() {
        Ok(())
    } else {
        exit(1)
    }
}
