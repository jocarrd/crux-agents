//! Templates and the blocks crux owns inside files that are otherwise the
//! person's: what crux generates is regenerated, and what they wrote stays.

use crate::{env, git};
use regex::Regex;
use std::fs;
use std::path::Path;

/// `{{KEY}}` replaced by each value. No trailing newline, as the shell
/// version's `$(cat)` dropped it.
pub fn render(src: &Path, vars: &[(&str, &str)]) -> std::io::Result<String> {
    let mut content = fs::read_to_string(src)?;
    while content.ends_with('\n') {
        content.pop();
    }
    for (k, v) in vars {
        content = content.replace(&format!("{{{{{k}}}}}"), v);
    }
    Ok(content)
}

pub fn render_to(src: &Path, dst: &Path, vars: &[(&str, &str)]) -> std::io::Result<()> {
    let content = render(src, vars)?;
    if let Some(d) = dst.parent() {
        fs::create_dir_all(d)?;
    }
    fs::write(dst, content + "\n")
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Managed {
    Created,
    Updated,
    Unchanged,
    /// The target exists and has no markers: it is the repo's, not touched.
    Foreign,
    /// The template itself has no managed block: a malformed template must
    /// not be reported as written.
    TemplateWithoutBlock,
}

fn managed_block_re() -> &'static Regex {
    crate::regex!(r"<!-- crux:begin[\s\S]*?crux:end -->")
}

/// Whitespace-insensitive: many repos run a formatter that aligns markdown
/// tables. Without this, the formatter and `crux link` rewrite the block back
/// and forth forever.
fn loose(t: &str) -> String {
    let t = crate::regex!(r"-{2,}").replace_all(t, "--");
    let t = crate::regex!(r"[ \t]+").replace_all(&t, " ");
    crate::regex!(r" *\n").replace_all(&t, "\n").into_owned()
}

/// Writes the template respecting what the repo has added: if the target
/// already has the marked block, only that block is replaced.
pub fn render_managed(src: &Path, dst: &Path, vars: &[(&str, &str)]) -> std::io::Result<Managed> {
    let incoming = render(src, vars)?;
    if !dst.exists() {
        if let Some(d) = dst.parent() {
            fs::create_dir_all(d)?;
        }
        fs::write(dst, format!("{incoming}\n"))?;
        return Ok(Managed::Created);
    }
    let current = fs::read_to_string(dst)?;
    if !current.contains("crux:begin") {
        return Ok(Managed::Foreign);
    }
    let re = managed_block_re();
    let Some(block) = re.find(&incoming) else { return Ok(Managed::TemplateWithoutBlock) };
    if let Some(previous) = re.find(&current) {
        if loose(previous.as_str()) == loose(block.as_str()) {
            return Ok(Managed::Unchanged);
        }
    }
    let updated = re.replacen(&current, 1, regex::NoExpand(block.as_str())).into_owned();
    fs::write(dst, updated)?;
    Ok(Managed::Updated)
}

/// Puts the block at the top of the file, replacing the one between the
/// markers if it was there, and leaves the rest as the person wrote it. An
/// empty block removes it. At the top because what is read first weighs most.
pub fn write_marked_block(file: &Path, begin: &str, end: &str, block: &str) -> std::io::Result<()> {
    let src = fs::read_to_string(file).unwrap_or_default();
    let re = Regex::new(&format!(r"{}[\s\S]*?{}\n*", regex::escape(begin), regex::escape(end))).unwrap();
    let rest = re.replacen(&src, 1, "").into_owned();
    let rest = rest.trim_start_matches('\n');
    let out = if block.is_empty() {
        rest.to_string()
    } else if rest.is_empty() {
        format!("{block}\n")
    } else {
        format!("{block}\n\n{rest}")
    };
    if out != src {
        if let Some(d) = file.parent() {
            fs::create_dir_all(d)?;
        }
        fs::write(file, out)?;
    }
    Ok(())
}

/// Replaces the marked block in place, or appends it if it is not there.
pub fn replace_or_append_block(file: &Path, begin: &str, end: &str, block: &str) -> std::io::Result<()> {
    let src = fs::read_to_string(file).unwrap_or_default();
    if src.contains(begin) {
        let re = Regex::new(&format!(r"{}[\s\S]*?{}", regex::escape(begin), regex::escape(end))).unwrap();
        fs::write(file, re.replacen(&src, 1, regex::NoExpand(block)).into_owned())
    } else {
        let mut f = fs::OpenOptions::new().create(true).append(true).open(file)?;
        std::io::Write::write_all(&mut f, format!("{block}\n").as_bytes())
    }
}

/// The client-repo profile does not allow writing anything versioned in
/// someone else's repo, but without a file the agent loads on its own the
/// docs repo is never discovered. CLAUDE.local.md loads like CLAUDE.md and
/// goes into the exclude of git's common directory.
pub use crate::names::LOCAL_POINTER;

#[derive(Debug, PartialEq, Eq)]
pub enum LocalPointer {
    Written,
    NotARepo,
    /// The client versions a file with that name: theirs, not touched.
    Versioned,
}

pub fn write_local_pointer(dir: &Path, docs_name: &str) -> std::io::Result<LocalPointer> {
    let Some(common) = git::common_dir(dir) else { return Ok(LocalPointer::NotARepo) };
    if git::ok(dir, &["ls-files", "--error-unmatch", LOCAL_POINTER]) {
        return Ok(LocalPointer::Versioned);
    }
    let exclude = common.join("info/exclude");
    fs::create_dir_all(common.join("info"))?;
    let listed = fs::read_to_string(&exclude).unwrap_or_default().lines().any(|l| l == LOCAL_POINTER);
    if !listed {
        let mut f = fs::OpenOptions::new().create(true).append(true).open(&exclude)?;
        std::io::Write::write_all(&mut f, format!("{LOCAL_POINTER}\n").as_bytes())?;
    }
    let home = env::crux_home().unwrap_or_default();
    // With its trailing newline: the client's `prettier --check`, which does
    // not read info/exclude, flags the file otherwise.
    let content = render(&home.join("templates/code-repo").join(LOCAL_POINTER), &[("DOCS", docs_name)])?;
    fs::write(dir.join(LOCAL_POINTER), content + "\n")?;
    Ok(LocalPointer::Written)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marked_block_goes_on_top_and_keeps_the_rest() {
        let d = std::env::temp_dir().join(format!("crux-tpl-{}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        let f = d.join(crate::names::CLAUDE);
        fs::write(&f, "My own line\n").unwrap();
        write_marked_block(&f, "<!-- b -->", "<!-- e -->", "<!-- b -->\nx\n<!-- e -->").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "<!-- b -->\nx\n<!-- e -->\n\nMy own line\n");
        write_marked_block(&f, "<!-- b -->", "<!-- e -->", "").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "My own line\n");
        fs::remove_dir_all(&d).unwrap();
    }
}
