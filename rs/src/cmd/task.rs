//! crux task — the record of the task of the workspace you are in.
//!
//! The record lives in ~/.crux/tasks/<project>/<task>.md: local state, next
//! to the workspace registry, and outside the repos. Not the code one —in a
//! client's it cannot go, and a task spanning several repos would be split—
//! nor the documentation one, which is for what lasts. See ADR-012.

use crate::args::Parser;
use crate::error::{Exit, Res};
use crate::task::{self, record};
use crate::{die, env, git, project, registry, sh, ui};
use std::path::{Path, PathBuf};

/// To stderr: called where the output is captured, an error on stdout would
/// end up inside the value and the command would exit without saying why.
fn fail<T>(msg: impl AsRef<str>) -> Result<T, Exit> {
    eprintln!("{}error{} {}", ui::palette().red, ui::palette().off, msg.as_ref());
    Err(Exit(1))
}

fn current_file(chosen: &str) -> Result<PathBuf, Exit> {
    if !chosen.is_empty() {
        if !chosen.contains('/') {
            return fail("--task goes as <project>/<task>");
        }
        return Ok(env::tasks_dir().join(format!("{chosen}.md")));
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(here) = git::toplevel(&cwd) else {
        return fail("you are not in a repo: use --task <project>/<task>, or 'crux task list'");
    };
    match task::file_for_workspace(&here.to_string_lossy()) {
        Some(f) => Ok(f),
        None => fail("you are not in a workspace with a task: 'crux workspace new <task>', or --task <project>/<task>"),
    }
}

fn mutate(f: &Path, op: impl FnOnce(&mut record::Doc) -> Result<(), String>) -> Res {
    let mut doc = match record::read(f) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}");
            return Err(Exit(1));
        }
    };
    if let Err(e) = op(&mut doc) {
        eprintln!("{e}");
        return Err(Exit(1));
    }
    if let Err(e) = record::write(f, &mut doc, true) {
        eprintln!("{e}");
        return Err(Exit(1));
    }
    Ok(())
}

/// When going into waiting, a clean workspace and a branch with nothing of
/// its own only take up room. They are removed; whatever has unpublished work
/// stays and is reported.
fn retire_idle(f: &Path) -> Res {
    let doc = record::read(f).unwrap_or_default();
    let task_name = doc.text("task");
    let project_name = crate::files::name(f.parent().unwrap());
    let list = match registry::read() {
        Ok(l) => l,
        Err(_) => die!("could not read the workspace registry {}", registry::path().display()),
    };
    let mine: Vec<registry::Workspace> =
        list.into_iter().filter(|w| w.project == project_name && w.task == task_name).collect();
    if mine.is_empty() {
        ui::info("the task has no workspaces on this machine");
        return Ok(());
    }
    for w in mine {
        let (repo, path) = (PathBuf::from(&w.repo), PathBuf::from(&w.path));
        if path.is_dir() && !git::out(&path, &["status", "--porcelain"]).unwrap_or_default().is_empty() {
            ui::warn(format!("{} has uncommitted changes: it stays", w.name));
            continue;
        }
        let main = project::main_branch(&repo);
        let ahead: i64 = git::out(&repo, &["rev-list", "--count", &format!("{main}..{}", w.branch)])
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let mut merged_pr = String::new();
        if ahead > 0 {
            merged_pr = sh::capture_in(
                &repo,
                "gh",
                &[
                    "pr",
                    "list",
                    "--head",
                    &w.branch,
                    "--state",
                    "merged",
                    "--json",
                    "number",
                    "-q",
                    ".[0].number // \"\"",
                ],
            )
            .out();
            if merged_pr.is_empty() {
                ui::warn(format!("{} has {ahead} unmerged commit(s) in {}: it stays", w.name, w.branch));
                continue;
            }
        }
        if path.is_dir()
            && !super::call_quiet(
                &std::env::current_dir().unwrap_or_default(),
                "workspace",
                &["rm", &w.name, "--include-ignored"],
            )
            .ok()
        {
            ui::warn(format!("could not remove workspace {}: crux workspace rm {}", w.name, w.name));
            continue;
        }
        git::run(&repo, &["branch", "-D", &w.branch]);
        if !merged_pr.is_empty()
            && git::ok(&repo, &["ls-remote", "--exit-code", "--heads", "origin", &w.branch])
            && !git::ok(&repo, &["push", "-q", "origin", "--delete", &w.branch])
        {
            ui::warn(format!("could not delete remote branch {}", w.branch));
        }
        let repo_name = crate::files::name(&repo);
        mutate(f, |d| {
            record::retire_branch(d, &repo_name, &w.branch, &w.name);
            Ok(())
        })?;
        let merged = if merged_pr.is_empty() { String::new() } else { format!(" (merged in #{merged_pr})") };
        ui::ok(format!("{} removed, and its branch {}{merged}", w.name, w.branch));
    }
    Ok(())
}

