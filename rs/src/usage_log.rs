//! Which skills each session used, travelling between machines (ADR-024).
//!
//! Each machine keeps one line per session in `usage.jsonl`, committed to a
//! ref of its own in the person's profile repo and pushed there. Only counts
//! travel: no words of the session, and nothing that says which client.
//! Lines accumulate, so what the agent deletes after a month stays counted.

use crate::git::Batch;
use crate::names::{self, git as refs};
use crate::{env, git};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub session: String,
    pub date: String,
    pub machine: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub project: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub calls: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scripts: Vec<String>,
}

/// A line that does not parse is skipped: these are statistics, and a log
/// written by a newer kernel must not stop an older one from reading the rest.
pub fn parse(text: &str) -> Vec<Session> {
    text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

pub fn render(sessions: &[Session]) -> String {
    sessions.iter().filter_map(|s| serde_json::to_string(s).ok()).map(|l| l + "\n").collect()
}

/// By session: a newer reading of the same session replaces the older, and
/// sessions only one side has are all kept.
pub fn merge(older: Vec<Session>, newer: Vec<Session>) -> Vec<Session> {
    let mut by_id: BTreeMap<(String, String), Session> = BTreeMap::new();
    for s in older.into_iter().chain(newer) {
        by_id.insert((s.machine.clone(), s.session.clone()), s);
    }
    let mut out: Vec<Session> = by_id.into_values().collect();
    out.sort_by(|a, b| (&a.date, &a.machine, &a.session).cmp(&(&b.date, &b.machine, &b.session)));
    out
}

/// What a client's session says about whose it is does not travel: its
/// project goes as `client`, and so does any skill that is not the kernel's,
/// since a project's own skill names the client as well as the project would.
pub fn project_label(name: &str, foreign: bool) -> String {
    if foreign && !name.is_empty() {
        "client".to_string()
    } else {
        name.to_string()
    }
}

pub fn skill_label(skill: &str, foreign: bool, kernel: &[String]) -> String {
    if foreign && !kernel.iter().any(|k| k == skill) {
        "client-skill".to_string()
    } else {
        skill.to_string()
    }
}

fn read_log(repo: &Path, r: &str) -> Vec<Session> {
    Batch::new(repo)
        .run(&["cat-file", "blob", &format!("{r}:{}", names::USAGE_LOG)], None)
        .map(|t| parse(&t))
        .unwrap_or_default()
}

fn tip(repo: &Path, r: &str) -> Option<String> {
    git::out(repo, &["rev-parse", "-q", "--verify", r])
}

/// Adds this machine's sessions to its log and publishes it; Ok(true) when
/// something new reached the log or the remote.
///
/// It builds on what the remote holds, not only on the local copy: a profile
/// cloned again, on a machine reinstalled under the same name, has no local
/// copy, and a forced push from it would erase that machine's history. So the
/// push is never forced, and what an earlier push without network left only
/// here is sent the next time.
pub fn publish(profile: &Path, sessions: &[Session]) -> Result<bool, String> {
    let common = git::common_dir(profile).ok_or_else(|| format!("{} is not a git repo", profile.display()))?;
    let _lock = crate::task::record::lock(&common.join("crux").join("usage"))?;
    let machine = env::machine();
    let mine = refs::usage_on_remote(&machine);
    let theirs = format!("{}{machine}", refs::USAGE_FETCHED);
    let g = Batch::new(profile);
    // Asked first, because fetching a ref the remote does not have yet fails
    // just as being offline does.
    let listed = git::remote_url(profile, refs::REMOTE).and(g.run(&["ls-remote", refs::REMOTE, &mine], None).ok());
    let online = listed.is_some();
    let on_remote = listed.is_some_and(|l| !l.trim().is_empty());
    if on_remote {
        g.run(&["fetch", "-q", "--no-write-fetch-head", refs::REMOTE, &format!("+{mine}:{theirs}")], None)?;
    }
    let remote = if on_remote { tip(profile, &theirs) } else { None };
    let local = tip(profile, &mine);
    let known = merge(
        remote.as_deref().map(|r| read_log(profile, r)).unwrap_or_default(),
        local.as_deref().map(|l| read_log(profile, l)).unwrap_or_default(),
    );
    let merged = merge(known, sessions.to_vec());
    let base = if on_remote { remote.clone() } else { local.clone() };
    let base_log = base.as_deref().map(|b| read_log(profile, b)).unwrap_or_default();
    let head = if merged == base_log && base.is_some() {
        base.clone().unwrap_or_default()
    } else {
        let blob = g.run(&["hash-object", "-w", "--stdin"], Some(&render(&merged)))?.trim().to_string();
        let tree = g.run(&["mktree"], Some(&format!("100644 blob {blob}\t{}\n", names::USAGE_LOG)))?.trim().to_string();
        let message = format!("[skip ci] usage: {machine}");
        let mut args = vec!["commit-tree", "--no-gpg-sign", tree.as_str(), "-m", message.as_str()];
        if let Some(b) = &base {
            args.extend(["-p", b.as_str()]);
        }
        Batch::as_crux(profile, &[]).run(&args, None)?.trim().to_string()
    };
    let changed = local.as_deref() != Some(head.as_str());
    if changed {
        // The old value guards against another writer that got in between.
        let old = local.clone().unwrap_or_else(|| "0".repeat(40));
        g.run(&["update-ref", &mine, &head, &old], None)?;
    }
    let pending = online && remote.as_deref() != Some(head.as_str());
    if pending {
        g.run(&["push", "-q", "--no-verify", refs::REMOTE, &format!("{head}:{mine}")], None)?;
        g.run(&["update-ref", &theirs, &head], None)?;
    }
    if !online && git::remote_url(profile, refs::REMOTE).is_some() {
        return Err("the profile's remote cannot be reached: this machine's usage stays here until next time".into());
    }
    Ok(changed || pending)
}

/// Every machine's log as the remote has it, plus this machine's local copy,
/// which may hold what a push without network left behind.
pub fn fetch_all(profile: &Path) -> Vec<Session> {
    if git::remote_url(profile, refs::REMOTE).is_some() {
        let spec = format!("+{}*:{}*", refs::USAGE_ON_REMOTE, refs::USAGE_FETCHED);
        let _ = Batch::new(profile).run(&["fetch", "-q", "--no-write-fetch-head", refs::REMOTE, &spec], None);
    }
    let listed =
        git::out(profile, &["for-each-ref", "--format=%(refname)", refs::USAGE_FETCHED, refs::USAGE_ON_REMOTE])
            .unwrap_or_default();
    listed.lines().fold(vec![], |acc, r| merge(acc, read_log(profile, r)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(id: &str, machine: &str, calls: &[&str]) -> Session {
        Session {
            session: id.into(),
            date: "2026-11-14".into(),
            machine: machine.into(),
            project: String::new(),
            calls: calls.iter().map(|c| c.to_string()).collect(),
            scripts: vec![],
        }
    }

    #[test]
    fn a_newer_reading_of_a_session_replaces_the_older_and_others_stay() {
        let merged =
            merge(vec![s("a", "desk", &["ship"]), s("b", "desk", &[])], vec![s("a", "desk", &["ship", "flow"])]);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged.iter().find(|x| x.session == "a").unwrap().calls, vec!["ship", "flow"]);
    }

    #[test]
    fn the_same_session_id_on_two_machines_is_two_sessions() {
        assert_eq!(merge(vec![s("a", "desk", &[])], vec![s("a", "laptop", &[])]).len(), 2);
    }

    #[test]
    fn the_log_reads_back_what_it_writes_and_skips_what_it_cannot_read() {
        let one = vec![s("a", "desk", &["ship"])];
        let text = render(&one) + "not json\n";
        assert_eq!(parse(&text), one);
    }

    #[test]
    fn nothing_of_a_clients_session_says_whose_it_is() {
        let kernel = vec!["ship".to_string()];
        assert_eq!(project_label("acme", true), "client");
        assert_eq!(project_label("own", false), "own");
        assert_eq!(skill_label("acme-billing-deploy", true, &kernel), "client-skill");
        assert_eq!(skill_label("ship", true, &kernel), "ship");
        assert_eq!(skill_label("own-deploy", false, &kernel), "own-deploy");
    }
}
