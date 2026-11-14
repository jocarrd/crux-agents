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

    pub fn head(branch: &str) -> String {
        format!("{HEADS}{branch}")
    }

    pub fn published_on_remote(machine: &str, branch: &str) -> String {
        format!("{PUBLISHED_ON_REMOTE}{machine}/{branch}")
    }

    pub fn published_here(branch: &str) -> String {
        format!("{PUBLISHED_HERE}{branch}")
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
}
