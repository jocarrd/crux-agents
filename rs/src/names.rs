//! The names crux writes and reads, in one place: spelled in two places, one
//! day they differ and something is looked for where it is not.

/// A project's contract, at the root of its docs repo.
pub const CONTRACT: &str = "crux.json";
/// The quality gate's receipt, in the repo being proposed.
pub const GATE_RECEIPT: &str = ".crux-ship";
/// The approved visual review's receipt.
pub const VISUAL_RECEIPT: &str = ".crux-visual";
/// The pointer crux writes into a client's repo, excluded from git.
pub const LOCAL_POINTER: &str = "CLAUDE.local.md";
pub const AGENTS: &str = "AGENTS.md";
pub const CLAUDE: &str = "CLAUDE.md";
pub const README: &str = "README.md";
pub const SKILL: &str = "SKILL.md";
/// What marks a directory as a kernel, with VERSION.
pub const STANDARD: &str = "STANDARD.md";
pub const VERSION: &str = "VERSION";

pub mod git {
    pub const REMOTE: &str = "origin";
    pub const HEADS: &str = "refs/heads/";
    /// Outside refs/heads: no list of branches shows them, no proposal is
    /// offered for them and no workflow is triggered by them.
    pub const PUBLISHED_ON_REMOTE: &str = "refs/crux/branches/";
    /// Kept locally so that knowing whether a branch travelled needs no network.
    pub const PUBLISHED_HERE: &str = "refs/crux/published/";
    pub const FETCHED: &str = "refs/crux/fetched/";
    /// What a workspace had uncommitted, per machine, as a commit on its HEAD.
    pub const WIP_ON_REMOTE: &str = "refs/crux/wip/";
    pub const WIP_HERE: &str = "refs/crux/wip-here/";
    pub const WIP_FETCHED: &str = "refs/crux/wip-fetched/";

    /// The branch tasks travel on, in each docs repo (ADR-016).
    pub const TASKS_BRANCH: &str = "crux/tasks";
    pub const TASKS_TRACKED: &str = "refs/remotes/origin/crux/tasks";
    /// What the task sync last saw on the remote. Its own ref, and the remote
    /// by URL and not by name: writing TASKS_TRACKED makes a `git pull` at the
    /// same moment fail with "cannot lock ref". git 2.56 and later update that
    /// ref on a push to the remote's URL; with a fetch holding it, the push
    /// still succeeds.
    pub const TASKS_SEEN: &str = "refs/crux/tasks-remote";
    pub const REMOTES: &str = "refs/remotes/";
    pub const REMOTE_HEAD: &str = "refs/remotes/origin/HEAD";
    pub const TAGS: &str = "refs/tags/";

    pub fn head(branch: &str) -> String {
        format!("{HEADS}{branch}")
    }

    /// The remote's copy of a branch, as the last fetch left it.
    pub fn remote_branch(branch: &str) -> String {
        format!("{REMOTES}{REMOTE}/{branch}")
    }

    /// The same copy as git names it for a person: `origin/main`.
    pub fn remote_short(branch: &str) -> String {
        format!("{REMOTE}/{branch}")
    }

    pub fn tag(name: &str) -> String {
        format!("{TAGS}{name}")
    }

    pub fn published_on_remote(machine: &str, branch: &str) -> String {
        format!("{PUBLISHED_ON_REMOTE}{machine}/{branch}")
    }

    pub fn published_here(branch: &str) -> String {
        format!("{PUBLISHED_HERE}{branch}")
    }

    pub fn wip_on_remote(machine: &str, branch: &str) -> String {
        format!("{WIP_ON_REMOTE}{machine}/{branch}")
    }

    pub fn wip_here(branch: &str) -> String {
        format!("{WIP_HERE}{branch}")
    }
}

pub mod hooks {
    pub const COMMIT_MSG: &str = "commit-msg";
    pub const POST_COMMIT: &str = "post-commit";
    pub const PRE_COMMIT: &str = "pre-commit";
    pub const PRE_PUSH: &str = "pre-push";
}

