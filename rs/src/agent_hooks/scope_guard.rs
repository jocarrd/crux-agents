//! The wall between scopes (ADR-025). Before a tool runs, it finds every path
//! the call touches and the place each belongs to, and stops what crosses
//! from the place the session is pinned to into another: another scope,
//! another project when either is isolated, a secret declared elsewhere, a
//! private note of the profile where only the shared part applies.
//!
//! At the front desk nothing is pinned yet: the first call that touches a
//! scope is stopped with the command that enters it, so the session gets the
//! scope's context and the pin before it reads anything.
//!
//! It fails closed: scopes that cannot be read stop every call.

use super::guards::{drop_heredocs, segments};
use super::{cwd, field, input, session_or_parent, stop};
use crate::error::Res;
use crate::names::vars;
use crate::scope::{self, Person, Place, Scopes};
use crate::{env, person};
use serde_json::Value;
use std::path::{Path, PathBuf};

const VARS_THAT_MOVE_THE_WALL: [&str; 5] =
    [vars::SCOPE, vars::SCOPES_DIR, vars::STATE_DIR, vars::UNPINNED_SESSIONS, vars::TASKS_DIR];

/// Programs that read a whole tree when given a folder: given an ancestor of
/// another scope, they read it too.
const RECURSIVE: [&str; 12] = ["grep", "egrep", "rg", "ag", "find", "fd", "tar", "zip", "rsync", "du", "tree", "cp"];

/// One command of a shell line: its words without quotes, the program it
/// runs (past `env`, `sudo`, assignments and a path), and the folder it runs
/// from after the `cd`s before it.
struct Step {
    words: Vec<String>,
    program: usize,
    here: PathBuf,
}

impl Step {
    fn program(&self) -> &str {
        self.words.get(self.program).map_or("", |w| w.rsplit('/').next().unwrap_or(w))
    }

    fn args(&self) -> &[String] {
        self.words.get(self.program + 1..).unwrap_or(&[])
    }

    fn resolve(&self, w: &str) -> PathBuf {
        let p = scope::expand(w);
        if p.is_absolute() {
            p
        } else {
            self.here.join(p)
        }
    }
}

fn steps(command: &str, start: &Path) -> Vec<Step> {
    let text = drop_heredocs(command);
    let mut here = start.to_path_buf();
    let mut out = vec![];
    for seg in segments(&text) {
        let words: Vec<String> = seg
            .split_whitespace()
            .map(|w| w.trim_matches(|c| c == '"' || c == '\'' || c == '(' || c == ')' || c == '`').to_string())
            .filter(|w| !w.is_empty())
            .collect();
        let (mut program, mut wrapped) = (0, false);
        while let Some(w) = words.get(program) {
            let name = w.rsplit('/').next().unwrap_or(w);
            let wrapper = matches!(name, "env" | "sudo" | "command" | "exec" | "nice" | "nohup" | "time");
            let assignment = w.contains('=') && !w.starts_with('-') && !w.starts_with('/');
            let wrapper_option = wrapped && w.starts_with('-');
            if !(wrapper || assignment || wrapper_option) {
                break;
            }
            wrapped |= wrapper;
            program += 1;
        }
        let step = Step { words, program, here: here.clone() };
        if step.program() == "cd" {
            here = match step.args().first().map(String::as_str) {
                None | Some("~") => env::home(),
                Some("-") => here,
                Some(d) => step.resolve(d),
            };
        }
        out.push(step);
    }
    out
}

fn looks_like_path(w: &str) -> bool {
    w.starts_with('/')
        || w.starts_with('~')
        || w.starts_with("$HOME")
        || w.starts_with("${HOME}")
        || w.starts_with('.')
        || (w.contains('/') && !w.contains("://") && !w.starts_with('-'))
}

/// Every path a step touches: the folder it runs in, and each word that names
/// one. `grep -r .` reads the folder it stands in.
fn step_paths(step: &Step) -> Vec<PathBuf> {
    let mut out = vec![step.here.clone()];
    for w in &step.words {
        let w = w.rsplit_once('=').map_or(w.as_str(), |(_, v)| v);
        let w = w.trim_start_matches(['<', '>']);
        if looks_like_path(w) {
            out.push(step.resolve(w));
        }
    }
    if step.program() == "cd" {
        if let Some(d) = step.args().first() {
            out.push(step.resolve(d));
        }
    }
    out
}

