//! The person's profile: a repo of its own next to the projects with how they
//! want to work and who they are. Markdown that belongs to no agent: each
//! adapter loads it in its own place. See ADR-018.

use crate::names;
use crate::{env, template};
use std::path::{Path, PathBuf};

pub fn repo_name() -> String {
    env::preference(crate::names::vars::PROFILE_REPO, "agent-profile")
}

/// The profile is the person's, not a scope's: it lives in the primary root
/// wherever the command runs (ADR-025).
pub fn expected_dir() -> PathBuf {
    let root = match crate::scope::load() {
        Ok(s) if s.declared => s.primary().root.clone(),
        _ => env::implicit_projects_root(),
    };
    root.join(repo_name())
}

/// The profile's directory, if this machine has one.
pub fn dir() -> Option<PathBuf> {
    let d = expected_dir();
    d.join("PROFILE.md").is_file().then_some(d)
}

/// A value of PROFILE.md's frontmatter.
pub fn field(dir: &Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("PROFILE.md")).ok()?;
    let mut lines = text.lines();
    if lines.next()? != "---" {
        return None;
    }
    let prefix = format!("{key}:");
    for l in lines {
        if l == "---" {
            return None;
        }
        if let Some(rest) = l.strip_prefix(&prefix) {
            let v = rest.trim_start_matches([' ', '\t']);
            if v.len() >= 2 && v.starts_with('"') && v.ends_with('"') {
                return Some(v[1..v.len() - 1].replace("\\\"", "\""));
            }
            return Some(v.to_string());
        }
    }
    None
}

/// This machine's note, if the profile has one: by its full hostname, and
/// failing that by its short name. macOS builds the hostname from the network
/// when none is set, so a note named after it stopped loading on another one.
pub fn machine_note(dir: &Path) -> Option<PathBuf> {
    [env::hostname(), env::machine()]
        .into_iter()
        .filter(|n| !n.is_empty())
        .map(|n| dir.join(format!("machines/{n}.md")))
        .find(|note| note.is_file())
}

const BEGIN: &str = "<!-- crux:profile:begin -->";
const END: &str = "<!-- crux:profile:end -->";

/// Claude reads ~/.claude/CLAUDE.md in any project. With an import, not a
/// copy: what changes in the profile is read as it is in the next session.
pub fn load_into_claude(dir: Option<&Path>, note: Option<&Path>) -> std::io::Result<PathBuf> {
    let file = env::claude_config_dir().join(names::CLAUDE);
    let block = match dir {
        Some(d) => {
            let mut b = format!(
                "{BEGIN}\nThe person's profile lives in {} (paths in its index are relative to it).\n\n@{}/PROFILE.md",
                d.display(),
                d.display()
            );
            if let Some(n) = note {
                b.push_str(&format!("\n@{}", n.display()));
            }
            b.push_str(&format!("\n{END}"));
            b
        }
        None => String::new(),
    };
    if env::dry_run() {
        println!("      [dry-run] claude: profile in {}", file.display());
        return Ok(file);
    }
    template::write_marked_block(&file, BEGIN, END, &block)?;
    Ok(file)
}

/// Whether a note may be read outside the person's own scope (ADR-025). What
/// the note says wins; without a word, who the person is (`about/`) and what
/// a machine holds (`machines/`) stay private, and how they want to work is
/// shared.
pub fn is_shared(dir: &Path, rel: &str) -> bool {
    // A note that cannot be read is not known to be shareable.
    let Some(text) = crate::files::read_optional(&dir.join(rel)) else { return false };
    let mut lines = text.lines();
    if lines.next() == Some("---") {
        for l in lines.by_ref() {
            if l == "---" {
                break;
            }
            if let Some(v) = l.trim().strip_prefix("visibility:") {
                return v.trim().trim_matches('"') == "shared";
            }
        }
    }
    // macOS folders ignore case: `About/x.md` is `about/x.md`.
    let rel = rel.to_lowercase();
    !(rel.starts_with("about/") || rel.starts_with("machines/"))
}

