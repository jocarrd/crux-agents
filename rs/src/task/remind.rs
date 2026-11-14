//! What is open and what to remind about it: the open tasks of every project,
//! and the reminder a session gets when it starts.

use super::record;
use super::sync::{is_task, live_workspaces};
use crate::{env, files};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, serde::Serialize)]
pub struct OpenTask {
    pub project: String,
    pub task: String,
    pub status: String,
    pub updated: String,
    pub next: String,
    pub workspaces: Vec<String>,
    pub waiting: Option<record::Waiting>,
    pub steps: usize,
    pub pending: usize,
    pub pr: String,
}

/// The open tasks, most recently updated first.
pub fn open_tasks(project: Option<&str>) -> Vec<OpenTask> {
    load(project, false)
}

/// The open tasks plus the ones whose proposal was merged with steps still to
/// do: they leave the reminder, and those are exactly the leftovers to gather.
pub fn unfinished_tasks(project: Option<&str>) -> Vec<OpenTask> {
    load(project, true)
}

fn load(project: Option<&str>, leftovers: bool) -> Vec<OpenTask> {
    let dt = env::tasks_dir();
    let projects: Vec<String> = match project {
        Some(p) => vec![p.to_string()],
        None => fs::read_dir(&dt)
            .map(|e| e.flatten().map(|x| x.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default(),
    };
    let mut out = vec![];
    for p in projects {
        let dir = dt.join(&p);
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        for n in names {
            if !is_task(&n) {
                continue;
            }
            let Ok(doc) = record::parse(&files::read_or_empty(&dir.join(&n))) else { continue };
            let status = doc.text("status");
            // A task waiting for an answer is still alive even if merged.
            let waiting = !doc.text("waiting_on").is_empty() && doc.status() != Some(record::Status::Closed);
            let leftover = leftovers
                && matches!(doc.status(), Some(record::Status::Merged | record::Status::Deployed))
                && record::pending(&doc) > 0;
            if !doc.status().is_some_and(record::Status::is_open) && !waiting && !leftover {
                continue;
            }
            let sec = |t: &str| record::first_line(&record::content(doc.section(t)));
            let next = sec("Next step");
            let task = doc.text("task");
            out.push(OpenTask {
                project: p.clone(),
                task: if task.is_empty() { n[..n.len() - 3].to_string() } else { task },
                status,
                updated: doc.text("updated"),
                next: if next.is_empty() { sec("Objective") } else { next },
                workspaces: doc.list("workspaces"),
                waiting: if waiting { record::waiting_of(&doc) } else { None },
                steps: record::steps(&doc).len(),
                pending: record::pending(&doc),
                pr: doc.text("pr"),
            });
        }
    }
    out.sort_by(|a, b| b.updated.cmp(&a.updated));
    out
}

/// The records `open_tasks` leaves out because they cannot be read: without
/// this a truncated record vanished from every listing without a word.
pub fn unreadable_tasks() -> Vec<std::path::PathBuf> {
    let dt = env::tasks_dir();
    let mut out = vec![];
    for p in crate::project::subdirs(&dt) {
        let Ok(entries) = fs::read_dir(dt.join(&p)) else { continue };
        for f in entries.flatten().map(|e| e.path()) {
            if is_task(&files::name(&f)) && record::read(&f).is_err() {
                out.push(f);
            }
        }
    }
    out.sort();
    out
}

//
// When a session starts, the open tasks are shown. It is a reminder and
// nothing more: one text the person sees, another for the agent that says
// expressly not to push them.

fn project_of(cwd: &Path) -> Option<String> {
    let root = crate::project::normalize(&env::projects_root());
    let cwd = crate::project::normalize(cwd);
    let rel = cwd.strip_prefix(&root).ok()?;
    let first = rel.components().next()?.as_os_str().to_string_lossy().into_owned();
    Some(crate::regex!(r"-ws-.*$").replace(&first, "").into_owned())
}

/// A local time the clock change makes ambiguous or skips is still a date.
/// Read as none, a task written in the repeated autumn hour looked active
/// forever, and the suite failed every night that fell twenty days after it.
/// Of a repeated hour, the older instant: the order in which the platform
/// returns the two is not something to rely on.
fn pick_local<T: Ord>(found: chrono::LocalResult<T>, an_hour_later: impl FnOnce() -> Option<T>) -> Option<T> {
    match found {
        chrono::LocalResult::Single(t) => Some(t),
        chrono::LocalResult::Ambiguous(a, b) => Some(a.min(b)),
        chrono::LocalResult::None => an_hour_later(),
    }
}

fn parse_date(s: &str) -> Option<chrono::DateTime<chrono::Local>> {
    use chrono::TimeZone;
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(d.with_timezone(&chrono::Local));
    }
    if let Ok(d) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
        return pick_local(chrono::Local.from_local_datetime(&d), || {
            chrono::Local.from_local_datetime(&(d + chrono::Duration::hours(1))).earliest()
        });
    }
    // A bare date is UTC midnight.
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .ok()
        .map(|d| chrono::Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap()).with_timezone(&chrono::Local))
}

