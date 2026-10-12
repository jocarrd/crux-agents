//! crux adopt — registers an existing docs repo under the standard.
//!
//! It rewrites nothing that is already there: it detects the project and its
//! repos, writes the missing crux.json and lets 'crux doctor' say what is left
//! to align. It is the entry point for projects that predate the kernel.
//!
//!   crux adopt [dir] [--profile <profile>]

use crate::args::Parser;
use crate::error::Res;
use crate::{die, env, git, policy, project, ui};
use std::path::PathBuf;

pub fn run(argv: &[String]) -> Res {
    let mut target = std::env::current_dir().unwrap_or_default();
    let mut profile = String::new();
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--profile" => profile = p.value(),
            other => target = PathBuf::from(other),
        }
    }
    let Some(docs) = project::resolve_dir(&target) else { die!("cannot enter {}", target.display()) };
    let docs_name = docs.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if !docs_name.ends_with("-docs") {
        die!("{} does not look like a docs repo (it must be named <project>-docs)", docs.display());
    }
    let project_name = docs_name.trim_end_matches("-docs").to_string();
    let root = docs.parent().unwrap().to_path_buf();
    if project::contract_file(&docs).is_file() {
        die!("{project_name} is already adopted — use 'crux doctor' or 'crux upgrade'");
    }
    if profile.is_empty() {
        profile = "multi-repo".into();
    }
    if !policy::exists(&profile, Some(&target)) {
        die!("unknown profile: {profile}");
    }

    // Repos: those that already have a documentation folder.
    let repos = project::subdirs(&docs.join("repos"));
    // Siblings without a doc folder are reported, not added: they might not
    // belong to the project.
    let orphans: Vec<String> =
        project::subdirs(&root).into_iter().filter(|n| *n != docs_name && !repos.contains(n)).collect();
    let sections: Vec<&str> =
        ["architecture", "conventions", "operations", "topics"].into_iter().filter(|s| docs.join(s).is_dir()).collect();

    // The remote is deduced from what is already cloned: the docs repo
    // template, and an override for each repo whose origin does not fit it.
    // That lets a project with its code in another account —a client repo—
    // be declared correctly from the start.
    let tmpl = project::remote_from_git(&docs).unwrap_or_default();
    let mut overrides = String::new();
    for repo in &repos {
        let dir = root.join(repo);
        if !dir.join(".git").is_dir() {
            continue;
        }
        let Some(url) = git::remote_url(&dir, "origin") else { continue };
        if url == tmpl.replace("{repo}", repo) {
            continue;
        }
        overrides.push_str(&format!("\n      \"{repo}\": \"{url}\","));
    }
    let overrides = overrides.strip_suffix(',').unwrap_or(&overrides).to_string();
    let remote_json = if !tmpl.is_empty() {
        let repos_part =
            if overrides.is_empty() { String::new() } else { format!(",\n    \"repos\": {{{overrides}\n    }}") };
        format!("  \"remote\": {{\n    \"url\": \"{tmpl}\"{repos_part}\n  }},")
    } else if !overrides.is_empty() {
        // Without a remote on the docs repo there is no template, but the code
        // repos that have one are declared anyway: otherwise clone could not
        // fetch any.
        format!("  \"remote\": {{\n    \"repos\": {{{overrides}\n    }}\n  }},")
    } else {
        String::new()
    };
    // An empty list must stay empty: [""] is a nameless repo that every
    // command would then try to walk.
    let list =
        |v: &[String]| v.iter().filter(|x| !x.is_empty()).map(|x| format!("\"{x}\"")).collect::<Vec<_>>().join(", ");
    let sections_owned: Vec<String> = sections.iter().map(|s| s.to_string()).collect();
    let text = format!(
        "{{\n  \"crux\": \"{}\",\n  \"project\": \"{project_name}\",\n  \"profile\": \"{profile}\",\n  \"language\": \"es\",\n{remote_json}\n  \"repos\": [{}],\n  \"sections\": [{}],\n  \"conventions\": {{\n    \"checks\": []\n  }}\n}}\n",
        env::crux_version(),
        list(&repos),
        list(&sections_owned)
    );
    if let Err(e) = std::fs::write(project::contract_file(&docs), text) {
        die!("cannot write {}: {e}", project::contract_file(&docs).display());
    }
    ui::ok(format!("written {project_name}-docs/crux.json"));
    ui::info(format!("profile {profile} · {} repos · {} sections", repos.len(), sections.len()));
    if !orphans.is_empty() {
        println!();
        ui::warn("siblings on disk without a folder in repos/ (not declared):");
        for o in &orphans {
            ui::info(format!("{o} — if it belongs to the project: /add-repo-to-docs {o}"));
        }
    }
    println!();
    // adopt writes the contract and touches nothing else, so a project that
    // predates the kernel leaves here without the mandatory structure.
    if super::call("doctor", &[&docs.to_string_lossy()]) != 0 {
        println!();
        ui::info("'crux upgrade' restores whatever is missing without overwriting what is there");
    }
    Ok(())
}
