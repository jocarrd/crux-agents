//! Listing the workspaces, with where each one's task was left.

use crate::error::Res;
use crate::{env, git, registry};
use std::path::Path;

fn since(p: &Path) -> String {
    let Ok(age) = std::fs::metadata(p).and_then(|m| m.modified()).map(|t| t.elapsed().unwrap_or_default()) else {
        return String::new();
    };
    match age.as_secs() / 86400 {
        0 => "today".into(),
        1 => "yesterday".into(),
        d => format!("{d} days ago"),
    }
}

/// What matters on returning to a workspace is where it was left: the status
/// and next step of its task, not just the slot.
fn task_line(w: &registry::Workspace) -> String {
    if w.task.is_empty() || w.project.is_empty() {
        return String::new();
    }
    let Ok(t) = std::fs::read_to_string(env::tasks_dir().join(&w.project).join(format!("{}.md", w.task))) else {
        return String::new();
    };
    let status = crate::regex!(r"(?m)^status: (.*)$").captures(&t).map(|c| c[1].to_string()).unwrap_or_default();
    let next_section =
        crate::regex!(r"(?m)^## (?:Next step|Siguiente paso)$").split(&t).nth(1).unwrap_or("").to_string();
    let next_section = crate::regex!(r"(?m)^## ").split(&next_section).next().unwrap_or("").to_string();
    let next = crate::regex!(r"<!--[\s\S]*?-->")
        .replace_all(&next_section, "")
        .trim()
        .split('\n')
        .next()
        .unwrap_or("")
        .to_string();
    let pending = crate::regex!(r"(?m)^- \[ \] (T\d+ .*)$").captures(&t).map(|c| c[1].to_string()).unwrap_or_default();
    let shown = if next.is_empty() { pending } else { next };
    let tail =
        if shown.is_empty() { String::new() } else { format!(" · {}", shown.chars().take(60).collect::<String>()) };
    format!("{status}{tail}")
}

pub fn list(argv: &[String]) -> Res {
    let all = argv.first().map(String::as_str) == Some("--all");
    let _ = registry::init();
    let here = if all { None } else { git::toplevel(&std::env::current_dir().unwrap_or_default()) };
    let mut rows = registry::read().unwrap_or_default();
    let total = rows.len();
    if let Some(here) = &here {
        let here_s = here.to_string_lossy().into_owned();
        // From inside a workspace, "this repo" is the repo it hangs from.
        let repo = rows.iter().find(|w| w.path == here_s).map(|w| w.repo.clone()).unwrap_or(here_s);
        rows.retain(|w| w.repo == repo);
    }
    if rows.is_empty() {
        if total > 0 {
            println!("no workspaces in this repo ({total} in others: crux workspace list --all)");
        } else {
            println!("no active workspaces");
        }
        return Ok(());
    }
    for w in &rows {
        let alive = Path::new(&w.path).exists();
        let tail =
            if alive { since(Path::new(&w.path)) } else { "no worktree — remove it with: crux workspace gc".into() };
        println!("{:<16} slot {:>2}  ports {}-{}  {:<14}  {}", w.name, w.slot, w.ports.0, w.ports.1, tail, w.path);
        let t = task_line(w);
        if !t.is_empty() {
            println!("{:<16} task {}: {t}", "", w.task);
        }
    }
    Ok(())
}