pub fn days_since(s: &str) -> Option<i64> {
    parse_date(s).map(|d| ((chrono::Local::now() - d).num_milliseconds() as f64 / 86_400_000.0).floor().max(0.0) as i64)
}

fn ago(s: &str) -> String {
    match parse_date(s) {
        None => String::new(),
        Some(d) => {
            let days = ((chrono::Local::now() - d).num_milliseconds() as f64 / 86_400_000.0).floor() as i64;
            match days {
                d if d <= 0 => "today".into(),
                1 => "yesterday".into(),
                d => format!("{d} days ago"),
            }
        }
    }
}

fn nudge_after_days() -> i64 {
    env::var(crate::names::vars::WAIT_NUDGE_DAYS)
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| *n > 0.0)
        .map(|n| n as i64)
        .unwrap_or(7)
}

pub fn idle_after_days() -> i64 {
    env::var(crate::names::vars::IDLE_TASK_DAYS)
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| *n > 0.0)
        .map(|n| n as i64)
        .unwrap_or(3)
}

/// How long an open task has gone untouched with no workspace on this
/// machine, once past the threshold. Such a task was usually finished under
/// another name, or forgotten: nothing archives it, because only closing its
/// last workspace does.
pub fn idle_days(updated: &str, workspaces: &[String], live: &BTreeSet<String>) -> Option<i64> {
    if workspaces.iter().any(|w| live.contains(w)) {
        return None;
    }
    days_since(updated).filter(|d| *d >= idle_after_days())
}

fn cut(t: &str, n: usize) -> String {
    if t.chars().count() > n {
        format!("{}…", t.chars().take(n - 1).collect::<String>())
    } else {
        t.to_string()
    }
}

