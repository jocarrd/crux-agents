//! crux add-repo — registers a new repo in an already adopted project.
//!
//!   crux add-repo <repo> [--description "..."] [dir]
//!
//! Creates its documentation folder, declares it in crux.json, registers it in
//! the table of repos/README.md and regenerates the pointers.

use crate::args::Parser;
use crate::error::Res;
use crate::names;
use crate::{die, env, files, git, project, template, ui};
use serde_json::{json, Value};
use std::path::PathBuf;

pub fn run(argv: &[String]) -> Res {
    let repo = argv.first().cloned().unwrap_or_default();
    if repo.is_empty() {
        die!("usage: crux add-repo <repo> [--description \"...\"]");
    }
    if !project::valid_name(&repo) {
        die!("the name must be lowercase kebab-case, without slashes: {repo}");
    }
    let mut description = "What this repo does, in one line.".to_string();
    let mut target = std::env::current_dir().unwrap_or_default();
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--description" => description = p.value(),
            other => target = PathBuf::from(other),
        }
    }
    let Some(docs) = project::find_docs_repo(&target) else {
        die!("cannot find a docs repo from {}", target.display())
    };
    let config = project::contract_file(&docs);
    if !config.is_file() {
        die!("crux.json is missing — run 'crux adopt' first");
    }
    let mut contract = match project::read_contract(&docs) {
        Ok(c) => c,
        Err(e) => die!("{} cannot be read: {e}", config.display()),
    };
    let project_name = files::get_str(&contract, "project").unwrap_or_default();
    let root = docs.parent().unwrap().to_path_buf();
    if files::str_list(contract.get("repos")).contains(&repo) {
        die!("{repo} is already declared in crux.json");
    }
    if docs.join("repos").join(&repo).is_dir() {
        die!("repos/{repo}/ already exists in the docs repo");
    }
    if !root.join(&repo).is_dir() {
        ui::warn(format!("{repo} is not yet in {}/ — registering it anyway", root.display()));
    }
    let home = env::crux_home().unwrap_or_default();
    let readme = docs.join("repos").join(&repo).join(names::README);
    if let Err(e) = template::render_to(
        &home.join("templates/repo-doc/README.md"),
        &readme,
        &[("REPO", &repo), ("PROJECT", &project_name), ("DESCRIPTION", &description)],
    ) {
        die!("cannot write {}: {e}", readme.display());
    }
    ui::ok(format!("created repos/{repo}/README.md"));

    let obj = contract.as_object_mut().unwrap();
    let repos = obj.entry("repos").or_insert_with(|| json!([]));
    if let Some(a) = repos.as_array_mut() {
        if !a.iter().any(|v| v.as_str() == Some(&repo)) {
            a.push(json!(repo));
        }
    }
    if let Err(e) = project::write_contract(&docs, &contract) {
        die!("cannot write {}: {e}", config.display());
    }
    ui::ok("declared in crux.json");

    // If the repo already has an origin the contract template does not
    // compose, clone would not know where to fetch it from.
    let repo_dir = root.join(&repo);
    if repo_dir.join(".git").is_dir() {
        let origin = git::remote_url(&repo_dir, "origin").unwrap_or_default();
        let expected = project::remote_url(&contract, &repo).unwrap_or_default();
        if !origin.is_empty() && origin != expected {
            let obj = contract.as_object_mut().unwrap();
            let remote = obj.entry("remote").or_insert_with(|| json!({}));
            if !remote.is_object() {
                *remote = json!({});
            }
            let r = remote.as_object_mut().unwrap().entry("repos").or_insert_with(|| json!({}));
            if !r.is_object() {
                *r = json!({});
            }
            r.as_object_mut().unwrap().insert(repo.clone(), Value::String(origin.clone()));
            if let Err(e) = project::write_contract(&docs, &contract) {
                die!("cannot write {}: {e}", config.display());
            }
            ui::ok(format!("remote taken from its origin: {origin}"));
        }
    }

    // The table in repos/README.md is the index a human reads; it maintains
    // itself while it exists, and if the project deleted it, it is not
    // reinvented.
    let index = docs.join("repos/README.md");
    if !index.exists() {
        ui::warn(format!("there is no repos/README.md — {repo} is declared, without a row in an index"));
    } else {
        let text = match std::fs::read_to_string(&index) {
            Ok(t) => t,
            Err(e) => die!("repos/README.md cannot be read: {e}"),
        };
        let has_table = crate::regex!(r"(?m)^\| *(Carpeta|Folder)").is_match(&text);
        let mut lines: Vec<String> = text.split('\n').map(String::from).collect();
        match lines.iter().rposition(|l| l.starts_with('|')).filter(|_| has_table) {
            None => ui::warn("repos/README.md has no table — register it by hand"),
            Some(last) => {
                let row = format!("| `{repo}/` | `{project_name}/{repo}` | {} |", description.replace('|', "\\|"));
                let empty_row = crate::regex!(r"^\|\s*\|\s*\|\s*\|\s*$");
                match lines.iter().enumerate().position(|(i, l)| i <= last && empty_row.is_match(l)) {
                    Some(e) => lines[e] = row,
                    None => lines.insert(last + 1, row),
                }
                if let Err(e) = std::fs::write(&index, lines.join("\n")) {
                    die!("repos/README.md cannot be written: {e}");
                }
                ui::ok("registered in repos/README.md");
            }
        }
    }
    println!();
    super::call("link", &[&docs.to_string_lossy()]);
    println!();
    ui::info(format!("suggested commit: docs(repos): add {repo}"));

    // The pointers written into the code repo only reach the workspaces once
    // committed: a workspace branches from the main branch, not from the files
    // lying around in the checkout.
    if repo_dir.join(".git").is_dir() {
        let pending: Vec<String> = git::out(&repo_dir, &["status", "--porcelain", "--", names::AGENTS, names::CLAUDE])
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.split_whitespace().nth(1).map(String::from))
            .collect();
        if !pending.is_empty() {
            ui::info(format!(
                "and in {repo}: commit {}, or the workspaces, which branch from {}, will not have them",
                pending.join(" "),
                project::main_branch(&repo_dir)
            ));
        }
    }
    Ok(())
}