/// Whether a step reads a tree. `grep` and `cp` only with their recursive flag.
fn reads_a_tree(step: &Step) -> bool {
    let p = step.program();
    if !RECURSIVE.contains(&p) {
        return p == "ls" && step.args().iter().any(|a| a.starts_with('-') && !a.starts_with("--") && a.contains('R'));
    }
    let flag = |c: char| step.args().iter().any(|a| a.starts_with('-') && !a.starts_with("--") && a.contains(c));
    match p {
        "grep" | "egrep" => flag('r') || flag('R') || step.args().iter().any(|a| a == "--recursive"),
        "cp" => flag('r') || flag('R') || flag('a') || step.args().iter().any(|a| a == "--recursive"),
        _ => true,
    }
}

/// Paths named in an `apply_patch` body (Codex): the files it adds, updates,
/// deletes or moves.
fn patch_paths(patch: &str, start: &Path) -> Vec<PathBuf> {
    let rx = crate::regex!(r"(?m)^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$");
    rx.captures_iter(patch)
        .filter_map(|c| c.get(1).or(c.get(2)).map(|m| m.as_str().trim().to_string()))
        .map(|p| {
            let p = scope::expand(&p);
            if p.is_absolute() {
                p
            } else {
                start.join(p)
            }
        })
        .collect()
}

/// The paths a non-shell tool reads or writes: its path fields, the fixed
/// part of a Glob pattern, and for a search with no path, the folder it runs
/// in.
fn tool_paths(tool: &str, params: &Value, start: &Path) -> Vec<PathBuf> {
    if tool == "apply_patch" {
        let body = ["patch", "input", "command"].iter().map(|k| field(params, k)).find(|v| !v.is_empty());
        return patch_paths(&body.unwrap_or_default(), start);
    }
    let pattern = field(params, "pattern");
    let fixed = pattern.split(['*', '?', '[', '{']).next().unwrap_or("").to_string();
    let pattern_path = (fixed.starts_with('/') || fixed.starts_with('~')).then_some(fixed);
    let mut out: Vec<PathBuf> = ["file_path", "notebook_path", "path"]
        .iter()
        .map(|k| field(params, k))
        .chain(pattern_path)
        .filter(|p| !p.is_empty())
        .map(|p| {
            let p = scope::expand(&p);
            if p.is_absolute() {
                p
            } else {
                start.join(p)
            }
        })
        .collect();
    if out.is_empty() && matches!(tool, "Grep" | "Glob" | "LS") {
        out.push(start.to_path_buf());
    }
    out
}

fn enter_hint(place: &Place) -> String {
    match &place.project {
        Some(p) => format!("crux scope enter --project {p}"),
        None => format!("crux scope enter {}", place.scope),
    }
}

fn open_hint(place: &Place) -> String {
    match &place.project {
        Some(p) => format!("crux scope open --project {p} --prompt \"<the request>\""),
        None => format!("crux scope open {} --prompt \"<the request>\"", place.scope),
    }
}

fn describe(p: &Place) -> String {
    match &p.project {
        Some(pr) => format!("project '{pr}' of scope '{}'", p.scope),
        None => format!("scope '{}'", p.scope),
    }
}

/// A place counts its project only when the project is isolated.
fn isolated_place(all: &Scopes, place: &Place) -> Place {
    let isolated = place
        .project
        .as_deref()
        .zip(all.by_name(&place.scope))
        .is_some_and(|(p, s)| scope::project_rules(s, p).isolated);
    Place { scope: place.scope.clone(), project: if isolated { place.project.clone() } else { None } }
}

const UNKNOWN: &str = "?";

/// The agent's transcripts and memory live under one folder per starting
/// path, named with every `/` and `.` turned into `-`. A folder named after a
/// root (or a project in it) is that scope's; the longest name wins, since
/// `acme-old` and `acme/old` read the same. Any other folder holds front-desk
/// sessions, each file the scope its session was pinned to. The folder as a
/// whole, or one that cannot be placed, holds conversations of any scope.
fn transcript_place(all: &Scopes, path: &Path, own_session: &str) -> Option<Option<Place>> {
    let base = scope::real_lenient(&env::claude_transcripts_dir());
    let real = scope::real_lenient(path);
    let rel = real.strip_prefix(&base).ok()?;
    let unknown = || Some(Some(Place { scope: UNKNOWN.into(), project: None }));
    let Some(folder) = rel.components().next().map(|c| c.as_os_str().to_string_lossy().into_owned()) else {
        return unknown();
    };
    let encode = |p: &Path| p.to_string_lossy().replace(['/', '.'], "-");
    let matches = |e: &str| folder == e || folder.starts_with(&format!("{e}-"));
    let best = all.list.iter().filter(|s| matches(&encode(&s.real_root))).max_by_key(|s| encode(&s.real_root).len());
    if let Some(s) = best {
        let project =
            scope::projects(s).into_iter().filter(|p| matches(&encode(&s.real_root.join(p)))).max_by_key(String::len);
        return Some(Some(isolated_place(all, &Place { scope: s.name.clone(), project })));
    }
    let file = rel.components().nth(1).map(|c| c.as_os_str().to_string_lossy().into_owned()).unwrap_or_default();
    let session = file.trim_end_matches(".jsonl");
    if !session.is_empty() && session == own_session {
        return Some(None);
    }
    match scope::pinned(session) {
        Some(p) => Some(Some(Place::parse(&p))),
        None => unknown(),
    }
}

