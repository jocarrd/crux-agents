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

use super::guards::{drop_heredocs, runnable, segments};
use super::{cwd, field, input, session_or_parent, stop};
use crate::error::Res;
use crate::scope::{self, Person, Place, Scopes};
use crate::{env, person};
use serde_json::Value;
use std::path::{Path, PathBuf};

use crate::names::vars;

const VARS_THAT_MOVE_THE_WALL: [&str; 5] =
    [vars::SCOPE, vars::SCOPES_DIR, vars::STATE_DIR, vars::UNPINNED_SESSIONS, vars::TASKS_DIR];

/// The words of a shell command that may be paths, with quotes taken off but
/// their content kept: a quoted path is still a path.
fn path_words(command: &str, start: &Path) -> Vec<PathBuf> {
    let text = drop_heredocs(command);
    let mut here = start.to_path_buf();
    let mut out = vec![];
    for seg in segments(&text) {
        let words: Vec<String> = seg
            .split_whitespace()
            .map(|w| w.trim_matches(|c| c == '"' || c == '\'' || c == '(' || c == ')' || c == '`').to_string())
            .filter(|w| !w.is_empty())
            .collect();
        for (i, w) in words.iter().enumerate() {
            let w = w.rsplit_once('=').map_or(w.as_str(), |(_, v)| v);
            let w = w.trim_start_matches(['<', '>']);
            let looks = w.starts_with('/')
                || w.starts_with('~')
                || w.starts_with("$HOME")
                || w.starts_with("${HOME}")
                || w.starts_with("./")
                || w.starts_with("..")
                || (w.contains('/') && !w.contains("://") && !w.starts_with('-'));
            if !looks {
                continue;
            }
            let p = scope::expand(w);
            let p = if p.is_absolute() { p } else { here.join(p) };
            if i == 1 && words[0] == "cd" {
                here = p.clone();
            }
            out.push(p);
        }
    }
    out
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

fn touched(tool: &str, params: &Value, start: &Path) -> Vec<PathBuf> {
    if tool == "Bash" {
        return path_words(&field(params, "command"), start);
    }
    if tool == "apply_patch" {
        let body = ["patch", "input", "command"].iter().map(|k| field(params, k)).find(|v| !v.is_empty());
        return patch_paths(&body.unwrap_or_default(), start);
    }
    // A Glob pattern can be an absolute path with wildcards: its fixed part is
    // where it reads.
    let pattern = field(params, "pattern");
    let fixed = pattern.split(['*', '?', '[', '{']).next().unwrap_or("").to_string();
    let pattern_path = (fixed.starts_with('/') || fixed.starts_with('~')).then_some(fixed);
    ["file_path", "notebook_path", "path"]
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
        .collect()
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

/// The agent's transcripts and memory live under one folder named after the
/// session's starting path. A folder named after a root is that scope's; one
/// named after any other path holds front-desk sessions, whose files belong to
/// the scope each session was pinned to.
fn transcript_place(all: &Scopes, path: &Path, own_session: &str) -> Option<Option<Place>> {
    let base = scope::real_lenient(&env::claude_transcripts_dir());
    let real = scope::real_lenient(path);
    let rel = real.strip_prefix(&base).ok()?;
    let mut parts = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned());
    let Some(folder) = parts.next() else { return Some(None) };
    let encode = |p: &Path| p.to_string_lossy().replace(['/', '.'], "-");
    for s in &all.list {
        let e = encode(&s.real_root);
        if folder == e || folder.starts_with(&format!("{e}-")) {
            return Some(Some(Place { scope: s.name.clone(), project: None }));
        }
    }
    let file = rel.components().next_back().map(|c| c.as_os_str().to_string_lossy().into_owned()).unwrap_or_default();
    let session = file.trim_end_matches(".jsonl");
    if session == own_session {
        return Some(None);
    }
    match scope::pinned(session) {
        Some(p) => Some(Some(Place::parse(&p))),
        // A front-desk folder as a whole, or a session never pinned: it may
        // hold any scope's conversation.
        None => Some(Some(Place { scope: "?".into(), project: None })),
    }
}

/// The profile's notes: the shared ones are anyone's, a private one only
/// where the full profile applies.
fn profile_note(path: &Path) -> Option<bool> {
    let dir = person::dir()?;
    let real = scope::real_lenient(path);
    let rel = real.strip_prefix(scope::real_lenient(&dir)).ok()?;
    let rel = rel.to_string_lossy().into_owned();
    if rel.is_empty() || rel == "PROFILE.md" {
        return Some(false);
    }
    if rel.ends_with(".md") {
        return Some(person::is_shared(&dir, &rel));
    }
    Some(true)
}

fn crossing(all: &Scopes, pinned: Option<&Place>, path: &Path, own_session: &str) -> Option<String> {
    let real = scope::real_lenient(path);
    // Said resolved: `web/../../Own/x` is read as the folder it reaches.
    let path = real.as_path();
    // The wall's own stones: scopes, pins and their state are crux's to write.
    for guarded in [scope::dir(), scope::pins_dir()] {
        if scope::inside(&real, &scope::real_lenient(&guarded)) {
            return Some(format!(
                "'{}' is where crux keeps the scopes and the sessions' pins: it is changed with `crux scope`, \
                 never by hand, and a session cannot move its own pin.",
                path.display()
            ));
        }
    }
    if let Some(shared) = profile_note(path) {
        let person = pinned.map_or(Person::Shared, |p| all.person_at(p));
        if person == Person::Full || (shared && person == Person::Shared) {
            return None;
        }
        return Some(match pinned {
            None => format!(
                "'{}' is a private note of the person's profile. Enter the person's own scope first: `crux scope enter {}`.",
                path.display(),
                all.primary().name
            ),
            Some(_) => format!(
                "'{}' is a private note of the person's profile, and this session only sees its shared part. \
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
        if place.scope == "?" {
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
        return Some(format!(
            "'{}' belongs to {}, and this session is in {}. Work there needs a new session: `{}`, \
             or in an agent app a new thread in that folder. Tell the person instead of trying.",
            path.display(),
            describe(&Place { scope: place.scope.clone(), project: None }),
            describe(pin),
            open_hint(&Place { scope: place.scope.clone(), project: None })
        ));
    }
    let target = place.project.as_deref()?;
    match pin.project.as_deref() {
        Some(own) if own == target => None,
        Some(own) => Some(format!(
            "'{}' belongs to project '{target}', and this session is in the isolated project '{own}'. \
             Work there needs a new session: `{}`.",
            path.display(),
            open_hint(&Place { scope: place.scope.clone(), project: Some(target.into()) })
        )),
        None => {
            let s = all.by_name(&place.scope)?;
            if scope::project_rules(s, target).isolated && person::repo_name() != target {
                Some(format!(
                    "'{}' belongs to the isolated project '{target}'. It is worked on in a session of its own: `{}`.",
                    path.display(),
                    open_hint(&Place { scope: place.scope.clone(), project: Some(target.into()) })
                ))
            } else {
                None
            }
        }
    }
}

fn isolated_place(all: &Scopes, place: &Place) -> Place {
    let isolated = place
        .project
        .as_deref()
        .zip(all.by_name(&place.scope))
        .is_some_and(|(p, s)| scope::project_rules(s, p).isolated);
    Place { scope: place.scope.clone(), project: if isolated { place.project.clone() } else { None } }
}

fn describe(p: &Place) -> String {
    match &p.project {
        Some(pr) => format!("project '{pr}' of scope '{}'", p.scope),
        None => format!("scope '{}'", p.scope),
    }
}

/// `crux scope enter ...` pins the session before the command runs, so the
/// context it prints arrives already inside the wall.
fn entering(all: &Scopes, command: &str) -> Option<Result<Place, String>> {
    // Only where a command starts: an `echo "... crux scope enter x"` names it
    // without running it. The name may be quoted.
    let rx =
        crate::regex!(r#"(?m)(?:^|[;&|(]\s*)\s*crux\s+scope\s+enter\s+(--project\s+)?["']?([A-Za-z0-9_.-]+)["']?"#);
    let c = rx.captures(command)?;
    let name = c[2].to_string();
    let place = if c.get(1).is_some() {
        match crate::cmd::scope::scope_of_project(all, &name) {
            Some(s) => isolated_place(all, &Place { scope: s.name.clone(), project: Some(name) }),
            None => return Some(Err(format!("no scope has a project '{name}'"))),
        }
    } else if all.by_name(&name).is_some() {
        Place { scope: name, project: None }
    } else {
        return Some(Err(format!("no scope '{name}'")));
    };
    Some(Ok(place))
}

/// Network reach: one account can read every scope's repos, which no
/// filesystem rule sees.
fn other_owner(all: &Scopes, pinned: Option<&Place>, command: &str) -> Option<String> {
    for s in all.list.iter().filter(|s| pinned.is_none_or(|p| p.scope != s.name)) {
        for o in &s.owners {
            let o = regex::escape(o);
            let web = regex::Regex::new(&format!(r"(?i)github\.com[:/]{o}/")).ok()?;
            let gh = regex::Regex::new(&format!(r"(?i)(^|[;&|]\s*)gh\b[^;&|\n]*[\s=]{o}/")).ok()?;
            if web.is_match(command) || gh.is_match(command) {
                return Some(format!(
                    "this reaches '{}', an owner of scope '{}'. {}",
                    s.owners.join(" "),
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

fn stop_with(reason: &str) -> Res {
    stop(&format!("Stopped by the scope wall (ADR-025): {reason}\n"))
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
    let pinned = match scope::pinned(&session) {
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

    if let Some(rest) = tool.strip_prefix("mcp__") {
        let Some(p) = &pinned else { return Ok(()) };
        let Some(s) = all.by_name(&p.scope) else { return Ok(()) };
        if s.mcp_deny.iter().any(|pat| crate::files::glob_match(pat, &tool)) {
            return stop_with(&format!(
                "the connector '{rest}' is not used in scope '{}'. Tell the person; it belongs to another scope.",
                s.name
            ));
        }
        return Ok(());
    }

    if tool == "Bash" {
        let raw = field(&params, "command");
        // What runs, not what is quoted or written into a heredoc: a commit
        // message that mentions `crux scope enter` pins nothing.
        let command = runnable(&raw, true, true);
        for v in VARS_THAT_MOVE_THE_WALL {
            if regex::Regex::new(&format!(r"(^|[\s;&|(]){v}=")).is_ok_and(|r| r.is_match(&command))
                || command.contains(&format!("export {v}"))
                || command.contains(&format!("unset {v}"))
            {
                return stop_with(&format!("{v} decides which scope a command works in; a session does not set it."));
            }
        }
        if crate::regex!(r"\bcrux\s+(task|workspace)\b[^;&|\n]*\s--all\b").is_match(&command) {
            return stop_with("the list of every scope is for the person, not for a session. Ask them to run it.");
        }
        if let Some(r) = entering(&all, &drop_heredocs(&raw)) {
            let place = match r {
                Ok(p) => p,
                Err(e) => return stop_with(&e),
            };
            return match scope::pin(&session, &place.as_pin()) {
                Ok(_) => Ok(()),
                Err(e) => stop_with(&format!("{e}. Tell the person: `{}`.", open_hint(&place))),
            };
        }
        // A remote is often quoted: here the quotes stay, the heredocs go.
        if let Some(why) = other_owner(&all, pinned.as_ref(), &drop_heredocs(&raw)) {
            return stop_with(&why);
        }
    }

    for p in touched(&tool, &params, &start) {
        if let Some(why) = crossing(&all, pinned.as_ref(), &p, &session) {
            return stop_with(&why);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_and_relative_paths_are_found_and_cd_moves_the_base() {
        let p = path_words(r#"cat "/w/acme/x" && cd ../acme && cat file/y; ls"#, Path::new("/w/own"));
        assert!(p.contains(&PathBuf::from("/w/acme/x")), "{p:?}");
        assert!(p.contains(&PathBuf::from("/w/own/../acme")), "{p:?}");
        assert!(p.contains(&PathBuf::from("/w/own/../acme/file/y")), "{p:?}");
    }

    #[test]
    fn urls_flags_and_heredoc_bodies_are_not_paths() {
        let p = path_words("curl https://x.y/a -o out --data=v\ncat <<EOF\n/w/acme/secret\nEOF", Path::new("/w"));
        assert!(!p.iter().any(|x| x.to_string_lossy().contains("acme")), "{p:?}");
        assert!(!p.iter().any(|x| x.to_string_lossy().contains("x.y")), "{p:?}");
    }

    #[test]
    fn a_patch_names_its_files() {
        let p = patch_paths("*** Begin Patch\n*** Update File: src/a.rs\n*** Add File: /w/b.rs\n", Path::new("/w/r"));
        assert_eq!(p, vec![PathBuf::from("/w/r/src/a.rs"), PathBuf::from("/w/b.rs")]);
    }
}