/// The index without the lines that lead to a private note, nor the
/// frontmatter. What a scope that only sees what is shared gets.
pub fn shared_index(dir: &Path) -> String {
    let text = crate::files::read_or_empty(&dir.join("PROFILE.md"));
    let link = crate::regex!(r"\]\(([^)#\s]+\.md)(#[^)]*)?\)");
    without_frontmatter(&text)
        .lines()
        .filter(|l| link.captures_iter(l).all(|c| is_shared(dir, &c[1])))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Where the shared index is kept: generated, so it lives with the machine's
/// state, never in the profile repo.
pub fn shared_index_file() -> PathBuf {
    env::state_dir().join("person").join("shared.md")
}

/// With scopes declared the global file imports nothing of the profile: each
/// root imports what its scope may see, and Claude reads a root's CLAUDE.md
/// for every session under it, workspaces included.
pub fn load_into_scopes(dir: &Path, note: Option<&Path>, all: &crate::scope::Scopes) -> std::io::Result<Vec<PathBuf>> {
    let shared = shared_index_file();
    if let Some(d) = shared.parent() {
        crate::files::mkdir_private(d)?;
    }
    let mut text = format!(
        "# The person's profile, shared part\n\nGenerated from {}/PROFILE.md by `crux profile link`; edit that.\n\n{}\n",
        dir.display(),
        shared_index(dir)
    );
    if let Some(n) = note.filter(|n| is_shared(dir, &format!("machines/{}", crate::files::name(n)))) {
        text.push_str(&format!("\n{}\n", without_frontmatter(&crate::files::read_or_empty(n))));
    }
    crate::files::write(&shared, &text).map_err(std::io::Error::other)?;
    template::write_marked_block(&env::claude_config_dir().join(names::CLAUDE), BEGIN, END, "")?;
    let mut written = vec![];
    for s in &all.list {
        let file = s.root.join(names::CLAUDE);
        // Only the shared part, even in the person's own root: a root's file
        // reaches every project under it, an isolated one too, and Claude
        // cannot be told to skip a parent's. The full index arrives with the
        // session's context where the scope and the project allow it.
        let block = match s.person {
            crate::scope::Person::None => String::new(),
            _ => format!("{BEGIN}\n@{}\n{END}", shared.display()),
        };
        if !s.root.is_dir() {
            continue;
        }
        template::write_marked_block(&file, BEGIN, END, &block)?;
        written.push(file);
    }
    Ok(written)
}

/// Every project on this machine, by folder: what has a docs repo next to it
/// in any root. Neither the profile repo nor the kernel's own clone count: one
/// is the person's, the other the tool they work with, and a preference about
/// how to use it is still theirs.
pub fn known_projects() -> Vec<String> {
    let profile = repo_name();
    let mut out: Vec<String> = env::all_projects_roots()
        .iter()
        .flat_map(|root| {
            let kernel = env::kernel_clone(root).and_then(|k| {
                k.strip_prefix(root)
                    .ok()
                    .and_then(|r| r.components().next())
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
            });
            crate::project::subdirs(root)
                .into_iter()
                .filter(|n| *n != profile && Some(n) != kernel.as_ref())
                .filter(|n| !n.contains("-ws-") && root.join(n).join(format!("{n}-docs")).is_dir())
                .collect::<Vec<_>>()
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

/// The projects a text names: by their folder name as a word, and a long
/// name also written apart (`lariojameteo` as "La Rioja Meteo").
pub fn projects_named_in(text: &str, projects: &[String]) -> Vec<String> {
    let lower = text.to_lowercase();
    let squeezed: String = lower.chars().filter(|c| c.is_alphanumeric()).collect();
    projects
        .iter()
        .filter(|p| {
            let p = p.to_lowercase();
            // A short name like `web` is an ordinary word: it would claim
            // every correction that mentions one.
            if p.chars().count() < 4 {
                return false;
            }
            let word = regex::Regex::new(&format!(r"(^|[^a-z0-9]){}($|[^a-z0-9])", regex::escape(&p)))
                .is_ok_and(|r| r.is_match(&lower));
            let flat: String = p.chars().filter(|c| c.is_alphanumeric()).collect();
            word || (flat.len() >= 6 && squeezed.contains(&flat))
        })
        .cloned()
        .collect()
}

/// Notes in `preferences/` that name a project. A preference is how the person
/// works anywhere; a rule of one project is that project's convention and goes
/// to its docs repo. Routing memories by their type alone sent every
/// correction there, project rules included.
pub fn preferences_naming_projects(dir: &Path) -> Vec<(String, Vec<String>)> {
    let projects = known_projects();
    let mut out = vec![];
    for f in crate::project::files_under(&dir.join("preferences")) {
        if f.extension().is_none_or(|e| e != "md") {
            continue;
        }
        let named = projects_named_in(&crate::files::read_or_empty(&f), &projects);
        if !named.is_empty() {
            out.push((format!("preferences/{}", crate::files::name(&f)), named));
        }
    }
    out
}

fn without_frontmatter(text: &str) -> String {
    let mut out = vec![];
    let mut fm = false;
    for (i, l) in text.lines().enumerate() {
        if i == 0 && l == "---" {
            fm = true;
            continue;
        }
        if fm && l == "---" {
            fm = false;
            continue;
        }
        if !fm {
            out.push(l);
        }
    }
    out.join("\n").trim_end_matches('\n').to_string()
}

/// Codex has no imports, so the index is copied between markers. The copy
/// goes stale when the profile changes: sync and `profile link` regenerate it.
pub fn load_into_codex(dir: Option<&Path>, note: Option<&Path>) -> std::io::Result<PathBuf> {
    let file = env::codex_home_dir().join(names::AGENTS);
    let block = match dir {
        Some(d) => {
            let index = std::fs::read_to_string(d.join("PROFILE.md"))?;
            let mut b = format!(
                "{BEGIN}\nThe person's profile lives in {} (paths in its index are relative to it).\n\n{}",
                d.display(),
                without_frontmatter(&index)
            );
            if let Some(n) = note {
                b.push_str(&format!("\n\n{}", without_frontmatter(&std::fs::read_to_string(n)?)));
            }
            b.push_str(&format!("\n{END}"));
            b
        }
        None => String::new(),
    };
    if env::dry_run() {
        println!("      [dry-run] codex: profile in {}", file.display());
        return Ok(file);
    }
    template::write_marked_block(&file, BEGIN, END, &block)?;
    Ok(file)
}