/// Where a path falls in the person's profile: `Some(true)` for a shared note,
/// `Some(false)` for anything else in it (private notes, the full index,
/// folders, git's objects), `None` outside it.
fn profile_part(path: &Path) -> Option<bool> {
    let dir = person::dir()?;
    let real = scope::real_lenient(path);
    let rel = real.strip_prefix(scope::real_lenient(&dir)).ok()?.to_string_lossy().into_owned();
    Some(rel.ends_with(".md") && rel != "PROFILE.md" && person::is_shared(&dir, &rel))
}

/// The folders a session at a place must not reach into: other scopes' roots
/// and, inside its own scope, the projects its isolation leaves out. A path
/// that holds one of them (an ancestor) is as closed as the folder itself
/// when a tool reads it whole.
fn foreign_folders(all: &Scopes, pinned: Option<&Place>) -> Vec<(PathBuf, Place)> {
    let mut out = vec![];
    for s in &all.list {
        let mine = pinned.is_some_and(|p| p.scope == s.name);
        if !mine {
            out.push((s.real_root.clone(), Place { scope: s.name.clone(), project: None }));
            continue;
        }
        let pin = pinned.unwrap();
        for p in scope::projects(s) {
            let closed = match &pin.project {
                Some(own) => own != &p,
                None => scope::project_rules(s, &p).isolated,
            };
            if closed {
                out.push((s.real_root.join(&p), Place { scope: s.name.clone(), project: Some(p) }));
            }
        }
        if all.person_at(pin) != Person::Full {
            if let Some(d) = person::dir() {
                out.push((scope::real_lenient(&d), Place { scope: s.name.clone(), project: None }));
            }
        }
    }
    out.push((scope::real_lenient(&env::claude_transcripts_dir()), Place { scope: UNKNOWN.into(), project: None }));
    out
}

fn crossing(all: &Scopes, pinned: Option<&Place>, path: &Path, own_session: &str, writes: bool) -> Option<String> {
    let real = scope::real_lenient(path);
    // Said resolved: `web/../../Own/x` is read as the folder it reaches.
    let path = real.as_path();
    for guarded in [scope::dir(), scope::pins_dir()] {
        if scope::inside(&real, &scope::real_lenient(&guarded)) {
            return Some(format!(
                "'{}' is where crux keeps the scopes and the sessions' pins: it is changed with `crux scope`, \
                 never by hand, and a session cannot move its own pin.",
                path.display()
            ));
        }
    }
    if let Some(shared) = profile_part(path) {
        let person = pinned.map_or(Person::Shared, |p| all.person_at(p));
        let primary = pinned.is_none_or(|p| p.scope == all.primary().name);
        if writes && !primary {
            return Some(format!(
                "'{}' is the person's profile, which travels under their own account: it is not written from \
                 scope '{}'. Tell the person what to note instead.",
                path.display(),
                pinned.map_or("", |p| p.scope.as_str())
            ));
        }
        if person == Person::Full || (shared && person == Person::Shared) {
            return None;
        }
        return Some(match pinned {
            None => format!(
                "'{}' is private to the person's profile. Enter the person's own scope first: `crux scope enter {}`.",
                path.display(),
                all.primary().name
            ),
            Some(_) => format!(
                "'{}' is private to the person's profile, and this session only sees its shared part. \
                 If something should be noted there, tell the person instead of writing it.",
                path.display()
            ),
        });
    }
    let place = match transcript_place(all, path, own_session) {
        Some(None) => return None,
        Some(Some(p)) => p,
        None => all.place_of(path)?,
    };
    let Some(pin) = pinned else {
        if place.scope == UNKNOWN {
            return Some(format!("'{}' holds other sessions' conversations.", path.display()));
        }
        let rules_place = isolated_place(all, &place);
        return Some(format!(
            "'{}' belongs to {}. This session is at the front desk: enter it first with `{}`. \
             That pins the session there for good and gives it that context.",
            path.display(),
            describe(&rules_place),
            enter_hint(&rules_place)
        ));
    };
    if place.scope != pin.scope {
        if place.scope == UNKNOWN {
            return Some(format!("'{}' holds other sessions' conversations.", path.display()));
        }
        let other = Place { scope: place.scope.clone(), project: None };
        return Some(format!(
            "'{}' belongs to {}, and this session is in {}. Work there needs a new session: `{}`, \
             or in an agent app a new thread in that folder. Tell the person instead of trying.",
            path.display(),
            describe(&other),
            describe(pin),
            open_hint(&other)
        ));
    }
    let target = place.project.as_deref()?;
    let target_place = Place { scope: place.scope.clone(), project: Some(target.into()) };
    match pin.project.as_deref() {
        Some(own) if own == target => None,
        Some(own) => Some(format!(
            "'{}' belongs to project '{target}', and this session is in the isolated project '{own}'. \
             Work there needs a new session: `{}`.",
            path.display(),
            open_hint(&target_place)
        )),
        None => {
            let s = all.by_name(&place.scope)?;
            (scope::project_rules(s, target).isolated && person::repo_name() != target).then(|| {
                format!(
                    "'{}' belongs to the isolated project '{target}'. It is worked on in a session of its own: `{}`.",
                    path.display(),
                    open_hint(&target_place)
                )
            })
        }
    }
}

