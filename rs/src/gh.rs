//! What crux asks GitHub, through the `gh` the person has authenticated: one
//! function per question, so the arguments and the jq that reads the answer
//! are written once.

use crate::sh;
use std::path::Path;

const GH: &str = "gh";
/// More proposals than this are not looked at when listing merged ones.
const MERGED_LIST_LIMIT: &str = "200";

pub fn exists() -> bool {
    sh::exists(GH)
}

pub fn authenticated() -> bool {
    exists() && sh::capture(GH, &["auth", "status"]).ok()
}

/// More repos than this in one owner are not looked at.
const REPO_LIST_LIMIT: &str = "300";

/// The names of an owner's repos.
pub fn repo_names(owner: &str) -> Vec<String> {
    sh::capture(GH, &["repo", "list", owner, "--limit", REPO_LIST_LIMIT, "--json", "name", "--jq", ".[].name"])
        .stdout
        .lines()
        .map(String::from)
        .collect()
}

/// The same, without the archived ones: read-only on GitHub, nothing more can
/// land there.
pub fn active_repo_names(owner: &str) -> Vec<String> {
    let jq = ".[] | select(.isArchived | not) | .name";
    sh::capture(GH, &["repo", "list", owner, "--limit", REPO_LIST_LIMIT, "--json", "name,isArchived", "--jq", jq])
        .stdout
        .lines()
        .map(String::from)
        .collect()
}

/// `owner/name` exists and this account can see it.
pub fn repo_exists(slug: &str) -> bool {
    sh::capture(GH, &["repo", "view", slug]).ok()
}

/// `public`, `private` or `internal`; None when it could not be asked. With a
/// timeout: it is asked from a background sync that must not hang.
pub fn visibility(slug: &str) -> Option<String> {
    let mut c = std::process::Command::new(GH);
    c.args(["repo", "view", slug, "--json", "visibility", "--jq", ".visibility"]);
    let r = sh::with_timeout(&mut c, 15);
    let v = r.stdout.trim().to_lowercase();
    (r.ok() && !v.is_empty()).then_some(v)
}

/// Whether the repo `slug` has the file `path` on its default branch.
pub fn has_file(slug: &str, path: &str) -> bool {
    sh::capture(GH, &["api", &format!("repos/{slug}/contents/{path}"), "--silent"]).ok()
}

/// A proposal that was merged, and the commit its branch pointed to when it
/// was: what a local branch has to contain nothing beyond to be deletable.
pub struct Merged {
    pub number: String,
    pub head: String,
}

pub fn merged_proposal(repo: &Path, branch: &str) -> Option<Merged> {
    if !exists() {
        return None;
    }
    let r = sh::capture_in(
        repo,
        GH,
        &[
            "pr",
            "list",
            "--head",
            branch,
            "--state",
            "merged",
            "--json",
            "number,headRefOid",
            "-q",
            r#".[0] | select(. != null) | "\(.number) \(.headRefOid)""#,
        ],
    );
    let line = r.out();
    let (number, head) = line.split_once(' ')?;
    Some(Merged { number: number.to_string(), head: head.to_string() })
}

pub fn repo_slug(repo: &Path) -> Option<String> {
    let r = sh::capture_in(repo, GH, &["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
    let slug = r.out();
    (r.ok() && !slug.is_empty()).then_some(slug)
}

pub fn merged_branches(repo: &Path) -> Option<Vec<String>> {
    let slug = repo_slug(repo)?;
    let r = sh::capture(
        GH,
        &[
            "pr",
            "list",
            "--repo",
            &slug,
            "--state",
            "merged",
            "--limit",
            MERGED_LIST_LIMIT,
            "--json",
            "headRefName",
            "-q",
            ".[].headRefName",
        ],
    );
    Some(r.stdout.lines().map(String::from).collect())
}