pub fn reminder(cwd: &Path, maximum: usize) -> Option<Value> {
    let project = project_of(cwd);
    let scope = project.as_deref().filter(|p| env::tasks_dir().join(p).exists());
    let list = open_tasks(scope);
    if list.is_empty() {
        return None;
    }
    let live = live_workspaces();
    let leftovers = unfinished_tasks(scope);
    let states = super::stall::workspace_states(&leftovers, &live);
    let survey = super::stall::survey(&leftovers, &live, &states);
    // The survey says what to do with a stalled task; its line does not repeat it.
    let covered = survey.tasks();
    // First the work that depends on us; then what waits on someone else.
    let list: Vec<OpenTask> = list
        .iter()
        .filter(|t| t.waiting.is_none())
        .chain(list.iter().filter(|t| t.waiting.is_some()))
        .cloned()
        .collect();
    let nudge_days = nudge_after_days();
    let shown = &list[..list.len().min(maximum)];
    let tasks: Vec<Value> = shown
        .iter()
        .map(|t| {
            let waiting = t.waiting.as_ref().map(|w| {
                let days = days_since(&w.since);
                json!({"on": w.on, "ask": w.ask, "since": w.since, "ref": w.reference, "days": days, "nudge": days.unwrap_or(0) >= nudge_days})
            });
            json!({
                "task": format!("{}/{}", t.project, t.task),
                "name": t.task,
                "status": if t.waiting.is_some() { "waiting".to_string() } else { t.status.clone() },
                "when": ago(&t.updated),
                "next": t.waiting.as_ref().map(|w| w.ask.clone()).unwrap_or_else(|| t.next.clone()),
                "here": t.workspaces.iter().any(|w| live.contains(w)),
                "waiting": waiting,
            })
        })
        .collect();
    let mut lines = vec![];
    let mut waiting_block = false;
    let mut idle_any = false;
    for t in shown {
        if let Some(w) = &t.waiting {
            if !waiting_block {
                lines.push("Waiting for an answer:".to_string());
                waiting_block = true;
            }
            let days = days_since(&w.since);
            let since = if w.since.is_empty() { String::new() } else { ago(&w.since) };
            let mut l = format!(
                "· {}/{} · to {}{}",
                t.project,
                t.task,
                w.on,
                if since.is_empty() { String::new() } else { format!(", {since}") }
            );
            if !w.ask.is_empty() {
                l.push_str(&format!(": {}", cut(&w.ask, 70)));
            }
            if days.unwrap_or(0) >= nudge_days {
                l.push_str(" · worth a nudge");
            }
            lines.push(l);
            continue;
        }
        let here = t.workspaces.iter().any(|w| live.contains(w));
        let status = if t.status == record::Status::Open.as_str() { String::new() } else { format!("{}, ", t.status) };
        let mut l = format!("· {}/{} ({status}{})", t.project, t.task, ago(&t.updated));
        if !t.next.is_empty() {
            l.push_str(&format!(": {}", cut(&t.next, 70)));
        }
        let idle = idle_days(&t.updated, &t.workspaces, &live).filter(|_| !super::stall::under_review(t));
        if !covered.contains(&format!("{}/{}", t.project, t.task)) {
            if let Some(days) = idle {
                idle_any = true;
                l.push_str(&format!(
                    " · idle {days} days with no workspace: if it is done, crux task archive --task {}/{}",
                    t.project, t.task
                ));
            } else if !here {
                l.push_str(&format!(" · no workspace here: crux workspace resume {}", t.task));
            }
        }
        lines.push(l);
    }
    if list.len() > maximum {
        lines.push(format!("· and {} more: crux status", list.len() - maximum));
    }
    lines.extend(super::stall::survey_lines(&survey));
    let mut conflicts = vec![];
    let projects: BTreeSet<&str> = list.iter().map(|t| t.project.as_str()).collect();
    for p in projects {
        let dir = env::tasks_dir().join(p);
        if let Ok(entries) = fs::read_dir(&dir) {
            let mut names: Vec<String> =
                entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            for n in names.into_iter().filter(|n| super::sync::is_conflict_copy(n)) {
                conflicts.push(dir.join(n));
            }
        }
    }
    if !conflicts.is_empty() {
        let what = if conflicts.len() == 1 {
            "there is 1 copy".to_string()
        } else {
            format!("there are {} copies", conflicts.len())
        };
        lines.push(format!(
            "· {what} of a conflict between machines to review: {}",
            conflicts[0].parent().unwrap().display()
        ));
    }
    let title = match &project {
        Some(p) if list.iter().all(|t| &t.project == p) => format!("Open tasks in {p}"),
        _ => "Open tasks".to_string(),
    };
    let user = format!("{title}, in case you want to resume one:\n{}", lines.join("\n"));
    let mut agent = vec![format!("{title} of this person (already shown to them):")];
    agent.extend(lines.iter().cloned());
    agent.push(String::new());
    agent.push("This is only a reminder. Do not resume any or propose one on your own, and do not push:".into());
    agent.push("if they ask for something else, do that something else. If they decide to resume one that has".into());
    agent.push("no workspace on this computer, it is opened with `crux workspace resume <task>`.".into());
    if idle_any {
        agent.push(
            "The idle ones may have been finished under another task name: if this session did that work,".into(),
        );
        agent.push("say so and offer to archive them; never archive one on your own.".into());
    }
    if survey != super::stall::Survey::default() {
        agent.push("Some tasks have stalled: merging leftovers, archiving finished ones or closing a forgotten".into());
        agent.push("workspace. Propose it once, with the command shown, and run it only if the person agrees;".into());
        agent.push("never merge, archive or close on your own, and never touch a workspace with unsaved work.".into());
    }
    if waiting_block {
        agent.push(
            "The ones waiting for an answer depend on another person: do not resume them until it arrives,".into(),
        );
        agent.push("and if a nudge is due, say so once and let the person decide.".into());
    }
    Some(json!({
        "user": user,
        "agent": agent.join("\n"),
        "title": title,
        "tasks": tasks,
        "more": list.len().saturating_sub(maximum),
        "conflicts": conflicts.len(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_time_the_clock_change_repeats_or_skips_is_still_a_date() {
        assert_eq!(pick_local(chrono::LocalResult::Single(1), || None), Some(1));
        assert_eq!(pick_local(chrono::LocalResult::Ambiguous(2, 1), || None), Some(1), "the older of the two");
        assert_eq!(pick_local(chrono::LocalResult::<i32>::None, || Some(3)), Some(3), "a skipped one, an hour later");
    }

    #[test]
    fn idle_only_without_a_live_workspace_and_past_the_threshold() {
        let old = (chrono::Local::now() - chrono::Duration::days(10)).format("%Y-%m-%dT%H:%M:%S").to_string();
        let fresh = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string();
        let live: BTreeSet<String> = ["ws-a".to_string()].into();
        assert_eq!(idle_days(&old, &[], &live), Some(10));
        assert_eq!(idle_days(&old, &["ws-b".into()], &live), Some(10));
        assert_eq!(idle_days(&old, &["ws-a".into()], &live), None);
        assert_eq!(idle_days(&fresh, &[], &live), None);
    }
}
