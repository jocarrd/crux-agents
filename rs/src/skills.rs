//! Skills exposed to each agent. A skill is a directory with a SKILL.md
//! inside: neutral markdown, and each adapter decides how its agent finds it.
//!
//! - Claude discovers skills through their frontmatter: a link in
//!   ~/.claude/skills/ is enough.
//! - Codex has no skills directory, but has custom prompts: a stub that
//!   points at the kernel's SKILL.md, so one source serves both agents.

use crate::names;
use crate::{env, template};
use std::fs;
use std::path::{Path, PathBuf};

/// Every SKILL.md one or two levels below the root, sorted.
pub fn find(root: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let Ok(entries) = fs::read_dir(root) else { return out };
    for e in entries.flatten() {
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        if p.join(names::SKILL).is_file() {
            out.push(p.clone());
        }
        if let Ok(inner) = fs::read_dir(&p) {
            for i in inner.flatten() {
                let q = i.path();
                if q.is_dir() && q.join(names::SKILL).is_file() {
                    out.push(q);
                }
            }
        }
    }
    // By the path of their SKILL.md: the catalog comes out the same on every machine.
    out.sort_by_key(|p| p.join(names::SKILL).to_string_lossy().into_owned());
    out
}

fn claude_link(src: &Path, name: &str) {
    if env::dry_run() {
        println!("      [dry-run] claude: {name}");
        return;
    }
    let dir = env::claude_skills_dir();
    let _ = fs::create_dir_all(&dir);
    let target = dir.join(name);
    // A kernel skill is not replaced by a project's: the link is global, so
    // that project's /ship would run in all the others.
    if let Ok(current) = fs::read_link(&target) {
        let home = env::crux_home().unwrap_or_default();
        if current != src && current.starts_with(&home) && !src.starts_with(&home) {
            eprintln!("warning: skill '{name}' is already shipped by the kernel: not replaced by the project's");
            return;
        }
    }
    if target.symlink_metadata().is_ok() {
        if target.is_dir() && target.symlink_metadata().map(|m| !m.file_type().is_symlink()).unwrap_or(false) {
            // A real directory with that name is the person's: `ln -sfn` would
            // have put the link inside it.
            let _ = std::os::unix::fs::symlink(src, target.join(name));
            return;
        }
        let _ = fs::remove_file(&target);
    }
    let _ = std::os::unix::fs::symlink(src, &target);
}

fn codex_stub(src: &Path, name: &str) {
    let skill_md = src.join(names::SKILL);
    if !skill_md.is_file() {
        return;
    }
    if env::dry_run() {
        println!("      [dry-run] codex: {name}");
        return;
    }
    let dir = env::codex_prompts_dir();
    let _ = fs::create_dir_all(&dir);
    let written = crate::files::write(
        &dir.join(format!("{name}.md")),
        &format!(
            "Read and follow the procedure described in:\n\n{}\n\nApply it to the current task. User arguments (if any): $ARGUMENTS\n",
            skill_md.display()
        ),
    );
    if let Err(e) = written {
        crate::ui::warn(format!("{e} — Codex will not offer /{name}"));
    }
}

/// Accepts a flat skills directory and one with subcategories.
pub fn materialize(root: &Path, label: &str) {
    if !root.is_dir() {
        return;
    }
    let found = find(root);
    for skill in &found {
        let name = crate::files::name(skill);
        claude_link(skill, &name);
        codex_stub(skill, &name);
    }
    if !found.is_empty() {
        let label = if label.is_empty() { String::new() } else { format!(" ({label})") };
        println!("      {} skills{label}", found.len());
    }
}

/// A project's skills, offered only where its sessions open: a link in each
/// of its repos' `.claude/skills/`, kept out of git, instead of the global
/// catalog every other project loads. Codex has a single global catalog, so
/// it keeps its stubs.
pub fn materialize_for_project(root: &Path, label: &str, repos: &[PathBuf]) {
    if !root.is_dir() {
        return;
    }
    let found = project_skills(root);
    for skill in &found {
        codex_stub(skill, &crate::files::name(skill));
    }
    for repo in repos {
        link_into(repo, &found);
    }
    forget_global_links_into(root);
    if !found.is_empty() {
        let label = if label.is_empty() { String::new() } else { format!(" ({label})") };
        println!("      {} skills{label}, in {} repos", found.len(), repos.len());
    }
}

