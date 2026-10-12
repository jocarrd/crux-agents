//! The names of the files crux writes and reads, in one place: spelled in
//! two places, one day they differ and a file is looked for where it is not.

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
