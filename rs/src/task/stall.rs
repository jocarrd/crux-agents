//! Which open tasks have stalled, and what to propose for each: merge the
//! leftovers of a project into one task, archive the finished ones, and warn
//! about forgotten work that is not saved anywhere else.
//!
//! A task stalls in more ways than "no workspace and an old record": its
//! workspace can stay open for weeks after the work stopped, its proposal can
//! be merged with a step left, or every step can be done with the task still
//! open. A task whose proposal is under review, or that waits on someone, has
//! not stalled: it waits.

use super::record;
use super::remind::{days_since, idle_after_days, OpenTask};
use crate::{env, git, project, registry};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub const DEFAULT_MERGE_TARGET: &str = "pending";

#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkspaceState {
    /// Days since the last commit or the last edited file; None if unknown.
    pub days: Option<i64>,
    pub dirty: bool,
    pub unpushed: bool,
    /// Its branch was removed from the remote: the proposal was merged.
    pub gone: bool,
}

pub fn stale_after_days() -> i64 {
    env::var("CRUX_STALE_WORKSPACE_DAYS")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| *n > 0.0)
        .map(|n| n as i64)
        .unwrap_or(7)
}

fn epoch_days(secs: i64) -> i64 {
    (chrono::Utc::now().timestamp() - secs).max(0) / 86_400
}

/// Read from git, without the network: the remote is what was last fetched.
pub fn workspace_state(w: &registry::Workspace) -> WorkspaceState {
    let dir = Path::new(&w.path);
    if !dir.is_dir() {
        return WorkspaceState::default();
    }
    let mut newest: Option<i64> =
        git::out(dir, &["log", "-1", "--format=%ct"]).and_then(|s| s.trim().parse::<i64>().ok());
    // -z leaves names with spaces, accents or quotes as they are. What git
    // cannot answer counts as unsaved work: it is never proposed for removal.
    let status = git::out(dir, &["status", "--porcelain", "-z"]);
    let dirty = status.as_deref().is_none_or(|s| !s.trim_matches('\0').trim().is_empty());
    let status = status.unwrap_or_default();
    let mut entries = status.split('\0').filter(|e| !e.is_empty());
    while let Some(entry) = entries.next() {
        // A rename or copy is followed by its old name, with no status of its own.
        if entry.starts_with(['R', 'C']) {
            entries.next();
        }
        let Some(path) = entry.get(3..) else { continue };
        let modified = std::fs::metadata(dir.join(path))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64);
        if let Some(m) = modified {
            newest = Some(newest.map_or(m, |n| n.max(m)));
        }
    }
    let track = git::out(dir, &["for-each-ref", "--format=%(upstream:track)", &format!("refs/heads/{}", w.branch)])
        .unwrap_or_default();
    let gone = track.contains("gone");
    let remote = format!("refs/remotes/origin/{}", w.branch);
    let ahead_of = |base: &str| {
        git::out(dir, &["rev-list", "--count", &format!("{base}..HEAD")])
            .and_then(|s| s.trim().parse::<i64>().ok())
            .unwrap_or(1)
    };
    let unpushed = if gone {
        false
    } else if git::ok(dir, &["rev-parse", "--verify", "--quiet", &remote]) {
        ahead_of(&remote) > 0
    } else {
        ahead_of(&project::main_branch(Path::new(&w.repo))) > 0
    };
    WorkspaceState { days: newest.map(epoch_days), dirty, unpushed, gone }
}

