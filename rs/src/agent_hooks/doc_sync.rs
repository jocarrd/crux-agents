//! The documentation gate at the close of a session.

use super::{cwd, field, input, stop, sweep};
use crate::error::Res;
use crate::names;
use crate::{env, git, project};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// At the close of a session that moved something, it blocks once and asks
/// what of what happened stays in git: a session that measures, discovers a
/// risk and commits clean otherwise closes with all of that lost.
pub(super) fn doc_sync() -> Res {
    let event = input();
    // The turn that already comes from a blocked Stop: blocking again loops.
    if event.get("stop_hook_active") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let session = {
        let s = field(&event, "session_id");
        if s.is_empty() {
            "no-id".to_string()
        } else {
            s
        }
    };
    let config = env::config_file();
    let mut root = env::var("CRUX_PROJECTS_DIR")
        .or_else(|| env::config_value_in(&config, "CRUX_PROJECTS_DIR"))
        .unwrap_or_default();
    if root.is_empty() {
        if let Some(k) = env::config_value_in(&config, "CRUX_HOME") {
            root = Path::new(&k).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        }
    }
    if root.is_empty() {
        return Ok(());
    }
    let here = cwd();
    let Some(rel) = here.to_string_lossy().strip_prefix(&format!("{root}/")).map(String::from) else { return Ok(()) };
    let mut parts = rel.split('/');
    let Some(project_name) = parts.next().filter(|p| !p.is_empty()) else { return Ok(()) };
    let repo = parts.next().unwrap_or(project_name);
    let root = PathBuf::from(&root);
    let docs = root.join(project_name).join(format!("{project_name}-docs"));
    if !docs.join(names::CONTRACT).is_file() {
        return Ok(());
    }
    let drift = crate::checks::drift(&docs);
    // Touched files that the docs mention by name.
    let mut referenced = vec![];
    let repo_docs = docs.join("repos").join(repo);
    if repo_docs.is_dir() {
        let skip = crate::regex!(r"(\.lock|lock\.yaml|lock\.json|tsbuildinfo|\.log)$|(^|/)\.env");
        let texts: Vec<String> = walk_text(&repo_docs);
        for l in git::out(&here, &["status", "--porcelain"]).unwrap_or_default().lines() {
            if l.starts_with("??") {
                continue;
            }
            let Some(f) = l.split_whitespace().nth(1) else { continue };
            if skip.is_match(f) {
                continue;
            }
            let base = f.rsplit('/').next().unwrap_or(f);
            if texts.iter().any(|t| t.contains(f)) {
                referenced.push(format!("  - {f} (referenced by path)"));
            } else if texts.iter().any(|t| t.contains(&format!("`{base}`"))) {
                referenced.push(format!("  - {f} (referenced by name)"));
            }
        }
    }
    // Asking in empty sessions is the fastest way to get the hook uninstalled.
    let mut activity = !drift.is_empty() || !referenced.is_empty();
    if !activity {
        activity = project::subdirs(&root.join(project_name)).iter().any(|d| {
            let dir = root.join(project_name).join(d);
            dir.join(".git").is_dir()
                && !git::out(&dir, &["log", "-1", "--since=12 hours ago", "--format=%h"]).unwrap_or_default().is_empty()
        });
    }
    if !activity {
        return Ok(());
    }
    let state = env::home().join(".crux/state");
    let _ = std::fs::create_dir_all(&state);
    let id: String =
        session.chars().map(|c| if c.is_ascii_alphanumeric() || "_.-".contains(c) { c } else { '_' }).collect();
    let m = state.join(format!("doc-gate-{id}"));
    if m.is_file() {
        return Ok(());
    }
    let _ = std::fs::write(&m, "");
    sweep(&state, "doc-gate-", Duration::from_secs(3 * 86400));
    let mut msg = format!(
        "DOCUMENTATION GATE — project {project_name}\n\nThis session has moved things. Before closing, answer in one line what\nof what happened stays in {project_name}-docs and what does not.\n"
    );
    if !drift.is_empty() {
        msg.push_str("\nMeasured drift:\n");
        for l in &drift {
            msg.push_str(&format!("  {l}\n"));
        }
    }
    if !referenced.is_empty() {
        msg.push_str("\nTouched files that the documentation mentions:\n");
        for l in &referenced {
            msg.push_str(&format!("{l}\n"));
        }
    }
    msg.push_str(
        "
Go over the conversation, not just the diff. What gets lost is not usually a
file, it is what was measured, decided or discovered and never was a file:

  - decision with discarded alternatives ........ decisions/ (ADR)
  - something measured that would be costly to repeat ... repos/<repo>/ or operations/
  - infrastructure or deployment gotcha ......... operations/
  - new risk .................................... operations/open-risks.md
  - open question that has been resolved ........ where the question was
  - state of a repo that has changed ............ repos/<repo>/notes.md

If nothing from the session fits, say so explicitly and close: the answer \"there
is nothing to promote\" is valid, but it has to be an answer, not an oversight.
If something fits, use /promote-to-docs now and commit before closing.
",
    );
    stop(&msg)
}

fn walk_text(dir: &Path) -> Vec<String> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).map(|e| e.flatten().collect::<Vec<_>>()).unwrap_or_default() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if let Ok(t) = std::fs::read_to_string(&p) {
                out.push(t);
            }
        }
    }
    out
}
