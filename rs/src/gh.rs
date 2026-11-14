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

/// A proposal that was merged, and the commit its branch pointed to when it
/// was: what a local branch has to contain nothing beyond to be deletable.
pub struct Merged {
    pub number: String,
    pub head: String,
}

/// The merged proposal whose head was `branch`, if there is one.
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

/// The `owner/name` of the repo GitHub knows `repo` as.
pub fn repo_slug(repo: &Path) -> Option<String> {
    let r = sh::capture_in(repo, GH, &["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
    let slug = r.out();
    (r.ok() && !slug.is_empty()).then_some(slug)
}

/// The head branches of the merged proposals of `repo`, the most recent first.
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
