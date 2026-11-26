//! Where things live on this machine: the kernel, the projects root, the
//! machine config and the local state. Every path the commands use comes from
//! here, and every one can be redirected by an environment variable, which is
//! how the test suite keeps its sandboxes away from the real machine.

use crate::names;
use std::path::{Path, PathBuf};

/// The variable, and the machine config key, that says where projects live.
pub const PROJECTS_DIR_KEY: &str = crate::names::vars::PROJECTS_DIR;
/// Under $HOME, when nobody has said otherwise.
pub const DEFAULT_PROJECTS_DIR: &str = "Projects";

pub fn var(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

pub fn home() -> PathBuf {
    var("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

/// The folder of this installation: config, kernels, tasks, state and its
/// command. A machine can hold several installations side by side, each bound
/// to its own agent folders (ADR-027). A kernel installed under
/// `<dir>/kernel/<version>` belongs to `<dir>` whatever the environment says,
/// so one installation's code never runs on another's state; a clone or a
/// loose binary takes the one CRUX_DIR names, and ~/.crux without it.
pub fn crux_dir() -> PathBuf {
    let kernel = var(crate::names::vars::HOME).map(PathBuf::from).or_else(own_kernel);
    kernel
        .and_then(|k| installation_of_kernel(&k))
        .or_else(|| var(crate::names::vars::DIR).map(PathBuf::from))
        .unwrap_or_else(default_crux_dir)
}

/// The installation a machine has when nobody names another one.
pub fn default_crux_dir() -> PathBuf {
    home().join(".crux")
}

/// `<dir>` for a kernel installed in `<dir>/kernel/<version>`; a clone
/// belongs to no installation by its location.
pub fn installation_of_kernel(kernel: &Path) -> Option<PathBuf> {
    let kernels = kernel.parent()?;
    (kernels.file_name()? == "kernel").then(|| kernels.parent().map(Path::to_path_buf)).flatten()
}

/// Where the installation leaves its own command, which the shared one on
/// the PATH hands over to.
pub fn installation_bin_dir() -> PathBuf {
    crux_dir().join("bin")
}

/// The one command on the PATH, shared by every installation of the machine.
pub fn command_dir() -> PathBuf {
    home().join(".local/bin")
}

/// The machine config, `~/.crux/config`: shell-style `KEY="value"` lines.
pub fn config_file() -> PathBuf {
    crux_dir().join("config")
}

/// The same file, but redirectable with CRUX_CONFIG. Only the remote template
/// has always honoured that variable; the rest read the file in $HOME.
pub fn config_file_redirectable() -> PathBuf {
    var(crate::names::vars::CONFIG).map_or_else(config_file, PathBuf::from)
}

/// The last `KEY=` line of a config file, without quotes.
pub fn config_value_in(file: &Path, key: &str) -> Option<String> {
    // Lossy: one byte that is not UTF-8, from an editor in another encoding,
    // made the whole config read as absent, and the projects root fell back to
    // the kernels directory without a word.
    let text = match std::fs::read(file) {
        Ok(b) => String::from_utf8_lossy(&b).into_owned(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            static SAID: std::sync::Once = std::sync::Once::new();
            SAID.call_once(|| crate::ui::warn_stderr(format!("cannot read {}: {e}", file.display())));
            return None;
        }
    };
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
    if let Some(h) = var(crate::names::vars::HOME) {
        return Some(PathBuf::from(h));
    }
    if let Some(k) = own_kernel() {
        return Some(k);
    }
    config_value_in(&config_file(), crate::names::vars::HOME).map(PathBuf::from)
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
        if h.parent().is_some_and(std::path::Path::is_dir) {
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
    var(crate::names::vars::REGISTRY).map_or_else(|| crux_dir().join("workspaces.json"), PathBuf::from)
}

/// Next to the workspace registry: if a test redirects that registry to its
/// sandbox, the tasks follow without having to remember another variable.
pub fn tasks_dir() -> PathBuf {
    if let Some(d) = var(crate::names::vars::TASKS_DIR) {
        return PathBuf::from(d);
    }
    registry_file().parent().unwrap_or(Path::new("/")).join("tasks")
}

pub fn state_dir() -> PathBuf {
    var(crate::names::vars::STATE_DIR).map_or_else(|| crux_dir().join("state"), PathBuf::from)
}

/// Where each installed kernel version lives, one folder per version.
pub fn kernels_dir() -> PathBuf {
    crux_dir().join("kernel")
}

/// The person's own profiles, which survive upgrades.
pub fn user_profiles_dir() -> PathBuf {
    crux_dir().join("profiles")
}

// Every agent path hangs from the agent's own folder, which the agent itself
// lets the person move: built from HOME instead, crux wrote where the agent
// did not look.

pub fn claude_config_dir() -> PathBuf {
    var(crate::names::agents::CLAUDE_CONFIG_DIR)
        .or_else(|| config_value_in(&config_file(), crate::names::agents::CLAUDE_CONFIG_DIR))
        .map_or_else(|| home().join(".claude"), PathBuf::from)
}

pub fn claude_skills_dir() -> PathBuf {
    var(crate::names::agents::CLAUDE_SKILLS_DIR).map_or_else(|| claude_config_dir().join("skills"), PathBuf::from)
}

pub fn claude_settings() -> PathBuf {
    var(crate::names::agents::CLAUDE_SETTINGS).map_or_else(|| claude_config_dir().join("settings.json"), PathBuf::from)
}

pub fn claude_transcripts_dir() -> PathBuf {
    claude_config_dir().join("projects")
}

pub fn codex_home_dir() -> PathBuf {
    var(crate::names::agents::CODEX_HOME_DIR)
        .or_else(|| var(crate::names::agents::CODEX_HOME))
        .or_else(|| config_value_in(&config_file(), crate::names::agents::CODEX_HOME))
        .map_or_else(|| home().join(".codex"), PathBuf::from)
}

pub fn codex_prompts_dir() -> PathBuf {
    var(crate::names::agents::CODEX_PROMPTS_DIR).map_or_else(|| codex_home_dir().join("prompts"), PathBuf::from)
}

/// This machine's name as it can go into a file name or a git ref: the short
/// hostname without anything but letters, digits and dashes.
pub fn machine() -> String {
    let h = var(crate::names::vars::MACHINE).unwrap_or_else(hostname);
    let short = h.split('.').next().unwrap_or("");
    let clean: String = short.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    if clean.is_empty() {
        "machine".into()
    } else {
        clean
    }
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

/// The identity an installation gives the git and GitHub it runs, as the
/// variables git and gh read. Empty unless the installation declares one.
pub fn installation_identity() -> Vec<(&'static str, String)> {
    let v = crate::names::vars::IDENTITY
        .iter()
        .filter_map(|(key, targets)| config_value_in(&config_file(), key).map(|value| (*targets, value)));
    v.flat_map(|(targets, value)| targets.iter().map(move |t| (*t, value.clone()))).collect()
}

pub fn dry_run() -> bool {
    var(crate::names::vars::DRY_RUN).as_deref() == Some("1")
}

pub fn in_tests() -> bool {
    var(crate::names::vars::IN_TESTS).as_deref() == Some("1")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_installed_kernel_belongs_to_the_folder_above_its_kernels() {
        assert_eq!(installation_of_kernel(Path::new("/h/.crux/kernel/1.0.0")), Some(PathBuf::from("/h/.crux")));
        assert_eq!(installation_of_kernel(Path::new("/srv/a/kernel/1.0.0")), Some(PathBuf::from("/srv/a")));
        assert_eq!(installation_of_kernel(Path::new("/r/crux")), None, "a clone belongs to none");
    }

    #[test]
    fn root_of_clone_in_either_layout() {
        assert_eq!(root_of_kernel_clone(Path::new("/r/crux")), PathBuf::from("/r"));
        assert_eq!(root_of_kernel_clone(Path::new("/r/crux/crux")), PathBuf::from("/r"));
    }
}
