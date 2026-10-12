//! crux link — generates and checks the context pointers of the project's
//! code repos, and materializes their own skills.
//!
//! Everything comes from crux.json: no project names or repo lists are
//! hardcoded. The profile decides whether anything is written to code repos.

use crate::error::Res;
use crate::names;
use crate::template::{LocalPointer, Managed, LOCAL_POINTER};
use crate::{die, env, files, git, policy, project, skills, template, ui};
use std::path::{Path, PathBuf};

/// Each repo's one-line description lives in the repos/README.md table, its
/// canonical source. Without it the pointer loses the only useful thing it
/// said about the repo.
fn tagline_of(docs: &Path, repo: &str, project_name: &str) -> String {
    let text = std::fs::read_to_string(docs.join("repos/README.md")).unwrap_or_default();
    for l in text.split('\n').filter(|l| l.starts_with('|')) {
        let c: Vec<&str> = l.split('|').map(str::trim).collect();
        if c.get(1).map(|x| x.replace(['`', '/'], "")).as_deref() == Some(repo) {
            let t = c.get(3).copied().unwrap_or("");
            if !t.is_empty() {
                return t.to_string();
            }
            break;
        }
    }
    format!("part of {project_name}")
}

/// The profile's rules, written into a managed block that doctor checks. The
/// old block was marked `perfil`: still recognised and replaced.
fn write_profile_rules(profile: &str, docs: &Path, tree: &Path) -> Result<(), String> {
    let Some(rules) = policy::get(profile, Some(docs), "rules").filter(|r| !r.is_empty()) else { return Ok(()) };
    let mut block = format!(
        "<!-- crux:begin profile -->\n## Rules of the `{profile}` profile\n\nThe profile declares them, and `crux doctor` checks they are written here.\nFollowing them is up to whoever does the work: they are working rules, not\nautomatic checks.\n\n"
    );
    for r in rules.lines().filter(|r| !r.is_empty()) {
        block.push_str(&format!("- {r}\n"));
    }
    block.push_str("\n<!-- crux:end -->");
    let target = tree.join(names::AGENTS);
    let Ok(current) = std::fs::read_to_string(&target) else { return Ok(()) };
    let re = crate::regex!(r"<!-- crux:begin (?:perfil|profile)[\s\S]*?crux:end -->");
    if let Some(m) = re.find(&current) {
        if m.as_str() != block {
            crate::files::write(&target, &re.replacen(&current, 1, regex::NoExpand(&block)))?;
            ui::ok(format!("profile {profile} rules updated in AGENTS.md"));
        }
    } else {
        crate::files::write(&target, &format!("{current}\n{block}\n"))?;
        ui::ok(format!("profile {profile} rules written to AGENTS.md"));
    }
    Ok(())
}

/// The first sentence of a skill's description: an index is scanned, not read.
pub fn catalog_line(skill: &Path) -> String {
    let name = skill.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let text = std::fs::read_to_string(skill.join(names::SKILL)).unwrap_or_default();
    let mut fences = 0;
    let mut line = String::new();
    for l in text.lines() {
        if l == "---" {
            fences += 1;
            continue;
        }
        if fences == 1 {
            if let Some(d) = l.strip_prefix("description:") {
                line = d.strip_prefix(' ').unwrap_or(d).to_string();
                break;
            }
        }
    }
    let cut = line.split('.').next().unwrap_or("");
    let cut = cut.split(':').next().unwrap_or("");
    let cut = if cut.chars().count() > 78 {
        format!("{}…", cut.chars().take(75).collect::<String>())
    } else {
        cut.to_string()
    };
    format!("- `{name}` — {cut}")
}

