//! The hooks an agent runs: `crux hook <name>`, reading the agent's event as
//! JSON on stdin. Exit 0 lets it through (stdout becomes context where the
//! agent takes it); exit 2 stops it, with the reason on stderr.
//!
//! They run on every message and every tool call, which is why they live in
//! the binary: a hook that costs a second is one people uninstall. git's
//! commit-msg hook is here too (`commit_msg`): it takes a file, not an event.

use crate::error::{exit, Exit, Res};
use crate::{env, files};
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

fn input() -> Value {
    let mut raw = String::new();
    if !std::io::IsTerminal::is_terminal(&std::io::stdin()) {
        let _ = std::io::stdin().read_to_string(&mut raw);
    }
    serde_json::from_str(&raw).unwrap_or(Value::Null)
}

fn field(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn session_or_parent(event: &Value) -> String {
    let s = field(event, "session_id");
    if s.is_empty() {
        // SAFETY: getppid has no preconditions.
        unsafe { libc::getppid() }.to_string()
    } else {
        s
    }
}

/// Markers go to ~/.crux/state and not to /tmp: their names would expose the
/// repo path, that is the client and the task, to anyone on the machine.
fn marker(prefix: &str, key: &str) -> PathBuf {
    let state = env::home().join(".crux/state");
    let _ = files::mkdir_private(&state);
    let id: String = crate::cmd::ship::cksum(key.as_bytes())
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    sweep(&state, prefix, Duration::from_secs(3 * 86400));
    state.join(format!("{prefix}{id}"))
}

fn sweep(dir: &Path, prefix: &str, older: Duration) {
    for e in std::fs::read_dir(dir).map(|e| e.flatten().collect::<Vec<_>>()).unwrap_or_default() {
        let n = e.file_name().to_string_lossy().into_owned();
        if n.starts_with(prefix)
            && e.path().is_file()
            && e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|a| a > older)
        {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

fn cwd() -> PathBuf {
    std::env::current_dir().unwrap_or_default()
}

fn stop(msg: &str) -> Res {
    eprint!("{msg}");
    exit(2)
}

mod commit_msg;
pub use commit_msg::Scope;
mod context;
mod cycle;
mod doc_sync;
mod guards;

/// The agent hooks crux installs. Each knows the event that runs it, the
/// tools it is limited to and what it does: the dispatcher and the installer
/// read them from here, so a hook cannot exist in one and not the other.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Hook {
    DocSync,
    CycleGuard,
    MemoryGuard,
    TaskContext,
    WorktreeGuard,
    DestructiveGuard,
    ProposalGuard,
    WaitGuard,
    SessionSync,
    SessionIdle,
    ProfileReminder,
}

/// How a hook is registered in Claude Code's settings.
pub struct Registration {
    pub event: &'static str,
    /// Names it had before, so reinstalling replaces them instead of adding.
    pub previous: &'static str,
    /// The tools it runs for; empty for all.
    pub matcher: &'static str,
    pub what: &'static str,
}

impl Hook {
    pub const ALL: [Hook; 11] = [
        Hook::DocSync,
        Hook::CycleGuard,
        Hook::MemoryGuard,
        Hook::TaskContext,
        Hook::WorktreeGuard,
        Hook::DestructiveGuard,
        Hook::ProposalGuard,
        Hook::WaitGuard,
        Hook::SessionSync,
        Hook::SessionIdle,
        Hook::ProfileReminder,
    ];

    /// The name in `crux hook <name>` and in its launcher's file name.
    pub fn name(self) -> &'static str {
        match self {
            Hook::DocSync => "doc-sync",
            Hook::CycleGuard => "cycle-guard",
            Hook::MemoryGuard => "memory-guard",
            Hook::TaskContext => "task-context",
            Hook::WorktreeGuard => "worktree-guard",
            Hook::DestructiveGuard => "destructive-guard",
            Hook::ProposalGuard => "proposal-guard",
            Hook::WaitGuard => "wait-guard",
            Hook::SessionSync => "session-sync",
            Hook::SessionIdle => "session-idle",
            Hook::ProfileReminder => "profile-reminder",
        }
    }

    pub fn parse(name: &str) -> Option<Hook> {
        Hook::ALL.into_iter().find(|h| h.name() == name)
    }

    pub fn registration(self) -> Registration {
        let r = |event, previous, matcher, what| Registration { event, previous, matcher, what };
        match self {
            Hook::DocSync => {
                r("Stop", "doc-sync|check-doc-sync", "", "hook for documentation drift when closing a session")
            }
            Hook::CycleGuard => {
                r("UserPromptSubmit", "cycle-guard", "", "hook for the cycle when starting on the main branch")
            }
            Hook::MemoryGuard => {
                r("Stop", "memory-guard", "", "hook for unpromoted project memories when closing a session")
            }
            Hook::TaskContext => {
                r("UserPromptSubmit", "task-context", "", "hook that brings the task back when resuming a workspace")
            }
            Hook::WorktreeGuard => {
                r("PreToolUse", "worktree-guard", "Bash", "hook that stops manual deletion of a registered workspace")
            }
            Hook::DestructiveGuard => r(
                "PreToolUse",
                "destructive-guard",
                "Bash|Read|Edit|Write|MultiEdit|NotebookEdit",
                "hook that stops destructive commands and reading private keys",
            ),
            Hook::ProposalGuard => r(
                "PreToolUse",
                "proposal-guard",
                "Bash",
                "hook that stops opening a proposal by hand without the gate receipt",
            ),
            Hook::WaitGuard => {
                r("PreToolUse", "wait-guard", "Bash", "hook that sends what takes minutes to the background")
            }
            Hook::SessionSync => r(
                "SessionStart",
                "session-sync",
                "",
                "hook that syncs the machine with the remote when opening a session",
            ),
            Hook::SessionIdle => r(
                "UserPromptSubmit",
                "session-idle",
                "",
                "hook that does the same when returning to a session idle for hours",
            ),
            Hook::ProfileReminder => r(
                "UserPromptSubmit",
                "profile-reminder",
                "",
                "hook that repeats the reminder the person set in their profile",
            ),
        }
    }

    fn run(self) -> Res {
        match self {
            Hook::DocSync => doc_sync::doc_sync(),
            Hook::CycleGuard => cycle::cycle_guard(),
            Hook::MemoryGuard => context::memory_guard(),
            Hook::TaskContext => context::task_context(),
            Hook::WorktreeGuard => guards::worktree_guard(),
            Hook::DestructiveGuard => guards::destructive_guard(),
            Hook::ProposalGuard => guards::proposal_guard(),
            Hook::WaitGuard => guards::wait_guard(),
            Hook::SessionSync => context::session_sync(),
            Hook::SessionIdle => context::session_idle(),
            Hook::ProfileReminder => context::profile_reminder(),
        }
    }
}

/// Codex only takes a UserPromptSubmit hook's context as JSON: plain text is
/// wrapped here. The hook does not change, and its exit code and stderr pass
/// through as they are.
fn codex_context(argv: &[String]) -> Res {
    let (Some(event), Some(hook)) = (argv.first(), argv.get(1)) else { return exit(2) };
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    let mut child = match std::process::Command::new("bash")
        .arg(hook)
        .args(&argv[2..])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return exit(127),
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = std::io::Write::write_all(&mut stdin, &raw);
    }
    let out = child.wait_with_output().map_err(|_| Exit(1))?;
    let text = String::from_utf8_lossy(&out.stdout).trim_end_matches('\n').to_string();
    let code = out.status.code().unwrap_or(1);
    if code != 0 {
        if !text.is_empty() {
            println!("{text}");
        }
        return exit(code);
    }
    if text.is_empty() {
        return Ok(());
    }
    // If the hook already speaks JSON, it is respected.
    if serde_json::from_str::<Value>(&text).is_ok() {
        println!("{text}");
        return Ok(());
    }
    println!("{}", json!({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}));
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    let name = argv.first().map(String::as_str).unwrap_or("");
    if let Some(hook) = Hook::parse(name) {
        return hook.run();
    }
    match name {
        "codex-context" => codex_context(rest),
        "commit-msg" => commit_msg::commit_msg(rest),
        other => {
            eprintln!("unknown hook: {other}");
            exit(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::guards::runnable;
    use crate::files::glob_match;

    #[test]
    fn a_heredoc_body_is_not_run() {
        let t = runnable("git commit -F - <<'EOF'\nreset --hard\nEOF\n", true, true);
        assert!(!t.contains("reset"));
    }

    #[test]
    fn shell_globs_match() {
        assert!(glob_match("/home/*/clients/*", "/home/a/clients/x"));
        assert!(!glob_match("/home/*/clients", "/home/a/other"));
    }
}
