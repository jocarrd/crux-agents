//! git, always through its command line: it is what the person has
//! configured (credentials, hooks, insteadOf), and a library would bypass it.

use crate::sh::{self, Run};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

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

/// Keeps local files out of git without touching the versioned .gitignore:
/// the common directory's exclude, which every worktree of the repo honours.
pub fn exclude(dir: &Path, entries: &[&str]) -> Result<(), String> {
    let Some(common) = common_dir(dir) else { return Err(format!("{} is not a git repo", dir.display())) };
    let file = common.join("info/exclude");
    std::fs::create_dir_all(common.join("info")).map_err(|e| format!("{}: {e}", file.display()))?;
    let mut current = crate::files::read_if_exists(&file)?;
    let missing: Vec<&str> = entries.iter().copied().filter(|e| !current.lines().any(|l| l == *e)).collect();
    if missing.is_empty() {
        return Ok(());
    }
    if !current.is_empty() && !current.ends_with('\n') {
        current.push('\n');
    }
    for e in missing {
        current.push_str(e);
        current.push('\n');
    }
    crate::files::write(&file, &current)
}

/// The main checkout and every worktree that hangs from it.
pub fn worktrees(dir: &Path) -> Vec<PathBuf> {
    out(dir, &["worktree", "list", "--porcelain"])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("worktree ").map(PathBuf::from))
        .filter(|p| p.is_dir())
        .collect()
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

/// git for what runs with no one at the terminal: published in the
/// background, fed on stdin, and never left waiting for a prompt.
pub struct Batch<'a> {
    repo: &'a Path,
    env: Vec<(String, String)>,
}

impl<'a> Batch<'a> {
    pub fn new(repo: &'a Path) -> Self {
        Batch { repo, env: vec![] }
    }
    pub fn with(repo: &'a Path, env: &[(&str, &str)]) -> Self {
        Batch { repo, env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new("git");
        c.arg("-C").arg(self.repo).args(args);
        c.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0");
        // With no terminal to answer, an ssh prompt would hang the publication.
        let ssh = std::env::var("GIT_SSH_COMMAND").unwrap_or_else(|_| "ssh".into());
        c.env("GIT_SSH_COMMAND", format!("{ssh} -o BatchMode=yes"));
        for (k, v) in &self.env {
            c.env(k, v);
        }
        c
    }
    /// stdout on success; stderr as the error.
    pub fn run(&self, args: &[&str], input: Option<&str>) -> Result<String, String> {
        let mut c = self.command(args);
        c.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
        let mut child = c.spawn().map_err(|e| e.to_string())?;
        if let Some(i) = input {
            let mut stdin = child.stdin.take().unwrap();
            let data = i.to_string();
            std::thread::spawn(move || {
                let _ = stdin.write_all(data.as_bytes());
            });
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        }
    }
    pub fn get(&self, args: &[&str]) -> Option<String> {
        self.run(args, None).ok().map(|s| s.trim().to_string())
    }
}
