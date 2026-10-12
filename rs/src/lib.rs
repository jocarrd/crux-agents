//! crux, the kernel of the agent work system. ARCHITECTURE.md, at the root of
//! the repo, is the map; in short, three layers, each using only the ones
//! below it:
//!
//! - Entry points: `cmd` (one module per command), `agent_hooks` (what an
//!   agent runs on its events) and `script_api` (single functions for the
//!   shell scripts that remain).
//! - The domain: the project and its contract (`project`, `policy`, `checks`,
//!   `mcp`), the person's profile (`person`), workspaces (`registry`), tasks
//!   (`task`), and what crux writes into other people's files (`template`,
//!   `skills`, `secrets`).
//! - The foundation: where things live (`env`), files, git and other programs
//!   (`files`, `git`, `sh`, `signals`), arguments (`args`), output (`ui`,
//!   `help`) and how a command ends (`error`).

/// A regular expression compiled once, the first time this line runs. A
/// literal that does not compile is a bug in crux, so it panics there.
#[macro_export]
macro_rules! regex {
    ($re:expr $(,)?) => {{
        static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        RE.get_or_init(|| regex::Regex::new($re).expect("a literal regex compiles"))
    }};
}

pub mod agent_hooks;
pub mod args;
pub mod checks;
pub mod cmd;
pub mod env;
pub mod error;
pub mod files;
pub mod git;
pub mod help;
pub mod mcp;
pub mod names;
pub mod person;
pub mod policy;
pub mod project;
pub mod registry;
pub mod script_api;
pub mod secrets;
pub mod sh;
pub mod signals;
pub mod skills;
pub mod task;
pub mod template;
pub mod ui;