pub mod vars {
    /// `0` keeps tasks and what archiving writes on this machine; `1` publishes
    /// them even inside the test suite.
    pub const TASK_SYNC: &str = "CRUX_TASK_SYNC";
    /// Lets `workspace rm` delete a branch already in the main one with no
    /// merged proposal behind it.
    pub const RM_DELETE_BRANCH: &str = "CRUX_RM_DELETE_BRANCH";
    /// This machine's name in what it publishes, when two share a hostname.
    pub const MACHINE: &str = "CRUX_MACHINE";
    /// `0` runs the whole session-start sync before the session opens; `1`
    /// leaves all but the session's project for afterwards, even in the suite.
    pub const SYNC_BACKGROUND: &str = "CRUX_SYNC_BACKGROUND";
    /// Minutes between two refreshes of the tasks during a session.
    pub const TASKS_REFRESH_MIN: &str = "CRUX_TASKS_REFRESH_MIN";
    pub const BIN: &str = "CRUX_BIN";
    pub const CHECKS_INTERVAL: &str = "CRUX_CHECKS_INTERVAL";
    pub const COMMIT_MSG_LANG: &str = "CRUX_COMMIT_MSG_LANG";
    pub const COMMIT_MSG_SCOPE: &str = "CRUX_COMMIT_MSG_SCOPE";
    pub const CONFIG: &str = "CRUX_CONFIG";
    pub const DEFER_CD: &str = "CRUX_DEFER_CD";
    pub const DRY_RUN: &str = "CRUX_DRY_RUN";
    pub const GATE_ASSUME_YES: &str = "CRUX_GATE_ASSUME_YES";
    pub const HOME: &str = "CRUX_HOME";
    pub const IDLE_TASK_DAYS: &str = "CRUX_IDLE_TASK_DAYS";
    pub const IN_TESTS: &str = "CRUX_IN_TESTS";
    pub const MACHINE_CHECKS: &str = "CRUX_MACHINE_CHECKS";
    pub const MACHINE_CHECK_TIMEOUT: &str = "CRUX_MACHINE_CHECK_TIMEOUT";
    pub const MEMORY_IGNORE: &str = "CRUX_MEMORY_IGNORE";
    pub const MERGE_CLOSE_WORKSPACE: &str = "CRUX_MERGE_CLOSE_WORKSPACE";
    pub const MODE: &str = "CRUX_MODE";
    pub const PROFILE_REPO: &str = "CRUX_PROFILE_REPO";
    pub const PROJECTS_DIR: &str = "CRUX_PROJECTS_DIR";
    pub const REGISTRY: &str = "CRUX_REGISTRY";
    pub const REMINDER_UI: &str = "CRUX_REMINDER_UI";
    pub const REMOTE: &str = "CRUX_REMOTE";
    pub const SKILL_FILE: &str = "CRUX_SKILL_FILE";
    pub const SKILL_RUNNER: &str = "CRUX_SKILL_RUNNER";
    pub const SKILL_TOKENS: &str = "CRUX_SKILL_TOKENS";
    pub const STALE_WORKSPACE_DAYS: &str = "CRUX_STALE_WORKSPACE_DAYS";
    pub const STATE_DIR: &str = "CRUX_STATE_DIR";
    pub const STG_CONFIG: &str = "CRUX_STG_CONFIG";
    pub const STG_CONTAINER: &str = "CRUX_STG_CONTAINER";
    pub const STG_DOMAIN: &str = "CRUX_STG_DOMAIN";
    pub const STG_ROOT: &str = "CRUX_STG_ROOT";
    pub const STG_SSH: &str = "CRUX_STG_SSH";
    pub const SYNC_EVERY_MIN: &str = "CRUX_SYNC_EVERY_MIN";
    pub const SYNC_NO_INSTALL: &str = "CRUX_SYNC_NO_INSTALL";
    pub const TASKS_DIR: &str = "CRUX_TASKS_DIR";
    pub const TASKS_IDLE_HOURS: &str = "CRUX_TASKS_IDLE_HOURS";
    pub const TASKS_RETENTION_DAYS: &str = "CRUX_TASKS_RETENTION_DAYS";
    pub const TEST_SYNC_PAUSE_MS: &str = "CRUX_TEST_SYNC_PAUSE_MS";
    pub const TEST_TTY: &str = "CRUX_TEST_TTY";
    pub const TRANSCRIPTS: &str = "CRUX_TRANSCRIPTS";
    pub const UNMANAGED: &str = "CRUX_UNMANAGED";
    pub const WAIT_NUDGE_DAYS: &str = "CRUX_WAIT_NUDGE_DAYS";
}

/// Each name lives here and only here: written by hand somewhere else, the
/// day one changes the other copy keeps the old one (`crux-docs`
/// `repos/crux/conventions.md`).
#[cfg(test)]
mod tests {
    use std::path::Path;

    fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                rust_files(&p, out);
            } else if p.extension().is_some_and(|x| x == "rs") {
                out.push(p);
            }
        }
    }

    /// The code before its tests, without raw strings: those are generated
    /// scripts and texts, where a name is prose.
    fn code(text: &str) -> String {
        let text = text.split("#[cfg(test)]").next().unwrap_or("");
        let raw = regex::Regex::new(r##"(?s)r#+".*?"#+"##).unwrap();
        raw.replace_all(text, "").into_owned()
    }

    #[test]
    fn no_name_is_written_outside_this_file() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = vec![];
        rust_files(&src, &mut files);
        let literal = regex::Regex::new(r#""(CRUX_[A-Z0-9_]+"|origin"|origin/|refs/)"#).unwrap();
        let mut found = vec![];
        for f in files.iter().filter(|f| !f.ends_with("names.rs")) {
            let text = code(&std::fs::read_to_string(f).unwrap());
            for (n, line) in text.lines().enumerate() {
                for m in literal.find_iter(line) {
                    found.push(format!("{}:{} {}", f.strip_prefix(&src).unwrap().display(), n + 1, m.as_str()));
                }
            }
        }
        assert!(found.is_empty(), "names written by hand instead of taken from names.rs:\n{}", found.join("\n"));
    }

    #[test]
    fn the_tasks_tracking_ref_is_the_remote_copy_of_their_branch() {
        assert_eq!(super::git::TASKS_TRACKED, super::git::remote_branch(super::git::TASKS_BRANCH));
    }
}
