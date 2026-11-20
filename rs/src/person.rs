//! The person's profile: a repo of its own next to the projects with how they
//! want to work and who they are. Markdown that belongs to no agent: each
//! adapter loads it in its own place. See ADR-018.

use crate::names;
use crate::{env, template};
use std::path::{Path, PathBuf};

pub fn repo_name() -> String {
    env::preference(crate::names::vars::PROFILE_REPO, "agent-profile")
}

pub fn expected_dir() -> PathBuf {
    env::projects_root().join(repo_name())
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

/// Every project on this machine, by folder: what has a docs repo next to it
/// in the projects root. Neither the profile repo nor the kernel's own clone
/// count: one is the person's, the other the tool they work with, and a
/// preference about how to use it is still theirs.
pub fn known_projects() -> Vec<String> {
    let root = env::projects_root();
    let profile = repo_name();
    let kernel = env::kernel_clone(&root).and_then(|k| {
        k.strip_prefix(&root)
            .ok()
            .and_then(|r| r.components().next())
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
    });
    let mut out: Vec<String> = crate::project::subdirs(&root)
        .into_iter()
        .filter(|n| *n != profile && Some(n) != kernel.as_ref())
        .filter(|n| !n.contains("-ws-") && root.join(n).join(format!("{n}-docs")).is_dir())
        .collect();
    out.sort();
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
            // Written apart ("La Rioja Meteo" for `lariojameteo`) only for a
            // long name: a short one lives inside ordinary words.
            word || (flat.len() >= 8 && squeezed.contains(&flat))
        })
        .cloned()
        .collect()
}

/// The projects a note names in its body; its frontmatter does not count.
pub fn projects_named_in_note(note: &Path, projects: &[String]) -> Result<Vec<String>, String> {
    let text = crate::files::read_if_exists(note)?;
    Ok(projects_named_in(&without_frontmatter(&text), projects))
}

/// Notes in `preferences/` that name a project. A preference is how the person
/// works anywhere; a rule of one project is that project's convention and goes
/// to its docs repo. Routing memories by their type alone sent every
/// correction there, project rules included. A note that cannot be read is an
/// error, not a note that names nothing.
pub fn preferences_naming_projects(dir: &Path) -> Vec<(String, Result<Vec<String>, String>)> {
    let projects = known_projects();
    crate::project::files_under(&dir.join("preferences"))
        .into_iter()
        .filter(|f| f.extension().is_some_and(|e| e == "md"))
        .map(|f| (format!("preferences/{}", crate::files::name(&f)), projects_named_in_note(&f, &projects)))
        .filter(|(_, named)| named.as_ref().map_or(true, |n| !n.is_empty()))
        .collect()
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
