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
}

/// The open tasks, most recently updated first.
pub fn open_tasks(project: Option<&str>) -> Vec<OpenTask> {
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
            if !doc.status().is_some_and(record::Status::is_open) && !waiting {
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
            });
        }
    }
    out.sort_by(|a, b| b.updated.cmp(&a.updated));
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

fn parse_date(s: &str) -> Option<chrono::DateTime<chrono::Local>> {
    use chrono::TimeZone;
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(d.with_timezone(&chrono::Local));
    }
    if let Ok(d) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
        return chrono::Local.from_local_datetime(&d).single();
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
    env::var("CRUX_WAIT_NUDGE_DAYS")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|n| *n > 0.0)
        .map(|n| n as i64)
        .unwrap_or(7)
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
        if !here {
            l.push_str(&format!(" · no workspace here: crux workspace resume {}", t.task));
        }
        lines.push(l);
    }
    if list.len() > maximum {
        lines.push(format!("· and {} more: crux status", list.len() - maximum));
    }
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
