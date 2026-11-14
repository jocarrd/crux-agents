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

/// The names git gives things, as crux uses them.
pub mod git {
    /// The remote crux publishes to and reads from.
    pub const REMOTE: &str = "origin";
    /// Where local branches live.
    pub const HEADS: &str = "refs/heads/";

    /// The full ref of a local branch.
    pub fn head(branch: &str) -> String {
        format!("{HEADS}{branch}")
    }
}

/// The environment variables a person sets to change what crux does.
pub mod vars {
    /// `0` keeps tasks and what archiving writes on this machine; `1` publishes
    /// them even inside the test suite.
    pub const TASK_SYNC: &str = "CRUX_TASK_SYNC";
    /// Lets `workspace rm` delete a branch already in the main one with no
    /// merged proposal behind it.
    pub const RM_DELETE_BRANCH: &str = "CRUX_RM_DELETE_BRANCH";
}