/// The links left next to the sources are not skills of their own.
pub fn project_skills(root: &Path) -> Vec<PathBuf> {
    find(root).into_iter().filter(|p| p.symlink_metadata().is_ok_and(|m| !m.file_type().is_symlink())).collect()
}

/// Links the skills into one repo, or into the worktree of a workspace,
/// which does not get what git ignores on its own.
pub fn link_into(repo: &Path, skills: &[PathBuf]) {
    if skills.is_empty() || env::dry_run() {
        return;
    }
    let dir = repo.join(names::CLAUDE_SKILLS);
    let mut linked: Vec<String> = vec![];
    for skill in skills {
        let name = crate::files::name(skill);
        let target = dir.join(&name);
        // What the repo already has under that name is its own.
        if target.symlink_metadata().is_ok_and(|m| !m.file_type().is_symlink()) {
            continue;
        }
        if fs::create_dir_all(&dir).is_err() {
            crate::ui::warn(format!("{} cannot be created: the project's skills are not offered there", dir.display()));
            return;
        }
        let _ = fs::remove_file(&target);
        if std::os::unix::fs::symlink(skill, &target).is_ok() {
            linked.push(format!("/{}/{name}", names::CLAUDE_SKILLS));
        }
    }
    let entries: Vec<&str> = linked.iter().map(String::as_str).collect();
    if let Err(e) = crate::git::exclude(repo, &entries) {
        crate::ui::warn(format!("{e} — the links to the project's skills could be committed"));
    }
}

/// Links an earlier version left in the global catalog.
fn forget_global_links_into(root: &Path) {
    let Ok(entries) = fs::read_dir(env::claude_skills_dir()) else { return };
    for e in entries.flatten() {
        let link = e.path();
        if fs::read_link(&link).is_ok_and(|t| t.starts_with(root)) && !env::dry_run() {
            let _ = fs::remove_file(&link);
        }
    }
}

/// Only broken links and stubs pointing at a SKILL.md that no longer exists.
pub fn prune() {
    let dir = env::claude_skills_dir();
    let Ok(entries) = fs::read_dir(&dir) else { return };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let link = e.path();
        if link.symlink_metadata().map(|m| m.file_type().is_symlink()).unwrap_or(false) && !link.exists() {
            if env::dry_run() {
                println!("      [dry-run] claude: prune {name}");
            } else {
                let _ = fs::remove_file(&link);
            }
        }
        let stub = env::codex_prompts_dir().join(format!("{name}.md"));
        if let Some(text) = crate::files::read_optional(&stub) {
            if let Some(target) = text.lines().find(|l| l.ends_with("/SKILL.md")) {
                if !Path::new(target).is_file() {
                    if env::dry_run() {
                        println!("      [dry-run] codex: prune {name}");
                    } else {
                        let _ = fs::remove_file(&stub);
                    }
                }
            }
        }
    }
}

/// Codex reads ~/.codex/AGENTS.md as global context: generated between
/// markers so it is regenerated without touching what the user wrote.
pub fn codex_global(crux_home: &Path) -> bool {
    let begin = "<!-- crux:begin -->";
    let end = "<!-- crux:end -->";
    let h = crux_home.display();
    let block = format!(
        "{begin}
# Work system (crux)

The documentation and agent work standard lives in:

  {h}/STANDARD.md

Rules that apply in any project:

- A project's documentation lives in its `<project>-docs` repo, never inside
  the code repo. A repo's specific documentation goes in `repos/<repo>/`.
- When changing code that affects a doc, update the doc in the same turn.
- Project notes and references go to git, not to local memory.
- Conventional commits, body lines of 100 characters, no emojis.
- Before working in a repo, read its `AGENTS.md` and the docs repo's.

The procedures available as `/<name>` are in
{h}/skills/ and in each project's docs repo.
{end}"
    );
    if env::dry_run() {
        println!("      [dry-run] codex: global AGENTS.md");
        return true;
    }
    let dir = env::codex_home_dir();
    let _ = fs::create_dir_all(&dir);
    if let Err(e) = template::replace_or_append_block(&dir.join(names::AGENTS), begin, end, &block) {
        crate::ui::warn(format!("{e} — Codex does not get the global context"));
        return false;
    }
    true
}
