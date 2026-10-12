//! crux upgrade — aligns a docs repo with the current kernel version.
//!
//! Materializes the pieces of the standard that are missing (those a new
//! version has added) and updates the version declared in crux.json. It does
//! not overwrite existing content unless --force: the documentation belongs to
//! the project, the templates only fill gaps.
//!
//!   crux upgrade [dir] [--force] [--dry-run]

use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, files, project, template, ui};
use serde_json::json;
use std::path::PathBuf;

pub fn run(argv: &[String]) -> Res {
    let mut target = std::env::current_dir().unwrap_or_default();
    let (mut force, mut dry) = (false, false);
    for a in argv {
        match a.as_str() {
            "--force" => force = true,
            "--dry-run" => dry = true,
            other => target = PathBuf::from(other),
        }
    }
    let Some(docs) = project::find_docs_repo(&target) else {
        die!("cannot find a docs repo from {}", target.display())
    };
    if !project::contract_file(&docs).is_file() {
        die!("crux.json is missing — run 'crux adopt' first");
    }
    let mut contract = match project::read_contract(&docs) {
        Ok(c) => c,
        Err(e) => die!("crux.json cannot be read: {e}"),
    };
    let project_name = files::get_str(&contract, "project").unwrap_or_default();
    let from = files::get_str(&contract, "crux").unwrap_or_default();
    let to = env::crux_version();
    println!("{project_name}: crux {from} → {to}");
    if dry {
        ui::warn("dry-run: nothing is written");
    }
    println!();

    // Downgrading the contract on the machine that has the old kernel leaves
    // the project declaring less than what it already has materialized. And
    // "cannot compare" is not "is not greater": a kernel without VERSION would
    // write "crux": "unknown" into the contract.
    if !project::is_semver(&to) {
        ui::err(format!("this kernel does not declare a valid version: '{to}'"));
        ui::info("reinstall it from the kernel repo: bash install.sh");
        return exit(1);
    }
    if !project::is_semver(&from) {
        ui::err(format!("the project declares a version that cannot be compared: '{from}'"));
        ui::info("fix \"crux\" in crux.json before upgrading");
        if !force {
            return exit(1);
        }
    }
    if project::version_greater_than(&from, &to) {
        ui::err(format!("the project declares crux {from} and this kernel is {to}"));
        ui::info(format!(
            "update the kernel ('git pull' in {}) instead of downgrading the contract",
            env::crux_home().unwrap_or_default().display()
        ));
        ui::info("if you really want to lower it: crux upgrade --force");
        if !force {
            return exit(1);
        }
    }

    let templates = env::crux_home().unwrap_or_default().join("templates/docs-repo");
    let mut added = 0;
    for src in project::files_under(&templates) {
        let rel = src.strip_prefix(&templates).unwrap().to_string_lossy().into_owned();
        let dst = match rel.as_str() {
            "gitignore" => docs.join(".gitignore"),
            "gitattributes" => docs.join(".gitattributes"),
            _ => docs.join(&rel),
        };
        if dst.exists() && !force {
            continue;
        }
        if dry {
            println!("      [dry-run] would materialize {rel}");
        } else {
            let description = files::get_str(&contract, "description")
                .unwrap_or_else(|| format!("Cross-cutting documentation for {project_name}."));
            if let Err(e) =
                template::render_to(&src, &dst, &[("PROJECT", &project_name), ("DESCRIPTION", &description)])
            {
                die!("cannot write {}: {e}", dst.display());
            }
            ui::ok(format!("materialized {rel}"));
        }
        added += 1;
    }
    // A matching version does not guarantee that all pieces are there: adopt
    // writes the current version over a repo without the structure.
    if added == 0 {
        ui::ok("no piece of the standard is missing");
    }
    // CLAUDE.md is a symlink, not a template.
    if !dry && docs.join(names::AGENTS).is_file() && docs.join(names::CLAUDE).symlink_metadata().is_err() {
        let _ = std::os::unix::fs::symlink(names::AGENTS, docs.join(names::CLAUDE));
        ui::ok("materialized CLAUDE.md");
    }
    if !dry {
        contract.as_object_mut().unwrap().insert("crux".into(), json!(to));
        if let Err(e) = project::write_contract(&docs, &contract) {
            die!("cannot write crux.json: {e}");
        }
        ui::ok(format!("crux.json updated to {to}"));
    }
    println!();
    if !dry {
        let code = super::call("doctor", &[&docs.to_string_lossy()]);
        if code != 0 {
            return exit(code);
        }
    }
    Ok(())
}
