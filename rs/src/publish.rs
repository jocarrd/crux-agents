//! A workspace's commits leave the machine as they are made, to a ref of its
//! own on the remote, so that the other machine can resume the work without
//! anyone remembering to push it.

use crate::error::{exit, Res};
use crate::names::git as refs;
use crate::{env, git, project, registry, sh, task};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const INTERNAL: &str = "__publish";

pub fn post_commit() -> Res {
    if !task::sync::publishing_enabled() {
        return Ok(());
    }
    let Some(repo) = git::toplevel(&std::env::current_dir().unwrap_or_default()) else { return Ok(()) };
    let Some(branch) = git::current_branch(&repo) else { return Ok(()) };
    if is_workspace_branch(&repo, &branch) && git::remote_url(&repo, refs::REMOTE).is_some() && may_travel(&repo) {
        if let Ok(exe) = std::env::current_exe() {
            let mut c = Command::new(exe);
            c.arg(INTERNAL).arg(&repo).arg(&branch);
            sh::detach(c);
        }
    }
    Ok(())
}

pub fn internal(argv: &[String]) -> Res {
    let (Some(repo), Some(branch)) = (argv.first(), argv.get(1)) else { return exit(2) };
    if publish_now(Path::new(repo), branch) {
        Ok(())
    } else {
        exit(1)
    }
}

/// A client's repo receives none of this: the refs would carry our tooling's
/// name and our machines' into their remote. The profile says so with
/// `travel.hiddenRefs`.
pub(crate) fn may_travel(repo: &Path) -> bool {
    let docs = project::find_docs_repo(repo);
    let profile = docs.as_deref().and_then(|d| project::contract_field(d, "profile")).unwrap_or_default();
    profile.is_empty() || crate::policy::flag(&profile, docs.as_deref(), "travel.hiddenRefs", true)
}

pub(crate) fn is_workspace_branch(repo: &Path, branch: &str) -> bool {
    let here = project::normalize(repo);
    registry::read()
        .unwrap_or_default()
        .iter()
        .any(|w| w.branch == branch && project::normalize(Path::new(&w.path)) == here)
}

fn lock_file(repo: &Path, branch: &str) -> PathBuf {
    let common = git::common_dir(repo).unwrap_or_else(|| repo.join(".git"));
    common.join("crux").join(format!("publish-{}", branch.replace('/', "-")))
}

/// The tip is read once the lock is held, not when the commit was made: two
/// commits in a row would otherwise race, and the older could land last.
pub fn publish_now(repo: &Path, branch: &str) -> bool {
    if !may_travel(repo) {
        return false;
    }
    let Ok(_lock) = task::record::lock(&lock_file(repo, branch)) else { return false };
    let Some(tip) = git::out(repo, &["rev-parse", "-q", "--verify", &refs::head(branch)]) else { return false };
    let mine = refs::published_here(branch);
    if git::out(repo, &["rev-parse", "-q", "--verify", &mine]).as_deref() == Some(tip.as_str()) {
        return true;
    }
    let target = refs::published_on_remote(&env::machine(), branch);
    git::ok(repo, &["push", "-q", "--no-verify", refs::REMOTE, &format!("+{tip}:{target}")])
        && git::ok(repo, &["update-ref", &mine, &tip])
}

pub fn is_published(repo: &Path, branch: &str) -> bool {
    let mine = refs::published_here(branch);
    git::has_ref(repo, &mine) && git::ok(repo, &["merge-base", "--is-ancestor", &refs::head(branch), &mine])
}

/// Whether `full` is `<prefix><machine>/<branch>` for exactly this branch: by
/// its ending alone, `fix` would also take what `ws/fix` published.
pub(crate) fn is_branch_ref(full: &str, prefix: &str, branch: &str) -> bool {
    full.strip_prefix(prefix).and_then(|r| r.split_once('/')).is_some_and(|(_, b)| b == branch)
}

/// What every machine published of `branch`, fetched now.
pub fn fetch_published(repo: &Path, branch: &str) -> Vec<String> {
    let spec = format!("+{}*/{branch}:{}*/{branch}", refs::PUBLISHED_ON_REMOTE, refs::FETCHED);
    git::run(repo, &["fetch", "-q", "--no-write-fetch-head", refs::REMOTE, &spec]);
    git::out(repo, &["for-each-ref", "--format=%(refname) %(objectname)", refs::FETCHED])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once(' '))
        .filter(|(name, _)| is_branch_ref(name, refs::FETCHED, branch))
        .map(|(_, sha)| sha.to_string())
        .collect()
}

/// The commit every other one is an ancestor of, or the ones that diverged.
pub fn most_advanced(repo: &Path, commits: &[String]) -> Result<Option<String>, Vec<String>> {
    let mut unique: Vec<String> = commits.to_vec();
    unique.sort();
    unique.dedup();
    let contains_all =
        |c: &String| unique.iter().all(|o| o == c || git::ok(repo, &["merge-base", "--is-ancestor", o, c]));
    match unique.iter().find(|c| contains_all(c)) {
        Some(c) => Ok(Some(c.clone())),
        None if unique.is_empty() => Ok(None),
        None => Err(unique),
    }
}

/// After the merge nothing of `branch` should keep travelling.
pub fn forget(repo: &Path, branch: &str) {
    crate::wip::forget(repo, branch);
    let remote: Vec<String> = git::out(repo, &["ls-remote", refs::REMOTE, &format!("{}*", refs::PUBLISHED_ON_REMOTE)])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('\t').map(|(_, r)| r.to_string()))
        .filter(|r| is_branch_ref(r, refs::PUBLISHED_ON_REMOTE, branch))
        .collect();
    if !remote.is_empty() {
        let mut args: Vec<String> = vec!["push".into(), "-q".into(), "--no-verify".into(), refs::REMOTE.into()];
        args.extend(remote.iter().map(|r| format!(":{r}")));
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        git::run(repo, &args);
    }
    let here = refs::published_here(branch);
    if git::has_ref(repo, &here) {
        git::run(repo, &["update-ref", "-d", &here]);
    }
    for fetched in git::out(repo, &["for-each-ref", "--format=%(refname)", refs::FETCHED])
        .unwrap_or_default()
        .lines()
        .filter(|r| is_branch_ref(r, refs::FETCHED, branch))
    {
        git::run(repo, &["update-ref", "-d", fetched]);
    }
}

#[cfg(test)]
mod tests {
    use super::is_branch_ref;

    #[test]
    fn a_branch_ref_is_matched_by_machine_and_whole_name() {
        let p = "refs/crux/branches/";
        assert!(is_branch_ref("refs/crux/branches/desk/ws/fix", p, "ws/fix"));
        assert!(is_branch_ref("refs/crux/branches/desk/fix", p, "fix"));
        assert!(!is_branch_ref("refs/crux/branches/desk/ws/fix", p, "fix"));
        assert!(!is_branch_ref("refs/crux/branches/desk/fix", p, "ws/fix"));
        assert!(!is_branch_ref("refs/crux/fetched/desk/fix", p, "fix"));
    }
}
