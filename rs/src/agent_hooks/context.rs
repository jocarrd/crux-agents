//! What a session is told when it starts, resumes or closes.

use super::{cwd, field, input, marker, session_or_parent, sweep};
use crate::error::Res;
use crate::task::{record, remind};
use crate::{env, files, git, person};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;

/// Inside a workspace, reminds where its task was left, once per session and
/// workspace: a compaction or coming back the next day loses it.
pub(super) fn task_context() -> Res {
    let event = input();
    let Some(here) = git::toplevel(&cwd()) else { return Ok(()) };
    if !here.to_string_lossy().contains("-ws-") {
        return Ok(());
    }
    let Some(file) = crate::task::file_for_workspace(&here.to_string_lossy()).filter(|f| f.is_file()) else {
        return Ok(());
    };
    let m = marker("task-context-", &format!("{}-{}", session_or_parent(&event), here.display()));
    if m.exists() {
        return Ok(());
    }
    let Ok(doc) = record::read(&file) else { return Ok(()) };
    let s = record::summary(&doc);
    let _ = std::fs::write(&m, "");
    let steps = if s.steps.is_empty() { String::new() } else { format!(" · steps {}", s.steps) };
    let next = if s.next.is_empty() { String::new() } else { format!(" · next: {}", s.next) };
    println!("Task '{}' · {}{steps}{next}", s.task, s.status);
    println!("Record: {} — read it before continuing; it is updated with 'crux task'.", file.display());
    Ok(())
}

/// Repeats on every message the reminder the person wrote in their profile.
/// The kernel brings no text of its own: without one this says nothing.
pub(super) fn profile_reminder() -> Res {
    let _ = input();
    if let Some(r) = person::dir().and_then(|d| person::field(&d, "reminder")).filter(|r| !r.is_empty()) {
        println!("{r}");
    }
    Ok(())
}

/// One line on closing, not the whole report: a warning that takes half the
/// screen is learned to be ignored in two days.
pub(super) fn memory_guard() -> Res {
    // It does not read the event: it has never needed it, and the agent may
    // keep its stdin open.
    let _ = crate::cmd::memory::run(&["--brief".into()]);
    Ok(())
}

/// The machine brought up to date and the open tasks, as the person sees them
/// and as the agent is told not to push them.
fn synced_and_reminder(cwd: &str) -> (String, Option<Value>) {
    let me = std::env::current_exe().unwrap_or_default();
    let r = crate::sh::capture_cmd(
        std::process::Command::new(&me).args(["sync", "--hook"]).stdin(std::process::Stdio::null()),
    );
    let synced = r.out();
    let dir = if cwd.is_empty() { self::cwd() } else { PathBuf::from(cwd) };
    (synced, remind::reminder(&dir, 6))
}

/// When a session opens, resumes or is cleared. On a compaction it stays
/// quiet: the session is halfway through some work.
pub(super) fn session_sync() -> Res {
    let event = input();
    if field(&event, "source") == "compact" {
        return Ok(());
    }
    let session = field(&event, "session_id");
    if !session.is_empty() {
        let dir = env::state_dir().join("sessions");
        let _ = files::mkdir_private(&dir);
        let _ = std::fs::write(dir.join(safe_id(&session)), "");
    }
    let (synced, reminder) = synced_and_reminder(&field(&event, "cwd"));
    if synced.is_empty() && reminder.is_none() {
        return Ok(());
    }
    // With the Claude Code mod it draws the reminder as a panel; the model
    // still gets it the same.
    let panel = env::var("CRUX_REMINDER_UI").as_deref() == Some("panel");
    let r_user =
        reminder.as_ref().and_then(|r| r.get("user")).and_then(Value::as_str).filter(|_| !panel).map(String::from);
    let r_agent = reminder.as_ref().and_then(|r| r.get("agent")).and_then(Value::as_str).map(String::from);
    let user: Vec<String> = [r_user, Some(synced.clone())].into_iter().flatten().filter(|s| !s.is_empty()).collect();
    let agent: Vec<String> = [Some(synced), r_agent].into_iter().flatten().filter(|s| !s.is_empty()).collect();
    let mut out = serde_json::Map::new();
    if !user.is_empty() {
        out.insert("systemMessage".into(), json!(user.join("\n\n")));
    }
    out.insert(
        "hookSpecificOutput".into(),
        json!({"hookEventName": "SessionStart", "additionalContext": agent.join("\n\n")}),
    );
    print!("{}", Value::Object(out));
    Ok(())
}

fn safe_id(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect()
}

/// A session resumed hours later does not go through SessionStart: here the
/// gap since the last message is measured and, over the limit, the same is
/// done as on opening.
pub(super) fn session_idle() -> Res {
    let event = input();
    let session = field(&event, "session_id");
    if session.is_empty() {
        return Ok(());
    }
    let dir = env::state_dir().join("sessions");
    if files::mkdir_private(&dir).is_err() {
        return Ok(());
    }
    sweep(&dir, "", Duration::from_secs(31 * 86400));
    let m = dir.join(safe_id(&session));
    let hours: u64 = env::var("CRUX_TASKS_IDLE_HOURS").and_then(|h| h.parse().ok()).unwrap_or(3);
    // No marker means the first message: session start took care of it.
    let stopped = std::fs::metadata(&m)
        .and_then(|x| x.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|a| a > Duration::from_secs(hours * 3600));
    let _ = std::fs::write(&m, "");
    if !stopped {
        return Ok(());
    }
    let (synced, reminder) = synced_and_reminder(&field(&event, "cwd"));
    if synced.is_empty() && reminder.is_none() {
        return Ok(());
    }
    let intro = format!("You are back in this session after more than {hours} h.");
    let r_user = reminder.as_ref().and_then(|r| r.get("user")).and_then(Value::as_str).map(String::from);
    let r_agent = reminder.as_ref().and_then(|r| r.get("agent")).and_then(Value::as_str).map(String::from);
    let user: Vec<String> =
        [Some(intro.clone()), r_user, Some(synced.clone())].into_iter().flatten().filter(|s| !s.is_empty()).collect();
    let agent: Vec<String> =
        [Some(intro), Some(synced), r_agent].into_iter().flatten().filter(|s| !s.is_empty()).collect();
    print!(
        "{}",
        json!({"systemMessage": user.join("\n\n"), "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": agent.join("\n\n")}})
    );
    Ok(())
}
