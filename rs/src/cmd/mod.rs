//! The subcommands. Each one takes its arguments and returns how it ended.

use crate::error::{Exit, Res};

pub mod add_repo;
pub mod adopt;
pub mod archive;
pub mod bootstrap;
pub mod checks;
pub mod clone;
pub mod doctor;
pub mod hooks;
pub mod init;
pub mod install;
pub mod link;
pub mod machine;
pub mod mcp;
pub mod memory;
pub mod merge;
pub mod profile;
pub mod prose;
pub mod release;
pub mod review;
pub mod setup;
pub mod ship;
pub mod skill;
pub mod status;
pub mod stg;
pub mod sync;
pub mod task;
pub mod upgrade;
pub mod usage;
pub mod visual;
pub mod workspace;

pub fn dispatch(argv: &[String]) -> i32 {
    let (name, rest) = match argv.split_first() {
        Some((n, r)) => (n.as_str(), r),
        None => ("help", &[][..]),
    };
    if matches!(rest.first().map(String::as_str), Some("--help" | "-h")) && help(name) {
        return 0;
    }
    // The binary alone, from npm or a download, carries the kernel but has not
    // laid it out: `init` answered "unknown profile: multi-repo".
    let standalone =
        matches!(name, "version" | "--version" | "-v" | "help" | "-h" | "--help" | "install" | "setup" | "prose")
            || name.starts_with("__");
    if !standalone && crate::env::crux_home().is_none_or(|h| !h.is_dir()) {
        crate::ui::err("crux is not installed on this machine yet");
        crate::ui::info("crux install    lays out the kernel this binary carries");
        crate::ui::info("crux setup      the same, step by step: account, remote, profile and projects");
        return 1;
    }
    let result: Res = match name {
        "version" | "--version" | "-v" => version(),
        "help" | "-h" | "--help" => {
            println!("{USAGE}");
            Ok(())
        }
        "__fn" => crate::script_api::run(rest),
        "__install" | "install" => install::run(rest),
        "setup" => setup::run(rest),
        "adopt" => adopt::run(rest),
        "add-repo" => add_repo::run(rest),
        "merge" => merge::run(rest),
        "archive" => archive::run(rest),
        "unarchive" => {
            let mut a = vec!["--undo".to_string()];
            a.extend(rest.iter().cloned());
            archive::run(&a)
        }
        "review" => review::run(rest),
        "release" => release::run(rest),
        "clone" => clone::run(rest),
        "checks" => checks::run(rest),
        "machine" => machine::run(rest),
        "mcp" => mcp::run(rest),
        "link" => link::run(rest),
        "init" => init::run(rest),
        "profile" => profile::run(rest),
        "bootstrap" => bootstrap::run(rest),
        "status" => status::run(rest),
        "visual" => visual::run(rest),
        "usage" => usage::run(rest),
        "prose" => prose::run(rest),
        "skill" => skill::run(rest),
        "memory" => memory::run(rest),
        "ship" => ship::run(rest),
        "task" => task::run(rest),
        "hooks" => hooks::run(rest),
        "doctor" => doctor::run(rest),
        "sync" => sync::run(rest),
        "workspace" => workspace::run(rest),
        "__check" => crate::checks::internal(rest),
        "__skill-scenarios" => skill::scenarios_report(rest),
        "stg" => stg::run(rest),
        "__check-mcp" => {
            for f in crate::mcp::check(std::path::Path::new(rest.first().map(String::as_str).unwrap_or("."))) {
                println!("{f}");
            }
            Ok(())
        }
        "upgrade" => upgrade::run(rest),
        "hook" => crate::agent_hooks::run(rest),
        "__task" => crate::task::internal(rest),
        "__task-sync" => crate::task::internal_sync(rest),
        other => {
            crate::ui::err(format!("unknown subcommand: {other}"));
            println!();
            println!("{USAGE}");
            Err(Exit(1))
        }
    };
    match result {
        Ok(()) => 0,
        Err(Exit(code)) => code,
    }
}

/// Another crux command, with the terminal attached.
pub fn call(name: &str, args: &[&str]) -> i32 {
    crate::sh::status(&mut self_command(name, args))
}

/// The same, from a directory and without showing its output.
pub fn call_quiet(dir: &std::path::Path, name: &str, args: &[&str]) -> crate::sh::Run {
    crate::sh::capture_cmd(self_command(name, args).current_dir(dir))
}

/// Another crux command, in a process of its own: what it prints and how it
/// ends stay its own, so a step that fails cannot take the caller down.
fn self_command(name: &str, args: &[&str]) -> std::process::Command {
    let exe = std::env::current_exe().unwrap_or_else(|_| "crux".into());
    let mut c = std::process::Command::new(exe);
    c.arg(name).args(args);
    if let Some(home) = crate::env::crux_home() {
        c.env("CRUX_HOME", home);
    }
    c
}

pub(crate) fn help(name: &str) -> bool {
    match crate::help::text(name) {
        Some(t) => {
            println!("{t}");
            true
        }
        None => false,
    }
}

const USAGE: &str = "crux — kernel of the agent work system

  crux setup            gets this machine ready, step by step
  crux init <project>   creates the docs repo of a new project
  crux clone <project>  brings a whole project to this machine
  crux bootstrap        gets a new machine ready: all projects
  crux install          lays out the kernel this binary carries on this machine
  crux adopt [dir]      registers a docs repo that already exists
  crux add-repo <repo>  registers a new repo in the project
  crux archive <repo>   marks a repo as archived: out of production, kept
  crux unarchive <repo> brings an archived repo back
  crux review           gathers the material to review a proposal
  crux checks [n]       waits for a proposal's CI and fetches the log of what fails
  crux merge <n>        merges a proposal, stating first which one and from which repo
  crux link [dir]       generates and verifies the pointers of the code repos
  crux workspace ...    isolated spaces to work in parallel
  crux task ...         the task record: steps, next step, evidence
  crux ship ...         the quality gate, with a receipt of what was run
  crux visual ...       the approved visual review, with receipt and section in the proposal
  crux hooks ...        hooks the standard into session end and commit
  crux mcp ...          the MCP servers the project declares
  crux stg ...          publishes a built folder to a keyed staging
  crux usage            which skills are really used
  crux prose check <f>  counts the markers of a model-generated text
  crux skill test <sk>  tests a skill with its scenarios and compares it with another version
  crux memory [--check] agent memories that should be in git
  crux profile ...      the person's memory: a repo of its own that every agent loads
  crux status [--check] what is open right now across all projects
  crux sync [--leave]   brings what is on this machine up to date; nothing trapped when you leave
  crux doctor [dir]     verifies conformity with the standard
  crux doctor --machine verifies that this machine can handle everything
  crux upgrade [dir]    re-materializes the kernel at the current version
  crux release <ver>    publishes a version, verifying whoever consumes it
  crux version          kernel version and its path

Without a directory argument, commands operate on the docs repo they find
walking up from the current directory.";

fn version() -> Res {
    // The binary alone, as npm or a download hands it over: it knows its own
    // version, and the next step is to lay out the kernel it carries.
    let Some(home) = crate::env::crux_home() else {
        println!("crux {} — not installed on this machine yet: crux install", install::packed_version());
        return Ok(());
    };
    println!("crux {} — {}", crate::env::crux_version(), home.display());
    Ok(())
}
