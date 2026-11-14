//! What a workspace has not committed travels too: at the end of each agent
//! turn it is saved as a commit on top of HEAD, in a hidden ref per machine,
//! and resuming the workspace on the other machine applies it.

use crate::error::{exit, Res};
use crate::names::git as refs;
use crate::{env, git, publish, sh, task};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const INTERNAL: &str = "__wip";

/// A file this big is a build output or a video nobody ignored, not work.
const MAX_FILE: u64 = 5 * 1024 * 1024;
/// Past this, new files are a dependency folder nobody ignored: nothing is
/// saved, and leaving goes on saying the work stays here.
const MAX_NEW_FILES: usize = 1000;
const MAX_NEW_BYTES: u64 = 20 * 1024 * 1024;

/// Ignored files are never carried; these are not carried even when nobody
/// ignored them, because the remote is no place for a secret.
fn looks_secret(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    (name.starts_with(".env") && !name.ends_with(".example"))
        || [".pem", ".key", ".p12", ".pfx"].iter().any(|e| name.ends_with(e))
        || name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
}

/// Starts the save detached: the turn of the agent does not wait for it.
pub fn save_in_background(dir: &Path) {
    if !task::sync::publishing_enabled() {
        return;
    }
    let Some(repo) = git::toplevel(dir) else { return };
    let Some(branch) = git::current_branch(&repo) else { return };
    if !publish::is_workspace_branch(&repo, &branch) || git::remote_url(&repo, refs::REMOTE).is_none() {
        return;
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut c = Command::new(exe);
        c.arg(INTERNAL).arg(&repo).arg(&branch);
        sh::detach(c);
    }
}

pub fn internal(argv: &[String]) -> Res {
    let (Some(repo), Some(branch)) = (argv.first(), argv.get(1)) else { return exit(2) };
    if save_now(Path::new(repo), branch) {
        Ok(())
    } else {
        exit(1)
    }
}

/// The working tree as a tree object, built in an index of its own so that
/// the person's staging is left as it was. Returns it with the paths left out.
fn snapshot(repo: &Path) -> Option<(String, Vec<String>)> {
    let index = PathBuf::from(git::out(repo, &["rev-parse", "--path-format=absolute", "--git-path", "index"])?);
    let tmp = index.with_extension(format!("crux-wip.{}", std::process::id()));
    let _ = std::fs::copy(&index, &tmp);
    let g = |args: &[&str]| sh::capture_cmd(git::cmd(repo).args(args).env("GIT_INDEX_FILE", &tmp));
    let mut left_out = vec![];
    let built = (|| {
        if !g(&["add", "-u"]).ok() {
            return None;
        }
        let untracked = g(&["ls-files", "-o", "--exclude-standard", "-z"]);
        let mut carried = vec![];
        let mut bytes = 0;
        for path in untracked.stdout.split('\0').filter(|p| !p.is_empty()) {
            let size = std::fs::metadata(repo.join(path)).map(|m| m.len()).unwrap_or(0);
            if looks_secret(path) || size > MAX_FILE {
                left_out.push(path.to_string());
            } else {
                carried.push(path.to_string());
                bytes += size;
            }
        }
        if carried.len() > MAX_NEW_FILES || bytes > MAX_NEW_BYTES {
            return None;
        }
        for chunk in carried.chunks(200) {
            let mut args = vec!["add", "--"];
            args.extend(chunk.iter().map(String::as_str));
            if !g(&args).ok() {
                return None;
            }
        }
        let tree = g(&["write-tree"]);
        tree.ok().then(|| tree.out())
    })();
    let _ = std::fs::remove_file(&tmp);
    built.map(|t| (t, left_out))
}

fn lock_file(repo: &Path, branch: &str) -> PathBuf {
    let common = git::common_dir(repo).unwrap_or_else(|| repo.join(".git"));
    common.join("crux").join(format!("wip-{}", branch.replace('/', "-")))
}