fn cut(t: &str, n: usize) -> String {
    t.chars().take(n).collect()
}

fn list(args: &[String]) -> Res {
    let all = args.iter().any(|a| a == "--all");
    let done = args.iter().any(|a| a == "--done");
    let tasks = env::tasks_dir();
    if done {
        let mut found = false;
        for p in project::subdirs(&tasks) {
            let mut names: Vec<String> = std::fs::read_dir(tasks.join(&p).join("done"))
                .map(|e| {
                    e.flatten()
                        .map(|x| x.file_name().to_string_lossy().into_owned())
                        .filter(|n| n.ends_with(".md"))
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            for n in names {
                found = true;
                println!("{p:<12} {}", n.trim_end_matches(".md"));
            }
        }
        if !found {
            println!("no archived tasks");
        }
        return Ok(());
    }
    if !tasks.is_dir() {
        println!("no open tasks");
        return Ok(());
    }
    let mut scope = String::new();
    if !all {
        if let Some(here) = git::toplevel(&std::env::current_dir().unwrap_or_default()) {
            scope = task::project_name_for(&here);
        }
    }
    let mut found = false;
    for p in project::subdirs(&tasks) {
        if !scope.is_empty() && p != scope {
            continue;
        }
        let mut names: Vec<String> = std::fs::read_dir(tasks.join(&p))
            .map(|e| {
                e.flatten()
                    .map(|x| x.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.ends_with(".md"))
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        for n in names {
            let f = tasks.join(&p).join(&n);
            let Ok(doc) = record::read(&f) else { continue };
            let s = record::summary(&doc);
            if s.status == record::Status::Closed.as_str() {
                continue;
            }
            found = true;
            let label = format!("{p}/{}", s.task);
            if let Some(w) = &s.waiting {
                println!(
                    "{label:<28} {:<12} {:<6} to {} since {}: {}",
                    "waiting",
                    s.steps,
                    w.on,
                    w.since,
                    cut(&w.ask, 50)
                );
                continue;
            }
            println!("{label:<28} {:<12} {:<6} {}", s.status, s.steps, cut(&s.next, 70));
        }
    }
    if !found {
        let hint = if scope.is_empty() { String::new() } else { format!(" in {scope} (all: crux task list --all)") };
        println!("no open tasks{hint}");
    }
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let op = argv.first().cloned().unwrap_or_else(|| "show".into());
    let mut chosen = String::new();
    let mut args: Vec<String> = vec![];
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    let mut p = Parser::new(rest);
    while let Some(arg) = p.next() {
        match arg {
            "--task" => chosen = p.value(),
            other => args.push(other.to_string()),
        }
    }
    let arg = |n: usize| args.get(n).cloned().unwrap_or_default();
    match op.as_str() {
        "show" => {
            let f = current_file(&chosen)?;
            if !f.is_file() {
                die!("the record {} does not exist", f.display());
            }
            let s = record::summary(&record::read(&f).unwrap_or_default());
            println!(
                "task {} · {}{}",
                s.task,
                s.status,
                if s.steps.is_empty() { String::new() } else { format!(" · steps {}", s.steps) }
            );
            if s.next.is_empty() {
                ui::info("no next step: crux task next \"...\"");
            } else {
                println!("next: {}", s.next);
            }
            ui::info(f.display().to_string());
            Ok(())
        }
        "path" => {
            println!("{}", current_file(&chosen)?.display());
            Ok(())
        }
        "goal" | "scope" | "next" => {
            let f = current_file(&chosen)?;
            if arg(0).is_empty() {
                die!("usage: crux task {op} \"<text>\"");
            }
            let (section, said) = match op.as_str() {
                "goal" => ("Objective", "objective noted"),
                "scope" => ("Scope", "scope noted"),
                _ => ("Next step", "next step noted"),
            };
            mutate(&f, |d| {
                record::set_section(d, section, &arg(0));
                Ok(())
            })?;
            ui::ok(said);
            Ok(())
        }
        "plan" => {
            let f = current_file(&chosen)?;
            let Ok(plan) = std::fs::read_to_string(arg(0)) else {
                die!("usage: crux task plan <file with the approved plan>")
            };
            mutate(&f, |d| {
                record::set_section(d, "Plan", plan.trim_end_matches('\n'));
                record::advance(d, record::Status::Planned);
                Ok(())
            })?;
            ui::ok("plan dumped to the record");
            Ok(())
        }
        "add" => {
            // Several steps in one call: noting a plan one by one is what adds
            // the most calls to the cycle.
            let f = current_file(&chosen)?;
            if arg(0).is_empty() {
                die!("usage: crux task add \"<step>\" [\"<step>\"...]");
            }
            for step in &args {
                let mut id = String::new();
                mutate(&f, |d| {
                    id = record::add_step(d, step);
                    Ok(())
                })?;
                ui::ok(format!("{id} {step}"));
            }
            Ok(())
        }
        "done" => {
            let f = current_file(&chosen)?;
            if arg(0).is_empty() {
                die!("usage: crux task done <Tn> [\"evidence\"]");
            }
            mutate(&f, |d| record::complete(d, &arg(0), &arg(1)))?;
            ui::ok(format!("{} done", arg(0)));
            if arg(1).is_empty() {
                ui::info("no evidence: a step marked without what proves it is a declaration");
            }
            Ok(())
        }
        "note" => {
            let f = current_file(&chosen)?;
            let what = arg(0);
            if what.is_empty() || what.starts_with("--") {
                die!("usage: crux task note \"<what>\" [--why \"…\"] [--where \"…\"] [--learned \"…\"]");
            }
            let (mut why, mut where_, mut learned) = (String::new(), String::new(), String::new());
            let mut j = 1;
            while j < args.len() {
                match args[j].as_str() {
                    k @ ("--why" | "--where" | "--learned") => {
                        let v = args.get(j + 1).cloned().unwrap_or_default();
                        if v.is_empty() || v.starts_with("--") {
                            die!("{k} needs a text");
                        }
                        match k {
                            "--why" => why = v,
                            "--where" => where_ = v,
                            _ => learned = v,
                        }
                        j += 2;
                    }
                    other => die!("unknown option: {other}"),
                }
            }
            mutate(&f, |d| {
                record::append(d, "Deviations and decisions", &record::decision_line(&what, &why, &where_, &learned));
                Ok(())
            })?;
            if !why.is_empty() {
                ui::ok("decision noted: when the task is archived it goes to the repo notes in the docs repo");
            } else {
                ui::ok("noted in deviations and decisions");
                ui::info("if it is a decision that has to last, add its why: --why \"…\"");
            }
            Ok(())
        }
        "status" => {
            let f = current_file(&chosen)?;
            let to = arg(0);
            if to.is_empty() {
                die!("usage: crux task status <status> [--force]");
            }
            let Some(status) = record::Status::parse(&to) else {
                eprintln!("unknown status: {to} — valid: {}", record::Status::valid_list());
                return Err(Exit(1));
            };
            let force = arg(1) == "--force";
            mutate(&f, |d| {
                if force {
                    d.set_text("status", status.as_str());
                } else {
                    record::advance(d, status);
                }
                Ok(())
            })?;
            ui::ok(format!("status: {}", record::read(&f).map(|d| d.text("status")).unwrap_or_default()));
            Ok(())
        }
        "wait" => {
            let f = current_file(&chosen)?;
            if !f.is_file() {
                die!("the record {} does not exist", f.display());
            }
            let (mut on, mut ask, mut reference, mut keep) = (String::new(), String::new(), String::new(), false);
            let mut j = 0;
            while j < args.len() {
                match args[j].as_str() {
                    k @ ("--on" | "--ask" | "--ref") => {
                        let v = args.get(j + 1).cloned().unwrap_or_default();
                        if v.is_empty() || v.starts_with("--") {
                            die!("{k} needs a text");
                        }
                        match k {
                            "--on" => on = v,
                            "--ask" => ask = v,
                            _ => reference = v,
                        }
                        j += 2;
                    }
                    "--keep" => {
                        keep = true;
                        j += 1;
                    }
                    other => die!("unknown option: {other}"),
                }
            }
            if on.is_empty() || ask.is_empty() {
                die!("usage: crux task wait --on \"<who>\" --ask \"<what>\" [--ref \"<where>\"] [--keep]");
            }
            mutate(&f, |d| record::set_waiting(d, &on, &ask, &reference, None))?;
            ui::ok(format!("waiting on {on}: {ask}"));
            if keep {
                ui::info("workspaces and branches untouched (--keep)");
            } else {
                retire_idle(&f)?;
            }
            let name = record::read(&f).map(|d| d.text("task")).unwrap_or_default();
            ui::info(format!("when the answer arrives: crux workspace resume {name}, or crux task unwait"));
            Ok(())
        }
        "unwait" => {
            let f = current_file(&chosen)?;
            if !f.is_file() {
                die!("the record {} does not exist", f.display());
            }
            let mut cleared = false;
            mutate(&f, |d| {
                cleared = record::clear_waiting(d);
                Ok(())
            })?;
            if cleared {
                ui::ok("the task no longer waits for an answer")
            } else {
                ui::info("the task was not waiting")
            }
            Ok(())
        }
        "archive" => {
            let f = current_file(&chosen)?;
            if !f.is_file() {
                die!("the record {} does not exist", f.display());
            }
            task::promote_decisions(&f);
            match record::archive(&f, true) {
                Ok(t) => {
                    ui::ok(format!("task archived: {}", t.display()));
                    Ok(())
                }
                Err(e) => {
                    eprintln!("{e}");
                    Err(Exit(1))
                }
            }
        }
        "list" => list(&args),
        "-h" | "--help" | "help" => {
            super::help("task");
            Ok(())
        }
        other => die!("unknown subcommand: {other} — 'crux task --help'"),
    }
}
