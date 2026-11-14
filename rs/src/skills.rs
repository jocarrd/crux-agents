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
        if target.is_dir() && target.symlink_metadata().is_ok_and(|m| !m.file_type().is_symlink()) {
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

/// A project's skills, and every folder their links may point into: the docs
/// repo's and each of its worktrees'.
pub struct ProjectSkills {
    skills: Vec<PathBuf>,
    roots: Vec<PathBuf>,
    kernel: Vec<String>,
}

impl ProjectSkills {
    pub fn of(docs: &Path) -> Self {
        let source = docs.join(names::CLAUDE_SKILLS);
        // The links left next to the sources are not skills of their own.
        let skills: Vec<PathBuf> = find(&source)
            .into_iter()
            .filter(|p| p.symlink_metadata().is_ok_and(|m| !m.file_type().is_symlink()))
            .collect();
        let mut roots: Vec<PathBuf> =
            crate::git::worktrees(docs).iter().map(|w| w.join(names::CLAUDE_SKILLS)).collect();
        if roots.is_empty() {
            roots.push(source);
        }
        let kernel = env::crux_home()
            .map(|h| find(&h.join("skills")).iter().map(|k| crate::files::name(k)).collect())
            .unwrap_or_default();
        ProjectSkills { skills, roots, kernel }
    }

    fn ours(&self, link: &Path) -> bool {
        fs::read_link(link).is_ok_and(|t| self.roots.iter().any(|r| t.starts_with(r)))
    }

    /// Links them into one repo, or into the worktree of a workspace, which
    /// does not get what git ignores on its own. What the repo has under the
    /// same name —a folder, a versioned file, a link of its own— is left alone,
    /// and links of ours to a skill that no longer exists are removed.
    pub fn link_into(&self, repo: &Path) {
        if env::dry_run() {
            println!("      [dry-run] claude: {} project skills in {}", self.skills.len(), repo.display());
            return;
        }
        let dir = repo.join(names::CLAUDE_SKILLS);
        let tracked: Vec<String> = crate::git::out(repo, &["ls-files", "--", names::CLAUDE_SKILLS])
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect();
        let is_tracked = |name: &str| tracked.iter().any(|t| t == &format!("{}/{name}", names::CLAUDE_SKILLS));
        let wanted: Vec<String> = self.skills.iter().map(|s| crate::files::name(s)).collect();
        for e in fs::read_dir(&dir).map(|e| e.flatten().collect::<Vec<_>>()).unwrap_or_default() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !wanted.contains(&name) && self.ours(&e.path()) && !is_tracked(&name) {
                let _ = fs::remove_file(e.path());
            }
        }
        let mut linked: Vec<String> = vec![];
        for (skill, name) in self.skills.iter().zip(&wanted) {
            // The global catalog wins over a repo's, so this one would be hidden.
            if self.kernel.contains(name) {
                crate::ui::warn(format!(
                    "skill '{name}' is already shipped by the kernel: the project's is not offered"
                ));
                continue;
            }
            let target = dir.join(name);
            if target.symlink_metadata().is_ok() && (!self.ours(&target) || is_tracked(name)) {
                continue;
            }
            if fs::create_dir_all(&dir).is_err() {
                crate::ui::warn(format!(
                    "{} cannot be created: the project's skills are not offered there",
                    dir.display()
                ));
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
    fn forget_global_links(&self) {
        let Ok(entries) = fs::read_dir(env::claude_skills_dir()) else { return };
        for e in entries.flatten() {
            if self.ours(&e.path()) && !env::dry_run() {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}

/// A project's skills, offered only where its sessions open: a link in each
/// of its repos' `.claude/skills/`, kept out of git, instead of the global
/// catalog every other project loads. Codex has a single global catalog, so
/// it keeps its stubs.
pub fn materialize_for_project(docs: &Path, label: &str, repos: &[PathBuf]) {
    let project = ProjectSkills::of(docs);
    for skill in &project.skills {
        codex_stub(skill, &crate::files::name(skill));
    }
    for repo in repos {
        project.link_into(repo);
    }
    project.forget_global_links();
    if !project.skills.is_empty() {
        let label = if label.is_empty() { String::new() } else { format!(" ({label})") };
        println!("      {} skills{label}, in {} repos", project.skills.len(), repos.len());
    }
}

/// Only broken links and stubs pointing at a SKILL.md that no longer exists.
pub fn prune() {
    let dir = env::claude_skills_dir();
    let Ok(entries) = fs::read_dir(&dir) else { return };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let link = e.path();
        if link.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) && !link.exists() {
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
