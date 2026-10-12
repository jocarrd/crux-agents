//! Task records and their replica between machines.

pub mod record;
pub mod remind;
pub mod sync;

use crate::args::Opts;
use crate::error::{exit, Exit, Res};
use crate::names;
use std::path::{Path, PathBuf};

fn fail(msg: impl AsRef<str>) -> Res {
    eprintln!("{}", msg.as_ref());
    Err(Exit(1))
}

/// `crux __task <op> --file <path> …`: the record operations, for the
/// commands still written in shell. Same interface as the old library.
pub fn internal(argv: &[String]) -> Res {
    let Some(op) = argv.first() else { return fail("unknown operation: undefined") };
    let o = Opts::parse(&argv[1..]);
    // --path: the record of the workspace at that path, for whoever only has
    // the session's directory. Not being in one is not an error to report.
    let file = match (o.get("file"), o.get("path")) {
        (Some(f), _) => PathBuf::from(f),
        (None, Some(p)) => match file_for_workspace(&p) {
            Some(f) => f,
            None => return exit(1),
        },
        _ => return fail("missing --file"),
    };
    let mutate = |f: &mut dyn FnMut(&mut record::Doc) -> Result<Option<String>, String>| -> Res {
        let mut doc = match record::read(&file) {
            Ok(d) => d,
            Err(e) => return fail(e),
        };
        let out = match f(&mut doc) {
            Ok(o) => o,
            Err(e) => return fail(e),
        };
        if let Err(e) = record::write(&file, &mut doc, true) {
            return fail(e);
        }
        if let Some(line) = out {
            println!("{line}");
        }
        Ok(())
    };
    match op.as_str() {
        "ensure" => {
            if file.exists() {
                mutate(&mut |d| {
                    record::join(d, &o.val("repo"), &o.val("workspace"));
                    Ok(None)
                })?;
                println!("joined");
            } else {
                let mut d = record::create(&o.val("task"), &o.val("project"), &o.val("repo"), &o.val("workspace"));
                if let Err(e) = record::write(&file, &mut d, true) {
                    return fail(e);
                }
                println!("created");
            }
            Ok(())
        }
        "set" => mutate(&mut |d| {
            record::set_section(d, &o.val("section"), &o.val("text"));
            Ok(None)
        }),
        "note" => mutate(&mut |d| {
            let line = record::decision_line(&o.val("text"), &o.val("why"), &o.val("where"), &o.val("learned"));
            record::append(d, "Deviations and decisions", &line);
            Ok(None)
        }),
        "decisions" => match record::read(&file) {
            Ok(d) => {
                let v = serde_json::json!({"task": d.text("task"), "repos": d.list("repos"), "items": record::decisions(&d)});
                println!("{v}");
                Ok(())
            }
            Err(e) => fail(e),
        },
        "add" => mutate(&mut |d| Ok(Some(record::add_step(d, &o.val("text"))))),
        "done" => mutate(&mut |d| record::complete(d, &o.val("id"), &o.val("evidence")).map(|_| None)),
        "status" => {
            let to = o.val("to");
            let Some(status) = record::Status::parse(&to) else {
                return fail(format!("unknown status: {to} — valid: {}", record::Status::valid_list()));
            };
            mutate(&mut |d| {
                if o.has("force") {
                    d.set_text("status", status.as_str());
                } else {
                    record::advance(d, status);
                }
                Ok(None)
            })
        }
        "wait" => {
            mutate(&mut |d| record::set_waiting(d, &o.val("on"), &o.val("ask"), &o.val("ref"), None).map(|_| None))
        }
        "unwait" => mutate(&mut |d| Ok(Some(if record::clear_waiting(d) { "cleared".into() } else { "none".into() }))),
        "waiting" => match record::read(&file) {
            Ok(d) => {
                if let Some(w) = record::waiting_of(&d) {
                    println!("{}", [w.on, w.ask, w.since, w.reference].join("\x1f"));
                }
                Ok(())
            }
            Err(e) => fail(e),
        },
        "retire" => mutate(&mut |d| {
            record::retire_branch(d, &o.val("repo"), &o.val("branch"), &o.val("workspace"));
            Ok(None)
        }),
        "reopen" => mutate(&mut |d| {
            record::reopen_branch(d, &o.val("repo"));
            Ok(None)
        }),
        "retired" => match record::read(&file) {
            Ok(d) => {
                for e in d.get("retired").map(record::Meta::list).unwrap_or_default() {
                    println!("{}", e.replacen('=', "\t", 1));
                }
                Ok(())
            }
            Err(e) => fail(e),
        },
        "meta" => mutate(&mut |d| {
            d.set_text(&o.val("key"), &o.val("value"));
            Ok(None)
        }),
        "places" => match record::read(&file) {
            Ok(d) => {
                let branches: std::collections::HashMap<String, String> = d
                    .list("branches")
                    .iter()
                    .filter_map(|e| {
                        e.split_once('=').map(|(a, b)| (a.to_string(), b.split('=').next().unwrap_or("").to_string()))
                    })
                    .collect();
                let ws = d.list("workspaces");
                for (i, r) in d.list("repos").iter().enumerate() {
                    println!(
                        "{}\t{}\t{}",
                        r,
                        branches.get(r).cloned().unwrap_or_default(),
                        ws.get(i).cloned().unwrap_or_default()
                    );
                }
                Ok(())
            }
            Err(e) => fail(e),
        },
        "branch" => mutate(&mut |d| {
            let repo = o.val("repo");
            let mut list: Vec<String> =
                d.list("branches").into_iter().filter(|e| !e.starts_with(&format!("{repo}="))).collect();
            list.push(format!("{repo}={}", o.val("branch")));
            d.set("branches", record::Meta::List(list));
            Ok(None)
        }),
        "verify" => {
            let receipt = std::fs::read_to_string(o.val("receipt")).unwrap_or_default();
            mutate(&mut |d| {
                record::verify(d, &receipt, &o.val("sha"));
                Ok(None)
            })
        }
        "summary" => match record::read(&file) {
            Ok(d) => {
                let r = record::summary(&d);
                if o.has("json") {
                    println!("{}", serde_json::to_string(&r).unwrap());
                } else {
                    // Unit separator and not tab: to the shell a tab is
                    // whitespace, and two in a row merge and shift the fields.
                    println!("{}", [r.task, r.status, r.steps, r.next].join("\x1f"));
                }
                Ok(())
            }
            Err(e) => fail(e),
        },
        "archive" => match record::archive(&file, true) {
            Ok(t) => {
                println!("{}", t.display());
                Ok(())
            }
            Err(e) => fail(e),
        },
        "body" => match record::read(&file) {
            Ok(d) => {
                print!("{}", record::proposal_body(&d, &o.val("lang"), &o.val("commits")));
                Ok(())
            }
            Err(e) => fail(e),
        },
        other => fail(format!("unknown operation: {other}")),
    }
}