fn rev(repo: &Path, r: &str) -> Option<String> {
    git::out(repo, &["rev-parse", "-q", "--verify", r])
}

/// Saves the working tree and publishes it. With nothing uncommitted, what
/// was published before is withdrawn: it would be applied on the other
/// machine over work that already has it.
pub fn save_now(repo: &Path, branch: &str) -> bool {
    if task::sync::visibility_of(repo) != task::sync::Visibility::Private {
        return true;
    }
    // Halfway through a merge the tree holds conflict markers: carried, they
    // would be applied on the other machine as if they were work.
    if ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        .iter()
        .any(|f| git::out(repo, &["rev-parse", "--git-path", f]).is_some_and(|p| repo.join(p).exists()))
    {
        return false;
    }
    let Ok(_lock) = task::record::lock(&lock_file(repo, branch)) else { return false };
    let (Some(head), Some(head_tree)) = (rev(repo, "HEAD"), rev(repo, "HEAD^{tree}")) else { return false };
    let Some((tree, left_out)) = snapshot(repo) else { return false };
    let here = refs::wip_here(branch);
    let remote = refs::wip_on_remote(&env::machine(), branch);
    if tree == head_tree {
        if git::has_ref(repo, &here) {
            return git::ok(repo, &["push", "-q", "--no-verify", refs::REMOTE, &format!(":{remote}")])
                && git::ok(repo, &["update-ref", "-d", &here]);
        }
        return true;
    }
    let saved = rev(repo, &here);
    if saved.is_some()
        && rev(repo, &format!("{here}^{{tree}}")).as_deref() == Some(tree.as_str())
        && rev(repo, &format!("{here}^")).as_deref() == Some(head.as_str())
    {
        return true;
    }
    let mut message = format!("wip of {branch} on {}", env::machine());
    if !left_out.is_empty() {
        message.push_str("\n\nleft out:\n");
        for p in &left_out {
            message.push_str(&format!("{p}\n"));
        }
    }
    let Some(commit) = git::out(repo, &["commit-tree", &tree, "-p", &head, "-m", &message]) else { return false };
    git::ok(repo, &["push", "-q", "--no-verify", refs::REMOTE, &format!("+{commit}:{remote}")])
        && git::ok(repo, &["update-ref", &here, &commit])
}

/// Whether what is uncommitted here already travelled, as it is now.
pub fn is_current(repo: &Path, branch: &str) -> bool {
    let here = refs::wip_here(branch);
    let (Some(head), Some(saved_tree)) = (rev(repo, "HEAD"), rev(repo, &format!("{here}^{{tree}}"))) else {
        return false;
    };
    rev(repo, &format!("{here}^")).as_deref() == Some(head.as_str())
        && snapshot(repo).is_some_and(|(tree, left_out)| tree == saved_tree && left_out.is_empty())
}

struct Saved {
    machine: String,
    commit: String,
    parent: String,
    when: i64,
}

fn fetch_saved(repo: &Path, branch: &str) -> Vec<Saved> {
    let spec = format!("+{}*/{branch}:{}*/{branch}", refs::WIP_ON_REMOTE, refs::WIP_FETCHED);
    git::run(repo, &["fetch", "-q", "--no-write-fetch-head", refs::REMOTE, &spec]);
    git::out(repo, &["for-each-ref", "--format=%(refname) %(objectname) %(committerdate:unix)", refs::WIP_FETCHED])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut it = l.split(' ');
            let (name, commit, when) = (it.next()?, it.next()?, it.next()?);
            if !publish::is_branch_ref(name, refs::WIP_FETCHED, branch) {
                return None;
            }
            let machine = name.strip_prefix(refs::WIP_FETCHED)?.split_once('/')?.0.to_string();
            let parent = rev(repo, &format!("{commit}^"))?;
            Some(Saved { machine, commit: commit.to_string(), parent, when: when.parse().unwrap_or(0) })
        })
        .collect()
}