pub fn run(argv: &[String]) -> Res {
    let mut refresh = false;
    let mut target = std::env::current_dir().unwrap_or_default();
    for a in argv {
        if a == "--refresh" {
            refresh = true;
        } else {
            target = PathBuf::from(a);
        }
    }
    let Some(docs) = project::find_docs_repo(&target) else { die!("no docs repo found from {}", target.display()) };
    let config = project::contract_file(&docs);
    if !config.is_file() {
        die!("{} is missing — run 'crux adopt' first", config.display());
    }
    let contract = match project::read_contract(&docs) {
        Ok(c) => c,
        Err(e) => die!("{} cannot be read: {e}", config.display()),
    };
    let project_name = files::get_str(&contract, "project").unwrap_or_default();
    let profile = files::get_str(&contract, "profile").unwrap_or_default();
    let docs_name = files::name(&docs);
    let root = docs.parent().unwrap().to_path_buf();
    let home = env::crux_home().unwrap_or_default();

    // The contract is read from the main checkout, but what is written into
    // the docs repo goes to the tree link was run from when that tree is a
    // worktree of it, so running it from a workspace writes to the workspace.
    let mut tree = docs.clone();
    if let Some(top) = git::toplevel(&target) {
        if top != docs && git::common_dir(&target).is_some() && git::common_dir(&target) == git::common_dir(&docs) {
            tree = top;
        }
    }
    println!("project {project_name} · profile {profile}");
    println!();
    if let Err(e) = write_profile_rules(&profile, &docs, &tree) {
        die!("{e}");
    }

    let repos = files::str_list(contract.get("repos"));
    if !policy::flag(&profile, Some(&docs), "pointers.write", true) {
        if !policy::flag(&profile, Some(&docs), "pointers.local", false) {
            ui::warn(format!("profile {profile}: nothing is written outside the docs repo"));
            ui::info(format!("agents must open {docs_name}/AGENTS.md explicitly"));
        } else {
            ui::info(format!(
                "profile {profile}: nothing versioned outside the docs repo; only the local pointer {LOCAL_POINTER}"
            ));
            for repo in repos.iter().filter(|r| !r.is_empty()) {
                if !project::valid_name(repo) {
                    ui::warn(format!("invalid repo name in the contract: {repo}"));
                    continue;
                }
                let dir = root.join(repo);
                if !dir.is_dir() {
                    ui::warn(format!("declared in crux.json but not on disk: {repo}"));
                    continue;
                }
                match template::write_local_pointer(&dir, &docs_name) {
                    Ok(LocalPointer::Written) => {
                        ui::ok(format!("{repo}/{LOCAL_POINTER} points to {docs_name} (excluded from git)"))
                    }
                    Ok(LocalPointer::NotARepo) => ui::warn(format!(
                        "{repo} is not a git repo: no local pointer, there would be no way to exclude it"
                    )),
                    Ok(LocalPointer::Versioned) => {
                        ui::info(format!("{repo} versions its own {LOCAL_POINTER} — respected, not touched"))
                    }
                    Err(e) => ui::warn(format!("{repo}: {e}")),
                }
            }
        }
    } else {
        let (mut created, mut updated, mut seen) = (0, 0, 0);
        let mut without_markers: Vec<(String, String)> = vec![];
        for repo in repos.iter().filter(|r| !r.is_empty()) {
            if !project::valid_name(repo) {
                ui::warn(format!("invalid repo name in the contract: {repo}"));
                continue;
            }
            let dir = root.join(repo);
            if !dir.is_dir() {
                ui::warn(format!("declared in crux.json but not on disk: {repo}"));
                continue;
            }
            seen += 1;
            let tagline = tagline_of(&docs, repo, &project_name);
            for file in [names::AGENTS, names::CLAUDE] {
                let vars = [
                    ("REPO", repo.as_str()),
                    ("PROJECT", project_name.as_str()),
                    ("DOCS", docs_name.as_str()),
                    ("TAGLINE", tagline.as_str()),
                ];
                match template::render_managed(&home.join("templates/code-repo").join(file), &dir.join(file), &vars) {
                    Ok(Managed::Created) => {
                        ui::ok(format!("created {repo}/{file}"));
                        created += 1;
                    }
                    Ok(Managed::Updated) => {
                        ui::ok(format!("updated the block of {repo}/{file}"));
                        updated += 1;
                    }
                    Ok(Managed::Unchanged) => {}
                    Ok(Managed::Foreign) => without_markers.push((repo.clone(), file.to_string())),
                    Ok(Managed::TemplateWithoutBlock) => die!("the kernel's {file} template has no managed block"),
                    Err(e) => die!("cannot write {repo}/{file}: {e}"),
                }
            }
        }
        if !without_markers.is_empty() {
            println!();
            if refresh {
                for (repo, file) in &without_markers {
                    let path = root.join(repo).join(file);
                    let text = std::fs::read_to_string(&path).unwrap_or_default();
                    let mut lines: Vec<&str> = text.lines().collect();
                    if lines.first().is_some_and(|l| l.starts_with("# ")) {
                        lines.remove(0);
                    }
                    let own = lines.join("\n").trim_end_matches('\n').to_string();
                    let tagline = tagline_of(&docs, repo, &project_name);
                    let vars = [
                        ("REPO", repo.as_str()),
                        ("PROJECT", project_name.as_str()),
                        ("DOCS", docs_name.as_str()),
                        ("TAGLINE", tagline.as_str()),
                    ];
                    let rendered =
                        template::render(&home.join("templates/code-repo").join(file), &vars).unwrap_or_default();
                    if let Err(e) =
                        crate::files::write(&path, &format!("{rendered}\n---\n\n## Own context of {repo}\n\n{own}\n"))
                    {
                        die!("{e}");
                    }
                    ui::ok(format!("{repo}/{file} rewritten with the block, previous content kept below"));
                }
            } else {
                ui::warn("these pointers predate the managed block:");
                for (repo, file) in &without_markers {
                    ui::info(format!("{repo}/{file}"));
                }
                ui::info("'crux link --refresh' rewrites them keeping their content below");
            }
        }
        if seen == 0 {
            ui::info("no code repo on disk yet");
        } else if created + updated == 0 && without_markers.is_empty() {
            ui::ok(format!("pointers up to date ({})", ui::count(seen, "repo", "repos")));
        }
    }

    // The kernel's skill catalog in the project index fills itself in if
    // AGENTS.md marks the spot: a list kept by hand goes stale as the kernel
    // grows, and an index that lies is worse than none.
    let index = tree.join(names::AGENTS);
    if let Ok(src) = std::fs::read_to_string(&index) {
        if src.contains("<!-- crux:skills -->") {
            let lines: Vec<String> = project::subdirs(&home.join("skills"))
                .iter()
                .map(|n| catalog_line(&home.join("skills").join(n)))
                .collect();
            let catalog = lines.join("\n");
            let re = crate::regex!(r"<!-- crux:skills -->[\s\S]*?<!-- /crux:skills -->");
            let replaced = re
                .replacen(&src, 1, regex::NoExpand(&format!("<!-- crux:skills -->\n{catalog}\n<!-- /crux:skills -->")))
                .into_owned();
            if let Err(e) = crate::files::write(&index, &replaced) {
                die!("{e}");
            }
            ui::ok(format!("kernel catalog updated in AGENTS.md ({} skills)", lines.len()));
        }
    }

    println!();
    skills::materialize(&tree.join(".claude/skills"), &project_name);
    skills::prune();
    ui::ok("project skills materialized");
    Ok(())
}
