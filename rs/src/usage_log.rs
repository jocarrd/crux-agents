//! Which skills each session used, travelling between machines (ADR-024).
//!
//! Each machine keeps one line per session in `usage.jsonl`, committed to a
//! ref of its own in the person's profile repo and pushed there. Only counts
//! travel: no words of the session, and a client's project as a fingerprint.
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

/// A client's project travels as a fingerprint: counted, without saying whose.
pub fn project_label(name: &str, foreign: bool) -> String {
    if foreign && !name.is_empty() {
        let digest = crate::cmd::ship::cksum(name.as_bytes());
        format!("client-{}", &digest[..digest.len().min(8)])
    } else {
        name.to_string()
    }
}

fn read_log(repo: &Path, r: &str) -> Vec<Session> {
    Batch::new(repo)
        .run(&["cat-file", "blob", &format!("{r}:{}", names::USAGE_LOG)], None)
        .map(|t| parse(&t))
        .unwrap_or_default()
}

/// Adds this machine's sessions to its log and publishes it. Ok(false) when
/// there was nothing new to write.
pub fn publish(profile: &Path, sessions: &[Session]) -> Result<bool, String> {
    let mine = refs::usage_on_remote(&env::machine());
    let head = git::out(profile, &["rev-parse", "-q", "--verify", &mine]);
    let before = head.as_deref().map(|_| read_log(profile, &mine)).unwrap_or_default();
    let merged = merge(before.clone(), sessions.to_vec());
    if merged == before {
        return Ok(false);
    }
    let g = Batch::new(profile);
    let blob = g.run(&["hash-object", "-w", "--stdin"], Some(&render(&merged)))?.trim().to_string();
    let tree = g.run(&["mktree"], Some(&format!("100644 blob {blob}\t{}\n", names::USAGE_LOG)))?.trim().to_string();
    let message = format!("[skip ci] usage: {}", env::machine());
    let mut args = vec!["commit-tree", "--no-gpg-sign", tree.as_str(), "-m", message.as_str()];
    if let Some(h) = &head {
        args.extend(["-p", h.as_str()]);
    }
    let commit = Batch::as_crux(profile, &[]).run(&args, None)?.trim().to_string();
    g.run(&["update-ref", &mine, &commit], None)?;
    if git::remote_url(profile, refs::REMOTE).is_some() {
        g.run(&["push", "-q", "--no-verify", refs::REMOTE, &format!("+{commit}:{mine}")], None)?;
    }
    Ok(true)
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
    fn a_clients_project_travels_as_a_fingerprint() {
        let label = project_label("acme", true);
        assert!(label.starts_with("client-") && !label.contains("acme"));
        assert_eq!(label, project_label("acme", true));
        assert_eq!(project_label("own", false), "own");
    }
}