/// Through the trees and not a patch: a patch passed as text would mangle
/// any file that is not UTF-8. Nothing is left staged.
fn apply(worktree: &Path, commit: &str) -> bool {
    let deleted = git::out(worktree, &["diff", "--name-only", "-z", "--diff-filter=D", "HEAD", commit]);
    if !git::ok(worktree, &["checkout", commit, "--", "."]) {
        return false;
    }
    for path in deleted.unwrap_or_default().split('\0').filter(|p| !p.is_empty()) {
        let _ = std::fs::remove_file(worktree.join(path));
    }
    git::ok(worktree, &["reset", "-q"])
}

/// In a workspace just opened: applies what another machine left uncommitted
/// on this same commit. Saved on an older commit, it is only pointed at.
pub fn bring(worktree: &Path, branch: &str, repo_name: &str) {
    let Some(head) = rev(worktree, "HEAD") else { return };
    let mut saved = fetch_saved(worktree, branch);
    saved.retain(|s| s.machine != env::machine() || s.parent == head);
    saved.sort_by_key(|s| std::cmp::Reverse(s.when));
    let (fits, older): (Vec<&Saved>, Vec<&Saved>) = saved.iter().partition(|s| s.parent == head);
    if let Some(s) = fits.first() {
        if apply(worktree, &s.commit) {
            crate::ui::ok(format!("{repo_name}: brought what {} left uncommitted", s.machine));
            let body = git::out(worktree, &["log", "-1", "--format=%b", &s.commit]).unwrap_or_default();
            if let Some(list) = body.strip_prefix("left out:\n") {
                crate::ui::info(format!(
                    "not carried (ignored or secret-looking): {}",
                    list.trim().replace('\n', ", ")
                ));
            }
        } else {
            crate::ui::warn(format!(
                "{repo_name}: what {} left uncommitted does not apply — to see it: git -C {} diff HEAD {}",
                s.machine,
                worktree.display(),
                s.commit
            ));
        }
    }
    for s in older.iter().chain(fits.iter().skip(1)) {
        crate::ui::info(format!(
            "{repo_name}: {} left uncommitted work on another commit — to see it: git -C {} diff {} {}",
            s.machine,
            worktree.display(),
            s.parent,
            s.commit
        ));
    }
}

/// After the merge nothing of `branch` should keep travelling.
pub fn forget(repo: &Path, branch: &str) {
    let remote: Vec<String> = git::out(repo, &["ls-remote", refs::REMOTE, &format!("{}*", refs::WIP_ON_REMOTE)])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('\t').map(|(_, r)| r.to_string()))
        .filter(|r| publish::is_branch_ref(r, refs::WIP_ON_REMOTE, branch))
        .collect();
    if !remote.is_empty() {
        let mut args: Vec<String> = vec!["push".into(), "-q".into(), "--no-verify".into(), refs::REMOTE.into()];
        args.extend(remote.iter().map(|r| format!(":{r}")));
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        git::run(repo, &args);
    }
    let here = refs::wip_here(branch);
    if git::has_ref(repo, &here) {
        git::run(repo, &["update-ref", "-d", &here]);
    }
    for fetched in git::out(repo, &["for-each-ref", "--format=%(refname)", refs::WIP_FETCHED])
        .unwrap_or_default()
        .lines()
        .filter(|r| publish::is_branch_ref(r, refs::WIP_FETCHED, branch))
    {
        git::run(repo, &["update-ref", "-d", fetched]);
    }
}

#[cfg(test)]
mod tests {
    use super::looks_secret;

    #[test]
    fn secret_looking_files_are_recognised_by_name() {
        assert!(looks_secret(".env"));
        assert!(looks_secret("api/.env.local"));
        assert!(looks_secret("certs/server.key"));
        assert!(looks_secret("id_ed25519"));
        assert!(!looks_secret(".env.example"));
        assert!(!looks_secret("src/environment.ts"));
        assert!(!looks_secret("keyboard.rs"));
    }
}