/// A folder read whole that holds what this session may not reach.
fn holds_foreign(foreign: &[(PathBuf, Place)], path: &Path) -> Option<String> {
    let real = scope::real_lenient(path);
    let (f, place) = foreign.iter().find(|(f, _)| scope::inside(f, &real) && *f != real)?;
    Some(format!(
        "'{}' holds {} ({}): reading it whole reads that too. Name a folder of this scope instead.",
        real.display(),
        if place.scope == UNKNOWN { "other sessions' conversations".to_string() } else { describe(place) },
        f.display()
    ))
}

/// Network reach: one account can read every scope's repos, which no
/// filesystem rule sees. For `gh`, the owner can be a bare argument
/// (`gh repo list acme`) or part of an API path (`repos/acme/x`).
fn other_owner(all: &Scopes, pinned: Option<&Place>, command: &str, steps: &[Step]) -> Option<String> {
    for s in all.list.iter().filter(|s| pinned.is_none_or(|p| p.scope != s.name)) {
        for o in &s.owners {
            let lo = o.to_lowercase();
            let web = regex::Regex::new(&format!(r"(?i)github\.com[:/]{}/", regex::escape(o))).ok()?;
            let by_gh = steps.iter().filter(|st| st.program() == "gh").any(|st| {
                st.args().iter().any(|a| {
                    let a = a.to_lowercase();
                    a == lo
                        || a.starts_with(&format!("{lo}/"))
                        || a.contains(&format!("={lo}/"))
                        || ["repos/", "orgs/", "users/"].iter().any(|k| a.contains(&format!("{k}{lo}")))
                })
            });
            if web.is_match(command) || by_gh {
                return Some(format!(
                    "this reaches '{o}', an owner of scope '{}'. {}",
                    s.name,
                    match pinned {
                        Some(_) => format!(
                            "Work there needs a new session: `{}`.",
                            open_hint(&Place { scope: s.name.clone(), project: None })
                        ),
                        None => format!("Enter it first: `crux scope enter {}`.", s.name),
                    }
                ));
            }
        }
    }
    None
}

/// What a `crux` step asks of the wall: entering a scope pins the session
/// before the command prints that scope's context; some subcommands are the
/// person's to run.
enum CruxStep {
    Enter(Place),
    Refused(String),
    FolderBound,
    Free,
}

