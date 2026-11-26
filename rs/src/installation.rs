//! A crux installation and the agents it serves (ADR-027).
//!
//! An installation is one folder (`env::crux_dir`): its kernels, config,
//! tasks, state and command. It serves a set of agents, each one through the
//! folder that agent keeps its settings, skills and hooks in (Claude's
//! `CLAUDE_CONFIG_DIR`, Codex's `CODEX_HOME`). A machine can hold several
//! installations side by side; what keeps them apart is that **an agent
//! folder belongs to exactly one installation**. Each agent folder carries a
//! `crux-installation` file naming its installation, which is how the shared
//! `crux` on the PATH knows which one to run from inside any agent, and how a
//! second installation knows not to take over a folder that is not its own.

use crate::{env, files, names, project};
use std::path::{Path, PathBuf};

/// An agent an installation can serve: its name, its folder and the file
/// where crux leaves its hooks, which tells who installed them before the
/// folder carried a mark.
pub struct Agent {
    pub name: &'static str,
    pub dir: PathBuf,
    pub hooks: PathBuf,
}

/// Every agent crux knows how to serve, at the folders this installation
/// uses for them. A new agent is one more entry here.
pub fn agents() -> Vec<Agent> {
    vec![
        Agent { name: "Claude", dir: env::claude_config_dir(), hooks: env::claude_settings() },
        Agent { name: "Codex", dir: env::codex_home_dir(), hooks: env::codex_home_dir().join("hooks.json") },
    ]
}

/// The installation an agent folder belongs to: the one its mark names or,
/// for a folder set up before marks existed, the one whose kernels its hooks
/// run (`<dir>/kernel/<version>/adapters/`).
pub fn owner(agent: &Agent) -> Result<Option<PathBuf>, String> {
    let mark = agent.dir.join(names::INSTALLATION_MARK);
    if mark.exists() {
        let text = files::read_if_exists(&mark)?;
        let dir = text.lines().next().unwrap_or("").trim();
        if dir.is_empty() {
            return Err(format!("{} is empty: write the installation's folder in it, or delete it", mark.display()));
        }
        return Ok(Some(PathBuf::from(dir)));
    }
    let hooks = files::read_if_exists(&agent.hooks)?;
    // A path inside a JSON string, alone or in a `:` list, or a command's word.
    let re = crate::regex!(r#"(?:^|["\s:])(/[^"\s:]+)/kernel/[^/"\s:]+/adapters/"#);
    Ok(re.captures(&hooks).map(|c| PathBuf::from(&c[1])))
}

fn same(a: &Path, b: &Path) -> bool {
    project::real(a) == project::real(b)
}

/// Claims for this installation every agent present on the machine, after
/// checking that none of them belongs to another: two installations on one
/// agent folder would mix exactly what they exist to keep apart. Nothing is
/// written unless every agent is free or already this installation's.
/// Returns the names of the agents claimed.
pub fn claim_agents() -> Result<Vec<String>, String> {
    let mine = env::crux_dir();
    let present: Vec<Agent> = agents().into_iter().filter(|a| a.dir.is_dir()).collect();
    for a in &present {
        if let Some(other) = owner(a)?.filter(|o| !same(o, &mine)) {
            return Err(format!(
                "{} ({}) belongs to the crux installation in {}, not to this one ({}): \
                 give this installation its own {} folder",
                a.name,
                a.dir.display(),
                other.display(),
                mine.display(),
                a.name
            ));
        }
    }
    if !env::dry_run() {
        for a in &present {
            files::write(&a.dir.join(names::INSTALLATION_MARK), &format!("{}\n", mine.display()))?;
        }
    }
    Ok(present.iter().map(|a| a.name.to_string()).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(dir: &Path) -> Agent {
        Agent { name: "Claude", dir: dir.to_path_buf(), hooks: dir.join("settings.json") }
    }

    #[test]
    fn an_agent_folder_belongs_to_the_installation_its_mark_names() {
        let d = std::env::temp_dir().join(format!("crux-owner-mark-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join(names::INSTALLATION_MARK), "/srv/a\n").unwrap();
        assert_eq!(owner(&agent(&d)).unwrap(), Some(PathBuf::from("/srv/a")));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn without_a_mark_its_hooks_say_which_kernels_installed_them() {
        let d = std::env::temp_dir().join(format!("crux-owner-hooks-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("settings.json"),
            r#"{"hooks":{"Stop":[{"hooks":[{"command":"/h/.crux/kernel/1.0.0/adapters/claude/hooks/x.sh"}]}]}}"#,
        )
        .unwrap();
        assert_eq!(owner(&agent(&d)).unwrap(), Some(PathBuf::from("/h/.crux")));
        std::fs::write(
            d.join("settings.json"),
            r#"{"env":{"P":"/opt/other:/h/.crux/kernel/1.0.0/adapters/claude/plugin"}}"#,
        )
        .unwrap();
        assert_eq!(owner(&agent(&d)).unwrap(), Some(PathBuf::from("/h/.crux")), "one path of a list, not the list");
        std::fs::write(d.join("settings.json"), "{}").unwrap();
        assert_eq!(owner(&agent(&d)).unwrap(), None, "a folder crux never touched belongs to nobody");
        let _ = std::fs::remove_dir_all(&d);
    }
}