pub fn workspace_states(list: &[OpenTask], live: &BTreeSet<String>) -> BTreeMap<String, WorkspaceState> {
    let wanted: BTreeSet<&str> =
        list.iter().flat_map(|t| t.workspaces.iter()).filter(|w| live.contains(*w)).map(String::as_str).collect();
    if wanted.is_empty() {
        return BTreeMap::new();
    }
    registry::read()
        .unwrap_or_default()
        .into_iter()
        .filter(|w| wanted.contains(w.name.as_str()))
        .map(|w| {
            let s = workspace_state(&w);
            (w.name, s)
        })
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub enum Stall {
    /// Being worked on, waiting on someone, or under review.
    Active,
    /// Stopped with steps left: a leftover. `close` are the workspaces to
    /// close first, all of them clean.
    Idle { days: i64, close: Vec<String> },
    /// Stopped with every step done: to archive, not to merge.
    Finished { days: i64, close: Vec<String> },
    /// Stopped with work that is only in the workspace.
    Unsaved { days: i64, workspaces: Vec<String> },
}

/// The proposal is open, so the task waits on whoever reviews it: it has not
/// stalled, nor does it receive leftovers.
pub fn under_review(t: &OpenTask) -> bool {
    !t.pr.is_empty()
        && matches!(record::Status::parse(&t.status), Some(record::Status::Verified | record::Status::Proposed))
}

pub fn classify(t: &OpenTask, live: &BTreeSet<String>, states: &BTreeMap<String, WorkspaceState>) -> Stall {
    if t.waiting.is_some() {
        return Stall::Active;
    }
    if under_review(t) {
        return Stall::Active;
    }
    let Some(record_days) = days_since(&t.updated) else { return Stall::Active };
    let mine: Vec<&String> = t.workspaces.iter().filter(|w| live.contains(*w)).collect();
    let (days, close) = if mine.is_empty() {
        if record_days < idle_after_days() {
            return Stall::Active;
        }
        (record_days, vec![])
    } else {
        let mut days = record_days;
        let mut unsaved = false;
        for w in &mine {
            let Some(s) = states.get(*w) else { return Stall::Active };
            let Some(ws_days) = s.days else { return Stall::Active };
            let d = ws_days.min(record_days);
            let threshold = if s.gone { idle_after_days() } else { stale_after_days() };
            if d < threshold {
                return Stall::Active;
            }
            days = days.min(d);
            unsaved |= s.dirty || s.unpushed;
        }
        let names: Vec<String> = mine.into_iter().cloned().collect();
        if unsaved {
            return Stall::Unsaved { days, workspaces: names };
        }
        (days, names)
    };
    if t.steps > 0 && t.pending == 0 {
        Stall::Finished { days, close }
    } else {
        Stall::Idle { days, close }
    }
}

#[derive(Debug, PartialEq)]
pub struct MergeCandidate {
    pub project: String,
    pub into: String,
    pub tasks: Vec<String>,
    /// Idle tasks the merge leaves as one, the target included when it is idle too.
    pub idle: usize,
    pub close: Vec<String>,
}

#[derive(Debug, Default, PartialEq)]
pub struct Survey {
    pub merge: Vec<MergeCandidate>,
    /// project/task and the workspaces to close.
    pub finished: Vec<(String, Vec<String>)>,
    /// project/task, days and the workspaces holding the work.
    pub unsaved: Vec<(String, i64, Vec<String>)>,
}

impl Survey {
    /// Every project/task it says something about.
    pub fn tasks(&self) -> BTreeSet<String> {
        let mut out: BTreeSet<String> = self.finished.iter().map(|(t, _)| t.clone()).collect();
        out.extend(self.unsaved.iter().map(|(t, _, _)| t.clone()));
        for c in &self.merge {
            out.extend(c.tasks.iter().map(|t| format!("{}/{t}", c.project)));
        }
        out
    }
}

/// The projects where two or more tasks have stalled with steps left are
/// proposed as one, into the task still alive there if there is one, so the
/// leftovers join the work in progress, or into a new `pending`.
pub fn survey(list: &[OpenTask], live: &BTreeSet<String>, states: &BTreeMap<String, WorkspaceState>) -> Survey {
    let mut out = Survey::default();
    let projects: BTreeSet<&str> = list.iter().map(|t| t.project.as_str()).collect();
    for p in projects {
        let mut idle: Vec<(&OpenTask, Vec<String>)> = vec![];
        let mut alive: Vec<&OpenTask> = vec![];
        for t in list.iter().filter(|t| t.project == p) {
            match classify(t, live, states) {
                Stall::Active => {
                    if t.waiting.is_none() && !under_review(t) {
                        alive.push(t);
                    }
                }
                Stall::Idle { close, .. } => idle.push((t, close)),
                Stall::Finished { close, .. } => out.finished.push((format!("{p}/{}", t.task), close)),
                Stall::Unsaved { days, workspaces } => out.unsaved.push((format!("{p}/{}", t.task), days, workspaces)),
            }
        }
        if idle.len() < 2 {
            continue;
        }
        let into = alive
            .iter()
            .max_by(|a, b| a.updated.cmp(&b.updated))
            .map(|t| t.task.clone())
            .or_else(|| idle.iter().find(|(t, _)| t.task == DEFAULT_MERGE_TARGET).map(|(t, _)| t.task.clone()))
            .unwrap_or_else(|| DEFAULT_MERGE_TARGET.to_string());
        let sources: Vec<&(&OpenTask, Vec<String>)> = idle.iter().filter(|(t, _)| t.task != into).collect();
        if sources.is_empty() {
            continue;
        }
        let mut close: Vec<String> = idle.iter().flat_map(|(_, c)| c.iter().cloned()).collect();
        close.sort();
        out.merge.push(MergeCandidate {
            project: p.to_string(),
            into,
            tasks: sources.iter().map(|(t, _)| t.task.clone()).collect(),
            idle: idle.len(),
            close,
        });
    }
    out
}

pub fn survey_lines(s: &Survey) -> Vec<String> {
    let mut lines = vec![];
    for c in &s.merge {
        let sources: Vec<String> = c.tasks.iter().map(|t| format!("{}/{t}", c.project)).collect();
        let first =
            if c.close.is_empty() { String::new() } else { format!("crux workspace rm {}, then ", c.close.join(" ")) };
        lines.push(format!(
            "· {} idle tasks in {} could be a single one: {first}crux task merge {}/{} {}",
            c.idle,
            c.project,
            c.project,
            c.into,
            sources.join(" ")
        ));
    }
    for (task, close) in &s.finished {
        let first =
            if close.is_empty() { String::new() } else { format!("crux workspace rm {}, then ", close.join(" ")) };
        lines.push(format!("· {task} has every step done and has stopped: {first}crux task archive --task {task}"));
    }
    for (task, days, ws) in &s.unsaved {
        lines.push(format!(
            "· {task}: workspace {} untouched {days} days with work not saved elsewhere — resume it or push it",
            ws.join(", ")
        ));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(project: &str, name: &str, days_ago: i64, ws: &[&str]) -> OpenTask {
        OpenTask {
            project: project.into(),
            task: name.into(),
            status: "open".into(),
            updated: (chrono::Local::now() - chrono::Duration::days(days_ago)).format("%Y-%m-%dT%H:%M:%S").to_string(),
            next: String::new(),
            workspaces: ws.iter().map(|w| w.to_string()).collect(),
            waiting: None,
            steps: 1,
            pending: 1,
            pr: String::new(),
        }
    }

    fn ws(days: i64) -> WorkspaceState {
        WorkspaceState { days: Some(days), ..Default::default() }
    }

    fn live(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|n| n.to_string()).collect()
    }

    #[test]
    fn a_task_without_workspace_stalls_after_the_idle_threshold() {
        let none = BTreeMap::new();
        assert_eq!(classify(&task("p", "a", 1, &[]), &live(&[]), &none), Stall::Active);
        assert_eq!(classify(&task("p", "a", 10, &[]), &live(&[]), &none), Stall::Idle { days: 10, close: vec![] });
        assert_eq!(
            classify(&task("p", "a", 10, &["gone-ws"]), &live(&[]), &none),
            Stall::Idle { days: 10, close: vec![] },
            "a workspace registered but not on this machine does not keep it alive"
        );
    }

    #[test]
    fn a_forgotten_open_workspace_stalls_and_is_closed_first() {
        let l = live(&["w"]);
        let t = task("p", "a", 20, &["w"]);
        let mut states = BTreeMap::from([("w".to_string(), ws(2))]);
        assert_eq!(classify(&t, &l, &states), Stall::Active, "recent commits keep it alive");
        states.insert("w".into(), ws(12));
        assert_eq!(classify(&t, &l, &states), Stall::Idle { days: 12, close: vec!["w".into()] });
        let fresh_record = task("p", "a", 1, &["w"]);
        assert_eq!(
            classify(&fresh_record, &l, &states),
            Stall::Active,
            "a recent note in the record counts as activity"
        );
        states.insert("w".into(), WorkspaceState { days: Some(5), gone: true, ..Default::default() });
        assert_eq!(
            classify(&t, &l, &states),
            Stall::Idle { days: 5, close: vec!["w".into()] },
            "a merged branch left open stalls sooner"
        );
        states.insert("w".into(), WorkspaceState { days: None, ..Default::default() });
        assert_eq!(classify(&t, &l, &states), Stall::Active, "an unknown activity is not taken as stopped");
    }

    #[test]
    fn work_only_in_the_workspace_is_warned_not_merged() {
        let l = live(&["w"]);
        let t = task("p", "a", 20, &["w"]);
        for s in [
            WorkspaceState { days: Some(15), dirty: true, ..Default::default() },
            WorkspaceState { days: Some(15), unpushed: true, ..Default::default() },
        ] {
            let states = BTreeMap::from([("w".to_string(), s)]);
            assert_eq!(classify(&t, &l, &states), Stall::Unsaved { days: 15, workspaces: vec!["w".into()] });
        }
    }

    #[test]
    fn every_workspace_of_a_task_must_have_stopped() {
        let l = live(&["w1", "w2"]);
        let t = task("p", "a", 20, &["w1", "w2"]);
        let states = BTreeMap::from([("w1".to_string(), ws(30)), ("w2".to_string(), ws(1))]);
        assert_eq!(classify(&t, &l, &states), Stall::Active);
    }

    #[test]
    fn under_review_waiting_and_finished_are_told_apart() {
        let none = BTreeMap::new();
        let mut review = task("p", "a", 30, &[]);
        review.status = "proposed".into();
        review.pr = "https://example.org/pr/1".into();
        assert_eq!(classify(&review, &live(&[]), &none), Stall::Active, "a proposal under review waits");
        let mut asked = task("p", "a", 30, &[]);
        asked.waiting =
            Some(record::Waiting { on: "x".into(), ask: "?".into(), since: String::new(), reference: String::new() });
        assert_eq!(classify(&asked, &live(&[]), &none), Stall::Active);
        let mut done = task("p", "a", 30, &[]);
        done.pending = 0;
        assert_eq!(classify(&done, &live(&[]), &none), Stall::Finished { days: 30, close: vec![] });
        let mut empty = task("p", "a", 30, &[]);
        empty.steps = 0;
        empty.pending = 0;
        assert_eq!(classify(&empty, &live(&[]), &none), Stall::Idle { days: 30, close: vec![] }, "never planned");
    }

    #[test]
    fn the_survey_groups_by_project_and_picks_the_target() {
        let l = live(&["main-ws", "old-ws", "dirty-ws"]);
        let states = BTreeMap::from([
            ("main-ws".to_string(), ws(0)),
            ("old-ws".to_string(), ws(20)),
            ("dirty-ws".to_string(), WorkspaceState { days: Some(20), dirty: true, ..Default::default() }),
        ]);
        let mut finished = task("a", "done", 10, &[]);
        finished.pending = 0;
        let mut review = task("a", "review", 0, &[]);
        review.status = "proposed".into();
        review.pr = "https://example.org/pr/2".into();
        let list = vec![
            review,
            task("a", "main", 0, &["main-ws"]),
            task("a", "old-1", 10, &[]),
            task("a", "old-2", 20, &["old-ws"]),
            task("a", "unsaved", 20, &["dirty-ws"]),
            finished,
            task("b", "lonely", 30, &[]),
            task("c", "x", 12, &[]),
            task("c", "y", 11, &[]),
            task("d", "pending", 10, &[]),
            task("d", "other", 10, &[]),
        ];
        let s = survey(&list, &l, &states);
        assert_eq!(
            s.merge,
            vec![
                MergeCandidate {
                    project: "a".into(),
                    into: "main".into(),
                    tasks: vec!["old-1".into(), "old-2".into()],
                    idle: 2,
                    close: vec!["old-ws".into()],
                },
                MergeCandidate {
                    project: "c".into(),
                    into: "pending".into(),
                    tasks: vec!["x".into(), "y".into()],
                    idle: 2,
                    close: vec![],
                },
                MergeCandidate {
                    project: "d".into(),
                    into: "pending".into(),
                    tasks: vec!["other".into()],
                    idle: 2,
                    close: vec![],
                },
            ]
        );
        assert_eq!(s.finished, vec![("a/done".to_string(), vec![])]);
        assert_eq!(s.unsaved, vec![("a/unsaved".to_string(), 20, vec!["dirty-ws".to_string()])]);
        let lines = survey_lines(&s);
        assert_eq!(
            lines[0],
            "· 2 idle tasks in a could be a single one: crux workspace rm old-ws, then crux task merge a/main a/old-1 a/old-2"
        );
        assert_eq!(lines[1], "· 2 idle tasks in c could be a single one: crux task merge c/pending c/x c/y");
        assert!(lines[2].starts_with("· 2 idle tasks in d"), "{}", lines[2]);
        assert_eq!(lines[3], "· a/done has every step done and has stopped: crux task archive --task a/done");
        assert!(lines[4].contains("a/unsaved: workspace dirty-ws untouched 20 days"), "{}", lines[4]);
    }
}
