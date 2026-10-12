//! The reminder of the cycle on the main branch of a managed repo.

use super::{cwd, input, marker, session_or_parent};
use crate::error::Res;
use crate::names;
use crate::{env, git};
use std::path::Path;

/// Reminds about the cycle when about to work on the main branch of a managed
/// repo, once per session. The signal is the state —where you are and on which
/// branch—, not the prompt's words: guessing intent warns when it should not.
pub(super) fn cycle_guard() -> Res {
    let event = input();
    let here = cwd();
    if !git::ok(&here, &["rev-parse", "--git-dir"]) || here.to_string_lossy().contains("-ws-") {
        return Ok(());
    }
    let Some(branch) = git::out(&here, &["rev-parse", "--abbrev-ref", "HEAD"]) else { return Ok(()) };
    let main = git::out(&here, &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        .map(|b| b.trim_start_matches("origin/").to_string())
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "main".into());
    if branch != main {
        return Ok(());
    }
    // Managed: the kernel itself, or any repo under the projects root. The
    // root comes from the configuration: a fixed folder would leave the guard
    // silent on a machine with another convention.
    let config = env::config_file();
    let kernel = env::config_value_in(&config, "CRUX_HOME").unwrap_or_default();
    let mut root = env::var("CRUX_PROJECTS_DIR")
        .or_else(|| env::config_value_in(&config, "CRUX_PROJECTS_DIR"))
        .unwrap_or_default();
    if root.is_empty() && !kernel.is_empty() {
        root = Path::new(&kernel).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    }
    // A trailing slash would leave the pattern unmatched and the guard silent.
    let root = root.trim_end_matches('/').to_string();
    let Some(top) = git::toplevel(&here) else { return Ok(()) };
    let top_s = top.to_string_lossy().into_owned();
    // In the docs repo you work on main and push directly.
    let base = top.file_name().unwrap_or_default().to_string_lossy().into_owned();
    if top.join(names::CONTRACT).is_file() && (base.ends_with("-docs") || base == "docs") {
        return Ok(());
    }
    let mut managed = !kernel.is_empty() && top_s == kernel;
    if !managed && !root.is_empty() {
        managed = top_s.strip_prefix(&format!("{root}/")).is_some_and(|rel| !rel.is_empty());
    }
    // The way out for a foreign clone left under the root to read it.
    if managed {
        let foreign =
            env::var("CRUX_UNMANAGED").or_else(|| env::config_value_in(&config, "CRUX_UNMANAGED")).unwrap_or_default();
        for pattern in foreign.split(':').filter(|p| !p.is_empty()) {
            if crate::files::glob_match(pattern, &top_s) {
                return Ok(());
            }
        }
    }
    if !managed {
        return Ok(());
    }
    // Once per session: repeated every turn it turns into noise.
    let m = marker("cycle-guard-", &format!("{}-{top_s}", session_or_parent(&event)));
    if m.exists() {
        return Ok(());
    }
    crate::files::touch_marker(&m, "");
    print!(
        "You are on '{branch}', the main branch of {base}, which is a repo
managed by crux. If what comes next is a development task, the work enters
through its own workspace and leaves as a proposal:

  crux workspace new <task>        isolated branch, worktree and runtime
  /ship                            the gate before committing
  crux workspace finish <task>     pushes the branch and opens the proposal

Isolating after starting forces moving changes already made between branches,
which is exactly the mess this avoids. For questions, exploration or a typo,
carry on as is: the cycle does not apply to everything.
"
    );
    Ok(())
}
