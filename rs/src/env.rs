//! Where things live on this machine: the kernel, the projects root, the
//! machine config and the local state. Every path the commands use comes from
//! here, and every one can be redirected by an environment variable, which is
//! how the test suite keeps its sandboxes away from the real machine.

use crate::names;
use std::path::{Path, PathBuf};

/// The variable, and the machine config key, that says where projects live.
pub const PROJECTS_DIR_KEY: &str = "CRUX_PROJECTS_DIR";
/// Under $HOME, when nobody has said otherwise.
pub const DEFAULT_PROJECTS_DIR: &str = "Projects";

pub fn var(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

pub fn home() -> PathBuf {
    var("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// The machine config, `~/.crux/config`: shell-style `KEY="value"` lines.
pub fn config_file() -> PathBuf {
    home().join(".crux/config")
}

/// The same file, but redirectable with CRUX_CONFIG. Only the remote template
/// has always honoured that variable; the rest read the file in $HOME.
pub fn config_file_redirectable() -> PathBuf {
    var("CRUX_CONFIG").map(PathBuf::from).unwrap_or_else(config_file)
}

/// The last `KEY=` line of a config file, without quotes.
pub fn config_value_in(file: &Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(file).ok()?;
    let prefix = format!("{key}=");
    text.lines().rfind(|l| l.starts_with(&prefix)).map(|l| l[prefix.len()..].replace('"', "")).filter(|v| !v.is_empty())
}

/// A machine preference: it belongs to the user, not to the project, so each
/// person closes their cycle as they like without touching the contract.
pub fn preference(key: &str, default: &str) -> String {
    config_value_in(&config_file(), key).unwrap_or_else(|| default.to_string())
}

/// A yes/no machine preference; `default` when the config does not say.
pub fn preference_flag(key: &str, default: bool) -> bool {
    config_value_in(&config_file(), key).map_or(default, |v| v == "true")
}

/// The kernel: the environment's, the one this binary belongs to, or the one
/// the machine config names. The binary belongs to the kernel it sits in
/// —<kernel>/bin/crux-core installed, <kernel>/rs/target/... built—, so a
/// symlink on the PATH needs no variable to find it.
pub fn crux_home() -> Option<PathBuf> {
    if let Some(h) = var("CRUX_HOME") {
        return Some(PathBuf::from(h));
    }
    if let Some(k) = own_kernel() {
        return Some(k);
    }
    config_value_in(&config_file(), "CRUX_HOME").map(PathBuf::from)
}

fn own_kernel() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    exe.ancestors()
        .skip(1)
        .find(|d| d.join(names::VERSION).is_file() && d.join(names::STANDARD).is_file())
        .map(Path::to_path_buf)
}

pub fn crux_version() -> String {
    crux_home()
        .and_then(|h| std::fs::read_to_string(h.join(names::VERSION)).ok())
        .map(|v| v.split_whitespace().collect::<String>())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "unknown".into())
}

/// The kernel clone lives at <root>/crux, or inside a project of its own,
/// <root>/crux/crux, next to its docs repo like any other project's code.
pub fn root_of_kernel_clone(clone: &Path) -> PathBuf {
    let parent = clone.parent().unwrap_or(Path::new("/"));
    if parent.file_name() == clone.file_name() {
        parent.parent().unwrap_or(Path::new("/")).to_path_buf()
    } else {
        parent.to_path_buf()
    }
}

/// The clone the kernel is updated from, in either layout.
pub fn kernel_clone(root: &Path) -> Option<PathBuf> {
    [root.join("crux/crux"), root.join("crux")]
        .into_iter()
        .find(|c| c.join("install.sh").is_file() && c.join(names::VERSION).is_file())
}

/// No folder is assumed: the most reliable hint is that the kernel itself
/// lives inside the root. Without this, on a machine with another convention
/// the commands that walk every project do not fail: they report zero, which
/// is worse because it looks like data.
pub fn projects_root() -> PathBuf {
    if let Some(d) = declared_projects_root() {
        return PathBuf::from(d);
    }
    if let Some(h) = crux_home() {
        if h.parent().is_some_and(|p| p.is_dir()) {
            return root_of_kernel_clone(&h);
        }
    }
    default_projects_root()
}

/// The folder the person chose: the variable first, then the machine config.
pub fn declared_projects_root() -> Option<String> {
    var(PROJECTS_DIR_KEY).or_else(|| config_value_in(&config_file(), PROJECTS_DIR_KEY))
}

pub fn default_projects_root() -> PathBuf {
    home().join(DEFAULT_PROJECTS_DIR)
}

pub fn registry_file() -> PathBuf {
    var("CRUX_REGISTRY").map(PathBuf::from).unwrap_or_else(|| home().join(".crux/workspaces.json"))
}

/// Next to the workspace registry: if a test redirects that registry to its
/// sandbox, the tasks follow without having to remember another variable.
pub fn tasks_dir() -> PathBuf {
    if let Some(d) = var("CRUX_TASKS_DIR") {
        return PathBuf::from(d);
    }
    registry_file().parent().unwrap_or(Path::new("/")).join("tasks")
}

pub fn state_dir() -> PathBuf {
    var("CRUX_STATE_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".crux/state"))
}

pub fn claude_config_dir() -> PathBuf {
    var("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".claude"))
}

pub fn claude_skills_dir() -> PathBuf {
    var("CLAUDE_SKILLS_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".claude/skills"))
}

pub fn codex_prompts_dir() -> PathBuf {
    var("CODEX_PROMPTS_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".codex/prompts"))
}

pub fn codex_home_dir() -> PathBuf {
    var("CODEX_HOME_DIR").map(PathBuf::from).unwrap_or_else(|| home().join(".codex"))
}

pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its whole length and gethostname
    // null-terminates within it or truncates.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc != 0 {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

pub fn dry_run() -> bool {
    var("CRUX_DRY_RUN").as_deref() == Some("1")
}

pub fn in_tests() -> bool {
    var("CRUX_IN_TESTS").as_deref() == Some("1")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_of_clone_in_either_layout() {
        assert_eq!(root_of_kernel_clone(Path::new("/r/crux")), PathBuf::from("/r"));
        assert_eq!(root_of_kernel_clone(Path::new("/r/crux/crux")), PathBuf::from("/r"));
    }
}