fn crux_step(all: &Scopes, pinned: Option<&Place>, step: &Step) -> CruxStep {
    let args = step.args();
    let sub = args.first().map(String::as_str).unwrap_or("");
    if matches!(sub, "task" | "workspace") && args.iter().any(|a| a == "--all") {
        return CruxStep::Refused(
            "the list of every scope is for the person, not for a session. Ask them to run it.".into(),
        );
    }
    if sub != "scope" {
        return if matches!(sub, "" | "prose" | "help" | "version" | "--version" | "-v" | "hook" | "__fn") {
            CruxStep::Free
        } else {
            CruxStep::FolderBound
        };
    }
    let verb = args.get(1).map(String::as_str).unwrap_or("");
    let rest = args.get(2..).unwrap_or(&[]);
    let named = rest.iter().position(|a| a == "--project").and_then(|i| rest.get(i + 1));
    match verb {
        "enter" => {
            let place = match (named, rest.iter().find(|a| !a.starts_with('-'))) {
                (Some(p), _) => match all.scope_of_project(p) {
                    Ok(s) => isolated_place(all, &Place { scope: s.name.clone(), project: Some(p.clone()) }),
                    Err(e) => return CruxStep::Refused(e),
                },
                (None, Some(n)) if all.by_name(n).is_some() => Place { scope: n.clone(), project: None },
                (None, Some(n)) => return CruxStep::Refused(format!("no scope '{n}'")),
                (None, None) => return CruxStep::Refused("which scope: crux scope enter <name>".into()),
            };
            CruxStep::Enter(place)
        }
        "move" => CruxStep::Refused(
            "a project changes scope by the person's decision: ask them to run `crux scope move` themselves.".into(),
        ),
        "show" => match (pinned, rest.first()) {
            (Some(p), Some(n)) if *n != p.scope => {
                CruxStep::Refused(format!("scope '{n}' is not this session's: what it declares is not read from here."))
            }
            _ => CruxStep::Free,
        },
        _ => CruxStep::Free,
    }
}

fn stop_with(reason: &str) -> Res {
    stop(&format!("Stopped by the scope wall (ADR-025): {reason}\n"))
}

/// The pin's file is touched while the session lives, so the sweep of old
/// pins never takes one from a session that is still working.
fn keep_alive(session: &str) {
    scope::refresh_pin(session);
}

