//! A project: its docs repo, the `crux.json` contract in it, and how its
//! repos are named and reached on the remote.

use crate::names;
use crate::{env, files, git, sh};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn absolute(dir: &Path) -> Option<PathBuf> {
    // `cd && pwd`, not canonicalize: the logical path keeps the symlinks the
    // person typed, and every path printed or stored has always been that one.
    if !dir.is_dir() {
        return None;
    }
    if dir.is_absolute() {
        return Some(normalize(dir));
    }
    std::env::current_dir().ok().map(|c| normalize(&c.join(dir)))
}

/// Removes `.` and `..` lexically, as the shell's `cd` does with a logical path.
pub fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Walks up from the directory until it finds a crux.json. The sibling
/// <project>-docs wins over a crux.json that shows up inside the code repo
/// itself: otherwise whoever sends a proposal with a crux.json at the root
/// decides the contract.
pub fn find_docs_repo(start: &Path) -> Option<PathBuf> {
    let dir = absolute(start)?;
    let parent = dir.parent().unwrap_or(Path::new("/"));
    let project = parent.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let sibling = parent.join(format!("{project}-docs"));
    if sibling.join(names::CONTRACT).is_file() {
        return Some(sibling);
    }
    let mut probe = dir.clone();
    while probe != Path::new("/") {
        if probe.join(names::CONTRACT).is_file() {
            let base = probe.file_name().and_then(|n| n.to_str()).unwrap_or("");
            // A crux.json at the root of a code repo is not the project
            // contract: it only counts if that repo is the documentation one.
            let code_repo = probe.join(".git").is_dir() && !base.ends_with("-docs") && base != "docs";
            if !code_repo {
                return Some(probe);
            }
        }
        probe = probe.parent().unwrap_or(Path::new("/")).to_path_buf();
    }
    if parent.join(format!("{project}-docs")).is_dir() {
        return Some(sibling);
    }
    if dir.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with("-docs")) {
        return Some(dir);
    }
    None
}

pub fn contract_file(docs: &Path) -> PathBuf {
    docs.join(names::CONTRACT)
}

pub fn read_contract(docs: &Path) -> Result<Value, String> {
    files::read_json(&contract_file(docs))
}

/// The contract if it parses; None if it is absent or broken. Only for
/// questions where a broken contract has no better answer than "unknown":
/// commands that depend on it report it instead.
pub fn contract_lenient(docs: &Path) -> Option<Value> {
    read_contract(docs).ok()
}

pub fn contract_field(docs: &Path, path: &str) -> Option<String> {
    contract_lenient(docs).and_then(|c| files::get_str(&c, path))
}