/// `crux __task-sync <op>`: the replica, for the commands still in shell and
/// for the background publication.
pub fn internal_sync(argv: &[String]) -> Res {
    let Some(op) = argv.first() else { return fail("unknown operation: undefined") };
    let rest = &argv[1..];
    let o = Opts::parse(rest);
    let flag = |k: &str| rest.iter().any(|a| a == k);
    match op.as_str() {
        "sync" => {
            let all = flag("--all");
            let list = if all { sync::projects_with_tasks() } else { o.get("project").into_iter().collect() };
            if list.is_empty() && !all {
                return fail("missing --project or --all");
            }
            let fetched = flag("--fetched");
            let results: Vec<serde_json::Value> = list
                .iter()
                .map(|p| {
                    let run = || -> Result<serde_json::Map<String, serde_json::Value>, String> {
                        // Pulling comes first: what has to be reconciled may
                        // come from the other machine.
                        let mut s = sync::sync_project(p, fetched)?;
                        let closed = if all && s.get("status").and_then(|v| v.as_str()) == Some("ok") { sync::reconcile(p) } else { vec![] };
                        if !closed.is_empty() {
                            let before = s.clone();
                            s = sync::sync_project(p, fetched)?;
                            if let Some(v) = before.get("pulled") {
                                s.insert("pulled".into(), v.clone());
                            }
                            let mut w: Vec<serde_json::Value> = before.get("warnings").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                            w.extend(s.get("warnings").and_then(|v| v.as_array()).cloned().unwrap_or_default());
                            s.insert("warnings".into(), serde_json::Value::Array(w));
                            s.insert("closed".into(), serde_json::json!(closed));
                        }
                        Ok(s)
                    };
                    match run() {
                        Ok(s) => serde_json::Value::Object(s),
                        Err(e) => serde_json::json!({"project": p, "status": "failed", "reason": e.lines().next().unwrap_or("")}),
                    }
                })
                .collect();
            println!("{}", serde_json::Value::Array(results));
            Ok(())
        }
        "projects" => {
            println!("{}", sync::projects_with_tasks().join("\n"));
            Ok(())
        }
        "pending" => {
            println!("{}", sync::pending_projects().join("\n"));
            Ok(())
        }
        "open" => {
            println!("{}", serde_json::to_string(&remind::open_tasks(o.get("project").as_deref())).unwrap());
            Ok(())
        }
        "remind" => {
            let cwd = o.get("cwd").map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            if let Some(r) = remind::reminder(Path::new(&cwd), 6) {
                println!("{r}");
            }
            Ok(())
        }
        other => fail(format!("unknown operation: {other}")),
    }
}