pub(super) fn scope_guard() -> Res {
    let event = input();
    let all = match scope::load() {
        Ok(a) if a.declared => a,
        Ok(_) => return Ok(()),
        Err(e) => return stop_with(&format!("the scopes cannot be read, so nothing runs until they are fixed: {e}")),
    };
    let session = session_or_parent(&event);
    let tool = field(&event, "tool_name");
    let params = event.get("tool_input").cloned().unwrap_or(Value::Null);
    let start = match field(&event, "cwd") {
        c if c.is_empty() => cwd(),
        c => PathBuf::from(c),
    };
    // A session that opened inside a root without going through session
    // start (one already open when the scopes were declared) is pinned where
    // it stands. A front-desk session cannot stand in a root: the command that
    // would take it there names the path and is stopped first.
    let mut pinned = match scope::pinned(&session) {
        Some(p) => Some(Place::parse(&p)),
        None => match all.pin_place(&start) {
            Some(place) => {
                if let Err(e) = scope::pin(&session, &place.as_pin()) {
                    return stop_with(&e);
                }
                Some(place)
            }
            None => None,
        },
    };
    if pinned.is_some() {
        keep_alive(&session);
    }

    if let Some(rest) = tool.strip_prefix("mcp__") {
        if let Some(s) = pinned.as_ref().and_then(|p| all.by_name(&p.scope)) {
            if s.mcp_deny.iter().any(|pat| crate::files::glob_match(pat, &tool)) {
                return stop_with(&format!(
                    "the connector '{rest}' is not used in scope '{}'. Tell the person; it belongs to another scope.",
                    s.name
                ));
            }
        }
    }

    let writes = matches!(tool.as_str(), "Write" | "Edit" | "MultiEdit" | "NotebookEdit" | "apply_patch");
    let mut paths: Vec<(PathBuf, bool)> = vec![];
    let foreign_reads: Vec<PathBuf>;
    if tool == "Bash" {
        let raw = field(&params, "command");
        let text = drop_heredocs(&raw);
        let steps = steps(&raw, &start);
        // Where an assignment takes effect: before the program (`X=1 cmd`,
        // `env "X=1" cmd`) or as what export and its kin set. A commit message
        // that mentions one sets nothing.
        for st in &steps {
            let setters = matches!(st.program(), "export" | "unset" | "declare" | "typeset" | "local" | "readonly");
            let words = if setters { &st.words[..] } else { &st.words[..st.program.min(st.words.len())] };
            if let Some(v) = VARS_THAT_MOVE_THE_WALL
                .iter()
                .find(|v| words.iter().any(|w| w == *v || w.starts_with(&format!("{v}="))))
            {
                return stop_with(&format!("{v} decides which scope a command works in; a session does not set it."));
            }
        }
        if let Some(why) = other_owner(&all, pinned.as_ref(), &text, &steps) {
            return stop_with(&why);
        }
        let mut trees = vec![];
        for st in &steps {
            if st.program() == "crux" {
                match crux_step(&all, pinned.as_ref(), st) {
                    CruxStep::Refused(why) => return stop_with(&why),
                    CruxStep::Enter(place) => match scope::pin(&session, &place.as_pin()) {
                        Ok(_) => pinned = Some(place),
                        Err(e) => return stop_with(&format!("{e}. Tell the person: `{}`.", open_hint(&place))),
                    },
                    CruxStep::FolderBound => {
                        if let Some(s) = pinned.as_ref().and_then(|p| all.by_name(&p.scope)) {
                            if !s.contains(&st.here) {
                                return stop_with(&format!(
                                    "crux works in the scope of the folder it runs from, and {} is outside scope '{}'. \
                                     Run it from inside: `cd {} && {}`.",
                                    st.here.display(),
                                    s.name,
                                    s.root.display(),
                                    st.words.join(" ")
                                ));
                            }
                        }
                    }
                    CruxStep::Free => {}
                }
            }
            let ps = step_paths(st);
            if reads_a_tree(st) {
                trees.extend(ps.iter().cloned());
            }
            paths.extend(ps.into_iter().map(|p| (p, true)));
        }
        foreign_reads = trees;
    } else {
        let ps = tool_paths(&tool, &params, &start);
        foreign_reads = if matches!(tool.as_str(), "Grep" | "Glob" | "LS") { ps.clone() } else { vec![] };
        paths.extend(ps.into_iter().map(|p| (p, writes)));
    }

    let foreign = foreign_folders(&all, pinned.as_ref());
    for p in &foreign_reads {
        if let Some(why) = holds_foreign(&foreign, p) {
            return stop_with(&why);
        }
    }
    for (p, w) in &paths {
        if let Some(why) = crossing(&all, pinned.as_ref(), p, &session, *w) {
            return stop_with(&why);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(cmd: &str, start: &str) -> Vec<PathBuf> {
        steps(cmd, Path::new(start)).iter().flat_map(step_paths).collect()
    }

    #[test]
    fn quoted_relative_and_bare_cd_paths_are_found() {
        let p = paths(r#"cat "/w/acme/x" && cd .. && cd acme && grep -r token ."#, "/w/own");
        assert!(p.contains(&PathBuf::from("/w/acme/x")), "{p:?}");
        assert!(p.contains(&PathBuf::from("/w/own/../acme")), "a cd without a slash moves the base: {p:?}");
        assert!(p.contains(&PathBuf::from("/w/own/../acme/.")), "{p:?}");
    }

    #[test]
    fn urls_flags_and_heredoc_bodies_are_not_paths() {
        let p = paths("curl https://x.y/a -o out --data=v\ncat <<EOF\n/w/acme/secret\nEOF", "/w");
        assert!(!p.iter().any(|x| x.to_string_lossy().contains("acme")), "{p:?}");
        assert!(!p.iter().any(|x| x.to_string_lossy().contains("x.y")), "{p:?}");
    }

    #[test]
    fn the_program_is_found_past_wrappers_and_paths() {
        let s = steps(
            r#"env "CRUX_SCOPE=x" /opt/bin/crux scope enter acme; sudo -E grep -r a /w; /usr/bin/env crux scope"#,
            Path::new("/"),
        );
        assert_eq!(s[2].program(), "crux", "a wrapper named by its path is still a wrapper");
        assert_eq!(s[0].program(), "crux");
        assert_eq!(s[0].args().first().map(String::as_str), Some("scope"));
        assert_eq!(s[1].program(), "grep");
        assert!(reads_a_tree(&s[1]));
    }

    #[test]
    fn only_recursive_reads_are_tree_reads() {
        let s = steps("grep a f; cp a b; cp -r a b; ls -la; ls -R x", Path::new("/"));
        assert_eq!(s.iter().map(reads_a_tree).collect::<Vec<_>>(), vec![false, false, true, false, true]);
    }

    #[test]
    fn a_patch_names_its_files() {
        let p = patch_paths("*** Begin Patch\n*** Update File: src/a.rs\n*** Add File: /w/b.rs\n", Path::new("/w/r"));
        assert_eq!(p, vec![PathBuf::from("/w/r/src/a.rs"), PathBuf::from("/w/b.rs")]);
    }
}
