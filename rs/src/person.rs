//! The person's profile: a repo of its own next to the projects with how they
//! want to work and who they are. Markdown that belongs to no agent: each
//! adapter loads it in its own place. See ADR-018.

use crate::names;
use crate::{env, template};
use std::path::{Path, PathBuf};

pub fn repo_name() -> String {
    env::preference("CRUX_PROFILE_REPO", "agent-profile")
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

/// This machine's note, if the profile has one.
pub fn machine_note(dir: &Path) -> Option<PathBuf> {
    let note = dir.join(format!("machines/{}.md", env::hostname()));
    note.is_file().then_some(note)
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