/// The task record of the workspace that lives at that path, if it is one.
pub fn file_for_workspace(path: &str) -> Option<PathBuf> {
    let w = crate::registry::find_by_path(path)?;
    if w.task.is_empty() || w.project.is_empty() {
        return None;
    }
    Some(crate::env::tasks_dir().join(&w.project).join(format!("{}.md", w.task)))
}

/// Advances a record's status; false if the record cannot be written.
pub fn advance_file(file: &Path, status: record::Status) -> bool {
    let Ok(mut doc) = record::read(file) else { return false };
    record::advance(&mut doc, status);
    record::write(file, &mut doc, true).is_ok()
}

/// A task's decisions (the notes with a why) live in its record, which is
/// local and gets archived. Before archiving they move to repos/<repo>/notes.md
/// in the docs repo, which is what the next session reads, and are committed
/// there on their own. Archiving does not depend on this.
pub fn promote_decisions(record_file: &Path) {
    let Ok(doc) = record::read(record_file) else { return };
    let project = doc.text("project");
    if project.is_empty() {
        return;
    }
    let docs = crate::env::projects_root().join(&project).join(format!("{project}-docs"));
    if !docs.join(names::CONTRACT).is_file() {
        return;
    }
    let items = record::decisions(&doc);
    if items.is_empty() {
        return;
    }
    let day = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let mut out = vec![];
    for i in &items {
        out.push(format!("## {}, {day}", i.what));
        out.push(String::new());
        out.push(format!("Task: `{}`", doc.text("task")));
        out.push(String::new());
        for (k, v) in [("Why", &i.why), ("Where", &i.where_), ("Learned", &i.learned)] {
            if let Some(v) = v.as_ref().filter(|v| !v.is_empty()) {
                out.push(format!("- **{k}**: {v}"));
            }
        }
        out.push(String::new());
    }
    let entry = out.join("\n");
    let Some(repo) = doc.list("repos").into_iter().find(|r| !r.is_empty() && docs.join("repos").join(r).is_dir())
    else {
        crate::ui::warn(format!(
            "the task has decisions, but its repo has no folder in {}/repos/",
            crate::files::name(&docs)
        ));
        crate::ui::info(format!("move them by hand from: {}", record_file.display()));
        return;
    };
    let target = docs.join("repos").join(&repo).join("notes.md");
    // Read as empty, the notes already there would be overwritten by this entry.
    let read =
        if target.exists() { std::fs::read_to_string(&target).map_err(|e| e.to_string()) } else { Ok(String::new()) };
    let written = read.and_then(|mut text| {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&entry);
        text.push('\n');
        crate::files::write(&target, &text)
    });
    if let Err(e) = written {
        crate::ui::warn(format!("the task decisions could not go to {}: {e}", target.display()));
        crate::ui::info(format!("move them by hand from: {}", record_file.display()));
        return;
    }
    let rel = format!("repos/{repo}/notes.md");
    let docs_name = crate::files::name(&docs);
    let stem = record_file.file_stem().unwrap().to_string_lossy().into_owned();
    if crate::git::ok(&docs, &["add", "--", &rel])
        && crate::git::ok(
            &docs,
            &["commit", "-q", "-m", &format!("docs({repo}): decisions from task {stem}"), "--", &rel],
        )
    {
        crate::ui::ok(format!("task decisions in {docs_name}/{rel} (committed; push them with git push)"));
    } else {
        crate::ui::warn(format!("decisions written to {docs_name}/{rel}, but the commit could not be made"));
        crate::ui::info("review it and commit it by hand");
    }
}

/// The project from the layout: <root>/<project>/<repo>. A repo that hangs
/// directly from the root —the kernel itself— is its own project.
pub fn project_name_for(path: &Path) -> String {
    let root = crate::env::projects_root();
    let strip_ws = |s: &str| s.split("-ws-").next().unwrap_or(s).to_string();
    match path.strip_prefix(&root) {
        Ok(rel) => {
            let parts: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
            match parts.len() {
                0 => strip_ws(&path.file_name().unwrap_or_default().to_string_lossy()),
                1 => strip_ws(&parts[0]),
                _ => parts[0].clone(),
            }
        }
        Err(_) => strip_ws(&path.file_name().unwrap_or_default().to_string_lossy()),
    }
}