/// The one declared in the contract, the remote's, or the one the repo is
/// using. In that order.
pub fn main_branch(dir: &Path) -> String {
    if let Some(docs) = find_docs_repo(dir) {
        if let Some(b) = contract_field(&docs, "branch").filter(|b| !b.is_empty()) {
            return b;
        }
    }
    let mut declared = git::out(dir, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        .map(|b| b.trim_start_matches("origin/").to_string())
        .unwrap_or_default();
    if declared.is_empty() {
        // The current branch only as a last resort: from a worktree it is the
        // work branch, and taking it as the main one leaves the hook blocking
        // exactly that.
        for c in ["main", "master"] {
            if git::has_ref(dir, &format!("refs/heads/{c}")) {
                declared = c.into();
                break;
            }
        }
    }
    if declared.is_empty() {
        declared = git::out(dir, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    }
    if declared.is_empty() || declared == "HEAD" {
        declared = "main".into();
    }
    declared
}

/// "since\treason" if its project archived the repo (a workspace answers for
/// its main repo).
pub fn archived_entry(repo: &Path) -> Option<(String, String)> {
    let main = git::main_repo(repo)?;
    let root = main.parent()?;
    let project = root.file_name()?.to_str()?;
    let config = root.join(format!("{project}-docs/crux.json"));
    let c = files::read_json(&config).ok()?;
    let name = main.file_name()?.to_str()?;
    let entry = c.get("archived")?.get(name)?;
    Some((files::get_str(entry, "since").unwrap_or_default(), files::get_str(entry, "reason").unwrap_or_default()))
}

/// Stops a command meant for active repos.
pub fn refuse_if_archived(repo: &Path) -> crate::error::Res {
    if let Some((since, reason)) = archived_entry(repo) {
        let name = git::main_repo(repo)
            .and_then(|m| m.file_name().map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_default();
        crate::ui::err(format!("{name} is archived since {since}: {reason}"));
        crate::ui::info(format!("if it is coming back to life: crux unarchive {name}, from its docs repo"));
        return crate::error::exit(1);
    }
    Ok(())
}

pub fn pinned_version(path: &Path) -> Option<String> {
    let docs = find_docs_repo(path)?;
    contract_field(&docs, "crux")
}

// --- The remote ---------------------------------------------------------------
//
// The kernel knows nothing about providers. Each project declares how the URL
// of its repos is built, and with that it works the same for GitHub, GitLab
// —including self-hosted with a port—, Bitbucket or Azure DevOps.

/// The per-repo override exists because a project can keep its documentation
/// on your remote and its code on someone else's.
pub fn remote_url(contract: &Value, repo: &str) -> Option<String> {
    let r = contract.get("remote")?;
    if let Some(own) = r.get("repos").and_then(|x| x.get(repo)).and_then(Value::as_str) {
        return Some(own.replace("{repo}", repo));
    }
    let tmpl = match r.get("url").and_then(Value::as_str) {
        Some(u) if !u.is_empty() => u.to_string(),
        _ => {
            let host = r.get("host").and_then(Value::as_str)?;
            let owner = r.get("owner").and_then(Value::as_str)?;
            if r.get("protocol").and_then(Value::as_str) == Some("https") {
                format!("https://{host}/{owner}/{{repo}}.git")
            } else {
                format!("git@{host}:{owner}/{{repo}}.git")
            }
        }
    };
    Some(tmpl.replace("{repo}", repo))
}

/// Infers the template from the origin of an already cloned repo. Only the
/// last occurrence of the name: if the owner is called like the repo,
/// replacing all of them gives a broken template.
pub fn remote_from_git(dir: &Path) -> Option<String> {
    let name = dir.file_name()?.to_str()?;
    let url = git::remote_url(dir, "origin")?;
    Some(match url.rfind(name) {
        Some(i) => format!("{}{{repo}}{}", &url[..i], &url[i + name.len()..]),
        None => url,
    })
}

/// Canonical «host/owner/repo» for comparing ssh and https forms of the same
/// repo. Lowercase: the owner is case-insensitive.
pub fn normalize_git_url(url: &str) -> String {
    let mut u = url.strip_suffix(".git").unwrap_or(url);
    for p in ["ssh://", "git@", "https://", "http://"] {
        u = u.strip_prefix(p).unwrap_or(u);
    }
    u.replacen(':', "/", 1).to_lowercase()
}

/// The owner of a GitHub template; empty elsewhere, since GitHub is the only
/// provider the kernel creates repos on.
pub fn owner_from_template(tmpl: &str) -> String {
    let re = crate::regex!(r"github\.com[:/]([^/]+)/");
    re.captures(tmpl).map(|c| c[1].to_string()).unwrap_or_default()
}

pub fn remote_template() -> Option<String> {
    env::config_value_in(&env::config_file_redirectable(), "CRUX_REMOTE")
}

/// From the same place as the clone URLs, so there are not two sources of
/// truth that can disagree.
pub fn default_owner() -> String {
    let owner = owner_from_template(&remote_template().unwrap_or_default());
    if !owner.is_empty() {
        return owner;
    }
    sh::capture("gh", &["api", "user", "--jq", ".login"]).out()
}

/// The machine's clone template pointing at another owner, keeping its shape.
pub fn template_for_owner(owner: &str) -> String {
    template_with_owner(&remote_template().unwrap_or_default(), owner)
}

pub fn template_with_owner(tmpl: &str, owner: &str) -> String {
    let re = crate::regex!(r"^(.*github\.com[:/])[^/]+/(.*)$");
    match re.captures(tmpl) {
        Some(c) => format!("{}{}/{}", &c[1], owner, &c[2]),
        None => format!("git@github.com:{owner}/{{repo}}.git"),
    }
}

/// Not style —there are real repos in CamelCase— but what does harm: a name
/// with '/' or '..' gets joined into a path and writes outside the docs repo.
pub fn valid_name(name: &str) -> bool {
    let re = crate::regex!(r"^[A-Za-z0-9][A-Za-z0-9._-]*$");
    re.is_match(name) && !name.contains("..")
}

/// A directory as the shell's `cd dir && pwd` gives it.
pub fn resolve_dir(dir: &Path) -> Option<PathBuf> {
    absolute(dir)
}

/// Sorted names of the subdirectories, as a shell glob `dir/*/` lists them.
pub fn subdirs(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .map(|e| {
            e.flatten()
                .filter(|x| x.path().is_dir())
                .map(|x| x.file_name().to_string_lossy().into_owned())
                .filter(|n| !n.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// Writes the contract as the kernel always has: two-space JSON, newline.
pub fn write_contract(docs: &Path, c: &Value) -> std::io::Result<()> {
    std::fs::write(contract_file(docs), files::json_pretty(c))
}

pub fn is_semver(v: &str) -> bool {
    crate::regex!(r"^[0-9]+\.[0-9]+\.[0-9]+$").is_match(v)
}

/// Compared as numbers: as text, 0.9.0 comes out greater than 0.10.0. What is
/// not semver is not compared.
pub fn version_greater_than(a: &str, b: &str) -> bool {
    if !is_semver(a) || !is_semver(b) {
        return false;
    }
    let n = |v: &str| v.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    n(a) > n(b)
}

/// Every file under a directory, sorted by path, as `find -type f | sort`.
pub fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() && !p.is_symlink() {
                stack.push(p);
            } else if p.is_file() {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

// --- Projects on the remote ---------------------------------------------------
//
// Used by bootstrap, which brings all of them, and sync, which brings the
// missing ones. The list comes from the remote and not from an inventory: one
// written by hand goes stale as soon as you create a project elsewhere.

/// Your account and every organisation you are an active member of: a
/// project lives where its team does.
pub fn search_owners() -> Vec<String> {
    let mut out = vec![default_owner()];
    let orgs = crate::sh::capture(
        "gh",
        &[
            "api",
            "user/memberships/orgs",
            "--paginate",
            "--jq",
            ".[] | select(.state == \"active\") | .organization.login",
        ],
    );
    out.extend(orgs.stdout.lines().map(String::from));
    let mut seen = std::collections::HashSet::new();
    out.into_iter().filter(|o| !o.is_empty() && seen.insert(o.clone())).collect()
}

/// The owner's `<something>-docs` repos, without the suffix.
pub fn candidate_projects(owner: &str) -> Vec<String> {
    let r = crate::sh::capture("gh", &["repo", "list", owner, "--limit", "300", "--json", "name", "--jq", ".[].name"]);
    let mut v: Vec<String> = r.stdout.lines().filter_map(|n| n.strip_suffix("-docs")).map(String::from).collect();
    v.sort();
    v.dedup();
    v
}

/// Without crux.json, any repo ending in -docs would count as a project.
pub fn has_contract(owner: &str, project: &str) -> bool {
    crate::sh::capture("gh", &["api", &format!("repos/{owner}/{project}-docs/contents/crux.json"), "--silent"]).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_and_https_normalize_the_same() {
        assert_eq!(normalize_git_url("git@github.com:Acme-Org/foo.git"), "github.com/acme-org/foo");
        assert_eq!(normalize_git_url("https://github.com/acme-org/foo.git"), "github.com/acme-org/foo");
        assert_ne!(normalize_git_url("git@github.com:acme-org/bar.git"), "github.com/acme-org/foo");
    }

    #[test]
    fn owner_only_from_github_templates() {
        assert_eq!(owner_from_template("git@github.com:Acme-Org/{repo}.git"), "Acme-Org");
        assert_eq!(owner_from_template("https://github.com/acme-org/{repo}.git"), "acme-org");
        assert_eq!(owner_from_template("git@gitlab.com:acme-org/{repo}.git"), "");
    }
}
