//! git, always through its command line: it is what the person has
//! configured (credentials, hooks, insteadOf), and a library would bypass it.

use crate::sh::{self, Run};
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn cmd(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir);
    c
}

pub fn run(dir: &Path, args: &[&str]) -> Run {
    sh::capture_cmd(cmd(dir).args(args))
}

/// stdout of a git command that has to succeed, or None.
pub fn out(dir: &Path, args: &[&str]) -> Option<String> {
    let r = run(dir, args);
    r.ok().then(|| r.out())
}

pub fn ok(dir: &Path, args: &[&str]) -> bool {
    run(dir, args).ok()
}

pub fn is_repo(dir: &Path) -> bool {
    dir.join(".git").exists()
}

pub fn toplevel(dir: &Path) -> Option<PathBuf> {
    out(dir, &["rev-parse", "--show-toplevel"]).map(PathBuf::from)
}

pub fn common_dir(dir: &Path) -> Option<PathBuf> {
    out(dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).map(PathBuf::from)
}

/// The main checkout a worktree hangs from (or the repo itself).
pub fn main_repo(dir: &Path) -> Option<PathBuf> {
    common_dir(dir).and_then(|c| c.parent().map(Path::to_path_buf))
}

/// In a worktree, .git is a file and the common directory lives in the main
/// repo.
pub fn is_worktree(dir: &Path) -> bool {
    match out(dir, &["rev-parse", "--git-common-dir"]) {
        Some(c) => c != ".git" && Path::new(&c) != dir.join(".git"),
        None => false,
    }
}

pub fn current_branch(dir: &Path) -> Option<String> {
    out(dir, &["symbolic-ref", "-q", "--short", "HEAD"]).filter(|b| !b.is_empty())
}

pub fn has_ref(dir: &Path, r: &str) -> bool {
    ok(dir, &["show-ref", "--verify", "--quiet", r])
}

pub fn remote_url(dir: &Path, remote: &str) -> Option<String> {
    out(dir, &["remote", "get-url", remote]).filter(|u| !u.is_empty())
}

pub fn head_sha(dir: &Path) -> Option<String> {
    out(dir, &["rev-parse", "HEAD"])
}
