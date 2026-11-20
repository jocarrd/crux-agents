//! The wall between scopes (ADR-025). Before a tool runs, it finds every path
//! the call touches and the place each belongs to, and stops what crosses
//! from the place the session is pinned to into another: another scope,
//! another project when either is isolated, a secret declared elsewhere, a
//! private part of the profile where only the shared part applies, the
//! agents' conversations, and what holds the wall up.
//!
//! At the front desk nothing is pinned yet: the first call that touches a
//! scope is stopped with the command that enters it, so the session gets the
//! scope's context and the pin before it reads anything. With one scope there
//! is no front desk: every session is in it.
//!
//! It fails closed: scopes that cannot be read stop every call, and so does a
//! pinned session whose scopes are gone.

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

/// Options of a wrapper that take a value: `nice -n 10 crux`.
const WRAPPER_OPTIONS_WITH_VALUE: [&str; 6] = ["-n", "-u", "-g", "-C", "-U", "-p"];

/// Programs that write every path they are given; `mv` takes its sources away.
const WRITERS: [&str; 10] = ["tee", "rm", "touch", "mkdir", "rmdir", "truncate", "chmod", "chown", "dd", "mv"];
/// Programs that write only the last path they are given.
const COPIERS: [&str; 4] = ["cp", "ln", "install", "rsync"];
/// Programs that read a whole tree when given a folder.
const RECURSIVE: [&str; 12] = ["grep", "egrep", "rg", "ag", "find", "fd", "tar", "zip", "rsync", "du", "tree", "cp"];
/// Arguments of git and gh that are text, not paths.
const MESSAGE_OPTIONS: [&str; 6] = ["-m", "--message", "--body", "--title", "--subject", "--notes"];

/// A program's name, whatever path it is called through.
fn program_name(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

fn resolve(base: &Path, word: &str) -> PathBuf {
    let p = scope::expand(word);
    if p.is_absolute() {
        p
    } else {
        base.join(p)
    }
}

// --- Reading a shell line ---------------------------------------------------

/// One command of a shell line: its words as the shell splits them, the
/// program it runs (past `env`, `sudo`, assignments and a path), and the
/// folder it runs from after the `cd`s before it.
struct Step {
    words: Vec<String>,
    program: usize,
    here: PathBuf,
}

impl Step {
    fn program(&self) -> &str {
        self.words.get(self.program).map_or("", |w| program_name(w))
    }

    fn args(&self) -> &[String] {
        self.words.get(self.program + 1..).unwrap_or(&[])
    }

    fn assignments(&self) -> &[String] {
        &self.words[..self.program.min(self.words.len())]
    }

    /// The arguments without the text of a message (`git commit -m "..."`).
    fn args_without_messages(&self) -> Vec<&String> {
        let message = matches!(self.program(), "git" | "gh");
        let mut out = vec![];
        let mut skip = false;
        for a in self.args() {
            if skip {
                skip = false;
            } else if message && MESSAGE_OPTIONS.contains(&a.as_str()) {
                skip = true;
            } else {
                out.push(a);
            }
        }
        out
    }
}

/// The words of a command as the shell splits them: what is quoted is one
/// word, with its quotes taken off. `-m "fix /w/x"` is two words, not three.
fn shell_words(seg: &str) -> Vec<String> {
    let (mut out, mut cur, mut quote, mut any) = (vec![], String::new(), None::<char>, false);
    let mut chars = seg.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (None, '\\') => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                    any = true;
                }
            }
            (None, '"' | '\'') => {
                quote = Some(c);
                any = true;
            }
            (Some(q), _) if c == q => quote = None,
            (None, c) if c.is_whitespace() => {
                if any {
                    out.push(std::mem::take(&mut cur));
                    any = false;
                }
            }
            (None, '(' | ')' | '`') => {}
            _ => {
                cur.push(c);
                any = true;
            }
        }
    }
    if any {
        out.push(cur);
    }
    out
}

/// The line another shell runs: `bash -c`, `bash -lc`, `zsh -ic`, `eval`.
fn inner_line(step: &Step) -> Option<String> {
    let args = step.args();
    match step.program() {
        "eval" => Some(args.join(" ")),
        "bash" | "sh" | "zsh" | "dash" | "ksh" => {
            let i = args.iter().position(|a| a.starts_with('-') && !a.starts_with("--") && a.contains('c'))?;
            args.get(i + 1).cloned()
        }
        _ => None,
    }
}

fn steps(command: &str, start: &Path) -> Vec<Step> {
    // `&>`, `&>>`, `>&f` and `>|` write, and their `&` or `|` must not cut the
    // line in two. `2>&1` and `>&-` only point a stream elsewhere.
    let text = drop_heredocs(command);
    let text = crate::regex!(r"&>>").replace_all(&text, " >> ");
    let text = crate::regex!(r"&>|>\|").replace_all(&text, " > ");
    let text = crate::regex!(r">&([^\d\-\s])").replace_all(&text, " > $1").into_owned();
    let mut here = start.to_path_buf();
    let mut out = vec![];
    for seg in segments(&text) {
        let words = shell_words(&seg);
        let (mut program, mut wrapped) = (0, false);
        while let Some(w) = words.get(program) {
            let wrapper =
                matches!(program_name(w), "env" | "sudo" | "command" | "exec" | "nice" | "nohup" | "time" | "doas");
            let assignment = w.contains('=') && !w.starts_with('-') && !w.starts_with('/');
            let wrapper_option = wrapped && w.starts_with('-');
            if !(wrapper || assignment || wrapper_option) {
                break;
            }
            if wrapper_option && WRAPPER_OPTIONS_WITH_VALUE.contains(&w.as_str()) {
                program += 1;
            }
            wrapped |= wrapper;
            program += 1;
        }
        let step = Step { words, program, here: here.clone() };
        if let Some(inner) = inner_line(&step) {
            out.extend(steps(&inner, &here));
        }
        if matches!(step.program(), "cd" | "pushd" | "popd") {
            let target = step.args().iter().find(|a| !a.starts_with('-') || a.as_str() == "-");
            here = match (step.program(), target.map(String::as_str)) {
                ("cd", None) | (_, Some("~")) => env::home(),
                // `cd -`, `popd` and a folder named through a variable go
                // where the guard cannot follow: what comes after is read
                // from nowhere it can place, and stopped if it names a path.
                ("popd", _) | (_, Some("-")) => unknown_folder(),
                (_, Some(d)) if d.contains('$') || d.contains('`') => unknown_folder(),
                (_, Some(d)) => resolve(&step.here, d),
                (_, None) => here,
            };
        }
        out.push(step);
    }
    out
}

/// Where a line stands after a `cd` the guard cannot follow.
fn unknown_folder() -> PathBuf {
    PathBuf::from("/.crux-unknown-folder")
}

fn looks_like_path(w: &str) -> bool {
    w.starts_with('/')
        || w.starts_with('~')
        || w.starts_with("$HOME")
        || w.starts_with("${HOME}")
        || w.starts_with('.')
        || (w.contains('/') && !w.contains("://") && !w.starts_with('-'))
}

/// A path a call touches: whether it may write it, and whether it is read as
/// a whole tree.
struct Touch {
    path: PathBuf,
    writes: bool,
    tree: bool,
    /// Removed or moved away: what the folder holds goes with it.
    wholesale: bool,
}

/// Whether a step reads a tree. `grep`, `cp` and `ls` only when recursive.
fn reads_a_tree(step: &Step) -> bool {
    let p = step.program();
    let flag = |c: char| step.args().iter().any(|a| a.starts_with('-') && !a.starts_with("--") && a.contains(c));
    let long = step.args().iter().any(|a| a == "--recursive");
    match p {
        "grep" | "egrep" => flag('r') || flag('R') || long,
        "cp" => flag('r') || flag('R') || flag('a') || long,
        "ls" => flag('R'),
        _ => RECURSIVE.contains(&p),
    }
}

/// Every path a step touches. The folder it runs in counts, and is read whole
/// by a tree reader that names no path (`grep -r x` reads where it stands). A
/// redirection writes (`> f`, `2>f`, `&>> f`); a shell glob is a tree read of
/// its fixed part; an assignment before the program can name a path too.
fn step_paths(step: &Step) -> Vec<Touch> {
    let program = step.program();
    let tree = reads_a_tree(step);
    let in_place = matches!(program, "sed" | "perl") && step.args().iter().any(|a| a.starts_with("-i"));
    let args = step.args_without_messages();
    let redirect = crate::regex!(r"^\d*&?(>>?|<)");
    let last_path = args.iter().rposition(|w| looks_like_path(&redirect.replace(w, "")));
    let mut out = vec![];
    let mut pending_redirect = None::<bool>;
    let words = step.assignments().iter().map(|w| (w, None)).chain(args.iter().enumerate().map(|(i, w)| (*w, Some(i))));
    for (w, index) in words {
        let op = redirect.find(w).map(|m| m.as_str().to_string());
        let rest = redirect.replace(w, "").into_owned();
        if op.is_some() && rest.is_empty() {
            pending_redirect = op.map(|o| o.contains('>'));
            continue;
        }
        let w = rest.rsplit_once('=').map_or(rest.as_str(), |(_, v)| v);
        // A bare name is a path when it is there: `tar czf o.tgz Lumyna`.
        let existing = !w.is_empty() && !w.starts_with('-') && step.here.join(w).exists();
        if !looks_like_path(w) && !existing {
            pending_redirect = None;
            continue;
        }
        let redirected = op.map(|o| o.contains('>')).or(pending_redirect.take());
        let glob = w.find(['*', '?', '[', '{']);
        let fixed = match glob {
            Some(at) => w[..at].rsplit_once('/').map_or("", |(d, _)| d),
            None => w,
        };
        let writes = index.is_some()
            && (redirected == Some(true)
                || in_place
                || WRITERS.contains(&program)
                || (COPIERS.contains(&program) && index == last_path));
        out.push(Touch {
            path: resolve(
                &step.here,
                if fixed.is_empty() && !w.starts_with('/') {
                    "."
                } else if fixed.is_empty() {
                    "/"
                } else {
                    fixed
                },
            ),
            writes,
            tree: tree || glob.is_some(),
            wholesale: index.is_some() && matches!(program, "rm" | "rmdir" | "mv"),
        });
    }
    out.extend(special_touches(step));
    let named = !out.is_empty();
    out.push(Touch { path: step.here.clone(), writes: false, tree: tree && !named, wholesale: false });
    out
}

/// The paths a step touches through its program rather than its arguments:
/// where `cd` goes, a program run by its path (`~/x/repo/script.sh`), and the
/// target of `ln -s`, read from the link's folder and read whole by whoever
/// follows the link.
fn special_touches(step: &Step) -> Vec<Touch> {
    let program = step.program();
    let mut out = vec![];
    if program == "cd" {
        if let Some(d) = step.args().first() {
            out.push(Touch { path: resolve(&step.here, d), writes: false, tree: false, wholesale: false });
        }
    }
    if let Some(w) = step.words.get(step.program).filter(|w| w.contains('/')) {
        out.push(Touch { path: resolve(&step.here, w), writes: false, tree: false, wholesale: false });
    }
    if program == "ln" && step.args().iter().any(|a| a.starts_with('-') && a.contains('s')) {
        let paths: Vec<&String> = step.args().iter().filter(|a| !a.starts_with('-')).collect();
        if let [target, link, ..] = paths.as_slice() {
            let base = resolve(&step.here, link).parent().map(Path::to_path_buf).unwrap_or_else(|| step.here.clone());
            out.push(Touch { path: resolve(&base, target), writes: false, tree: true, wholesale: false });
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
        .map(|p| resolve(start, &p))
        .collect()
}

/// The paths a non-shell tool touches: its path fields, the fixed part of a
/// Glob pattern, and for a search with no path, the folder it runs in.
fn tool_touches(tool: &str, params: &Value, start: &Path) -> Vec<Touch> {
    let writes = matches!(tool, "Write" | "Edit" | "MultiEdit" | "NotebookEdit" | "apply_patch");
    let tree = matches!(tool, "Grep" | "Glob" | "LS");
    let mut paths: Vec<PathBuf> = if tool == "apply_patch" {
        // Codex may hand the command as an array: its words are the patch.
        let body = ["patch", "input", "command"]
            .iter()
            .map(|k| match params.get(*k) {
                Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n"),
                _ => field(params, k),
            })
            .find(|v| !v.is_empty());
        patch_paths(&body.unwrap_or_default(), start)
    } else {
        let pattern = field(params, "pattern");
        let fixed = pattern.split(['*', '?', '[', '{']).next().unwrap_or("").to_string();
        let pattern_path = (fixed.starts_with('/') || fixed.starts_with('~')).then_some(fixed);
        ["file_path", "notebook_path", "path"]
            .iter()
            .map(|k| field(params, k))
            .chain(pattern_path)
            .filter(|p| !p.is_empty())
            .map(|p| resolve(start, &p))
            .collect()
    };
    if paths.is_empty() && tree {
        paths.push(start.to_path_buf());
    }
    paths.into_iter().map(|path| Touch { path, writes, tree, wholesale: false }).collect()
}

// --- Places -----------------------------------------------------------------

/// What a path belongs to, for the wall: a place, or the agents' session
/// stores, which hold every scope's conversations at once.
#[derive(Clone)]
enum Zone {
    Place(Place),
    Sessions,
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

fn describe_zone(z: &Zone) -> String {
    match z {
        Zone::Place(p) => describe(p),
        Zone::Sessions => "other sessions' conversations".into(),
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

/// Folder names in Claude's transcripts are paths with every character that
/// is not a letter or a digit turned into `-`.
fn encoded(p: &Path) -> String {
    p.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// Where a path inside a session store belongs. A folder of Claude's named
/// after a root (or a project in it) is that scope's; the longest name wins,
/// since `acme-old` and `acme/old` read the same. A file of a front-desk
/// folder is the scope its session was pinned to; any other store, the store
/// as a whole, or anything it cannot place holds conversations of any scope.
/// The session's own files are its own.
fn session_zone(all: &Scopes, path: &Path, own_session: &str, start: &Path) -> Option<Option<Zone>> {
    let real = scope::real_lenient(path);
    let claude = scope::real_lenient(&env::claude_transcripts_dir());
    let (store, rel) = scope::session_stores().into_iter().find_map(|s| {
        let s = scope::real_lenient(&s);
        real.strip_prefix(&s).ok().map(|r| (s.clone(), r.to_path_buf()))
    })?;
    let parts: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    if !own_session.is_empty() && parts.iter().any(|p| p.trim_end_matches(".jsonl") == own_session) {
        return Some(None);
    }
    if store != claude {
        return Some(Some(Zone::Sessions));
    }
    let Some(folder) = parts.first().map(|f| encoded(Path::new(f))) else { return Some(Some(Zone::Sessions)) };
    if folder == encoded(&scope::real_lenient(start)) || folder == encoded(start) {
        return Some(None);
    }
    let matches = |e: &str| folder == e || folder.starts_with(&format!("{e}-"));
    let best = all.list.iter().filter(|s| matches(&encoded(&s.real_root))).max_by_key(|s| encoded(&s.real_root).len());
    if let Some(s) = best {
        let project =
            scope::projects(s).into_iter().filter(|p| matches(&encoded(&s.real_root.join(p)))).max_by_key(String::len);
        return Some(Some(Zone::Place(isolated_place(all, &Place { scope: s.name.clone(), project }))));
    }
    let session = parts.get(1).map(|f| f.trim_end_matches(".jsonl").to_string()).unwrap_or_default();
    Some(Some(match scope::pinned(&session) {
        Some(p) => Zone::Place(Place::parse(&p)),
        None => Zone::Sessions,
    }))
}

/// Where a path falls in the person's profile: `Some(true)` for a shared note,
/// `Some(false)` for anything else in it (private notes, the full index,
/// folders, git's objects), `None` outside it.
fn profile_part(profile: Option<&Path>, path: &Path) -> Option<bool> {
    let dir = profile?;
    let real = scope::real_lenient(path);
    let rel = real.strip_prefix(scope::real_lenient(dir)).ok()?.to_string_lossy().into_owned();
    Some(rel.ends_with(".md") && !rel.eq_ignore_ascii_case("PROFILE.md") && person::is_shared(dir, &rel))
}

/// What holds the wall up: the scopes and the pins, crux itself (the guard is
/// its binary), the agents' settings where the hooks and the sandbox are
/// written, and the git and ssh configs `apply` writes. A session writes none
/// of them, nor a folder that holds one (`rm -rf ~/.crux`).
fn wall_paths() -> Vec<PathBuf> {
    let mut out = vec![scope::dir(), scope::pins_dir(), env::crux_dir()];
    out.extend(env::crux_home());
    out.push(env::claude_settings());
    out.push(env::claude_config_dir().join("settings.local.json"));
    out.push(env::codex_home_dir().join("hooks.json"));
    out.push(env::home().join(".gitconfig"));
    out.push(env::home().join(".ssh/config"));
    out.push(env::home().join(".claude.json"));
    out.push(env::codex_home_dir().join("config.toml"));
    // What a shell reads when it starts: an `export` there moves the wall
    // for every session after.
    for rc in [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"] {
        out.push(env::home().join(rc));
    }
    out.into_iter().map(|p| scope::real_lenient(&p)).collect()
}

fn writes_the_wall(path: &Path) -> Option<String> {
    let real = scope::real_lenient(path);
    let hit = real.ends_with(crate::names::CLAUDE_LOCAL_SETTINGS)
        || wall_paths().iter().any(|w| scope::inside(&real, w) || scope::inside(w, &real));
    hit.then(|| {
        format!(
            "'{}' holds up the scope wall (scopes, pins, crux, the agents' settings): a session does not write it. \
             Changes to scopes go through `crux scope`, run by the person.",
            real.display()
        )
    })
}

// --- The checks -------------------------------------------------------------

/// What a session is checked against, loaded once per call.
struct Wall<'a> {
    all: &'a Scopes,
    pinned: Option<Place>,
    profile: Option<PathBuf>,
    session: &'a str,
    /// The folder the session started in: its transcript folder, and its
    /// automatic memory in it, are named after it.
    start: PathBuf,
}

impl Wall<'_> {
    fn person(&self) -> Person {
        self.pinned.as_ref().map_or(Person::Shared, |p| self.all.person_at(p))
    }

    /// The folders this session must not read whole: other scopes' roots and
    /// secrets, inside its own scope the projects its isolation leaves out,
    /// the profile where only its shared part applies, and the session stores
    /// when they can hold anything this session may not see.
    fn foreign(&self) -> Vec<(PathBuf, Zone)> {
        let mut out = vec![];
        for s in &self.all.list {
            let Some(pin) = self.pinned.as_ref().filter(|p| p.scope == s.name) else {
                let zone = Zone::Place(Place { scope: s.name.clone(), project: None });
                out.push((s.real_root.clone(), zone.clone()));
                out.extend(s.secret_paths().iter().map(|p| (scope::real_lenient(p), zone.clone())));
                out.extend(s.dir.iter().map(|d| (scope::real_lenient(d), zone.clone())));
                out.push((scope::real_lenient(&s.tasks_dir()), zone.clone()));
                out.push((
                    scope::real_lenient(&env::state_dir().join(format!("sync-report-{}", s.name))),
                    zone.clone(),
                ));
                continue;
            };
            for p in scope::projects(s) {
                let closed = match &pin.project {
                    Some(own) => own != &p,
                    None => scope::project_rules(s, &p).isolated,
                };
                if closed {
                    out.push((s.real_root.join(&p), Zone::Place(Place { scope: s.name.clone(), project: Some(p) })));
                }
            }
        }
        if self.person() != Person::Full {
            if let Some(d) = &self.profile {
                let owner = Place { scope: self.all.primary().name.clone(), project: None };
                out.push((scope::real_lenient(d), Zone::Place(owner)));
            }
        }
        if !out.is_empty() {
            out.extend(scope::session_stores().iter().map(|s| (scope::real_lenient(s), Zone::Sessions)));
        }
        out
    }

    fn holds_foreign(&self, foreign: &[(PathBuf, Zone)], path: &Path) -> Option<String> {
        let real = scope::real_lenient(path);
        let (f, zone) = foreign.iter().find(|(f, _)| scope::inside(f, &real) && *f != real)?;
        Some(format!(
            "'{}' holds {} ({}): reading it whole reads that too. Name a folder of this scope instead.",
            real.display(),
            describe_zone(zone),
            f.display()
        ))
    }

    fn profile_crossing(&self, path: &Path, shared: bool, writes: bool) -> Option<String> {
        let primary = self.pinned.as_ref().is_none_or(|p| p.scope == self.all.primary().name);
        if writes && !primary {
            return Some(format!(
                "'{}' is the person's profile, which travels under their own account: it is not written from \
                 scope '{}'. Tell the person what to note instead.",
                path.display(),
                self.pinned.as_ref().map_or("", |p| p.scope.as_str())
            ));
        }
        // The person's own sessions (the front desk, the primary scope) note
        // things in the profile and commit them; writing reads nothing private.
        if writes {
            return None;
        }
        let person = self.person();
        if person == Person::Full || (shared && person == Person::Shared) {
            return None;
        }
        Some(match &self.pinned {
            None => format!(
                "'{}' is private to the person's profile. Enter the person's own scope first: `crux scope enter {}`.",
                path.display(),
                self.all.primary().name
            ),
            Some(_) => format!(
                "'{}' is private to the person's profile, and this session only sees its shared part. \
                 If something should be noted there, tell the person instead of writing it.",
                path.display()
            ),
        })
    }

    fn crossing(&self, touch: &Touch) -> Option<String> {
        if touch.path.starts_with(unknown_folder()) && touch.path != unknown_folder() {
            return Some(
                "this line moves to a folder the guard cannot follow (`cd -`, `popd`, a variable) and then names \
                 a path from it: write that folder out instead."
                    .into(),
            );
        }
        let real = scope::real_lenient(&touch.path);
        let path = real.as_path();
        if touch.writes {
            if let Some(why) = writes_the_wall(path) {
                return Some(why);
            }
        }
        if let Some(shared) = profile_part(self.profile.as_deref(), path) {
            // Standing in a folder of the profile (`git commit` in it) reads
            // no note; reading it whole is stopped as a tree read.
            if path.is_dir() && !touch.tree {
                return None;
            }
            return self.profile_crossing(path, shared, touch.writes);
        }
        let zone = match session_zone(self.all, path, self.session, &self.start) {
            Some(None) => return None,
            Some(Some(z)) => z,
            None => Zone::Place(self.all.place_of(path)?),
        };
        match zone {
            Zone::Sessions => Some(format!("'{}' holds other sessions' conversations.", path.display())),
            Zone::Place(place) => self.place_crossing(path, &place),
        }
    }

    /// Whether a path of a place is closed to this session: another scope,
    /// another isolated project, or any scope while at the front desk.
    fn place_crossing(&self, path: &Path, place: &Place) -> Option<String> {
        let Some(pin) = &self.pinned else {
            let rules_place = isolated_place(self.all, place);
            return Some(format!(
                "'{}' belongs to {}. This session is at the front desk: enter it first with `{}`. \
                 That pins the session there for good and gives it that context.",
                path.display(),
                describe(&rules_place),
                enter_hint(&rules_place)
            ));
        };
        if place.scope != pin.scope {
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
                let s = self.all.by_name(&place.scope)?;
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

    /// Network reach: one account can read every scope's repos, which no
    /// filesystem rule sees. Messages are left out: citing a repo in a commit
    /// message reaches nothing.
    fn other_owner(&self, steps: &[Step]) -> Option<String> {
        for s in self.all.list.iter().filter(|s| self.pinned.as_ref().is_none_or(|p| p.scope != s.name)) {
            for o in &s.owners {
                let lo = o.to_lowercase();
                let web = regex::Regex::new(&format!(
                    r"(?i)(github\.com[:/]{0}/|api\.github\.com/(repos|orgs|users)/{0}(/|$))",
                    regex::escape(o)
                ))
                .ok()?;
                let by_gh = |a: &str| {
                    a.starts_with(&format!("{lo}/"))
                        || a.contains(&format!("={lo}/"))
                        || ["repos/", "orgs/", "users/"].iter().any(|k| {
                            let at = format!("{k}{lo}");
                            a.ends_with(&at) || a.contains(&format!("{at}/"))
                        })
                };
                // A bare owner counts where gh takes one: `-R`, `--owner`,
                // `repo list`, `org`. `--label acme` is not a repo.
                let hit = steps.iter().any(|st| {
                    let gh = st.program() == "gh";
                    let args = st.args_without_messages();
                    args.iter().enumerate().any(|(i, a)| {
                        let a = a.to_lowercase();
                        let before = i.checked_sub(1).and_then(|j| args.get(j)).map(|b| b.as_str());
                        let takes_owner = matches!(before, Some("-R" | "--repo" | "--owner" | "list" | "org"));
                        web.is_match(&a) || (gh && (by_gh(&a) || (takes_owner && a == lo)))
                    })
                });
                if hit {
                    return Some(format!(
                        "this reaches '{o}', an owner of scope '{}'. {}",
                        s.name,
                        match &self.pinned {
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
}

/// What a `crux` command of the line asks of the wall.
enum CruxStep {
    Refused(String),
    FolderBound,
    Free,
}

fn crux_step(wall: &Wall, step: &Step) -> CruxStep {
    let args = step.args();
    let sub = args.first().map(String::as_str).unwrap_or("");
    if matches!(sub, "task" | "workspace") && args.iter().any(|a| a == "--all") {
        return CruxStep::Refused(
            "the list of every scope is for the person, not for a session. Ask them to run it.".into(),
        );
    }
    // These read every project and the whole profile: only where the
    // session sees all of it, the person's own scope with no isolation.
    let sees_everything =
        wall.pinned.as_ref().is_some_and(|p| p.project.is_none() && wall.all.person_at(p) == Person::Full);
    if matches!(sub, "memory" | "sync" | "status" | "usage" | "machine") && !sees_everything {
        return CruxStep::Refused(format!(
            "`crux {sub}` reads every project and the person's whole profile: run it from a session of the \
             person's own scope, or ask the person."
        ));
    }
    if sub != "scope" {
        return if matches!(sub, "" | "prose" | "help" | "version" | "--version" | "-v" | "hook" | "__fn") {
            CruxStep::Free
        } else {
            CruxStep::FolderBound
        };
    }
    let rest = args.get(2..).unwrap_or(&[]);
    match args.get(1).map(String::as_str).unwrap_or("") {
        verb @ ("move" | "apply") => CruxStep::Refused(format!(
            "`crux scope {verb}` changes the scopes on this machine: the person runs it themselves."
        )),
        "show" => match (&wall.pinned, rest.first()) {
            (Some(p), Some(n)) if *n != p.scope => {
                CruxStep::Refused(format!("scope '{n}' is not this session's: what it declares is not read from here."))
            }
            _ => CruxStep::Free,
        },
        "map" if wall.pinned.as_ref().is_some_and(|p| p.project.is_some()) => {
            CruxStep::Refused("an isolated project's session does not read the other projects' names.".into())
        }
        _ => CruxStep::Free,
    }
}

/// Every `scope enter <target>` a line runs, behind whatever wrapper: the
/// words in sequence in any of its commands, nested shells included. A
/// sentence that only mentions it is one quoted word and does not count.
fn named_entries(all: &Scopes, steps: &[Step]) -> Vec<Result<Place, String>> {
    let mut out = vec![];
    for st in steps {
        for (i, w) in st.words.iter().enumerate() {
            if w != "scope" || st.words.get(i + 1).map(String::as_str) != Some("enter") {
                continue;
            }
            let rest = st.words.get(i + 2..).unwrap_or(&[]);
            let (project, name) = match rest.first().map(String::as_str) {
                Some("--project") => (true, rest.get(1)),
                _ => (false, rest.first()),
            };
            let Some(name) = name.cloned() else { continue };
            out.push(if project {
                all.scope_of_project(&name)
                    .map(|s| isolated_place(all, &Place { scope: s.name.clone(), project: Some(name) }))
            } else if all.by_name(&name).is_some() {
                Ok(Place { scope: name, project: None })
            } else {
                Err(format!("no scope '{name}'"))
            });
        }
    }
    out
}

/// The shell line, command by command: what it asks of the wall and every
/// path it touches. Returns the place it enters, if it enters one.
/// Where an assignment takes effect: before the program (`X=1 cmd`,
/// `env "X=1" cmd`) or as what export and its kin set. A commit message that
/// mentions one sets nothing.
fn check_assignments(steps: &[Step]) -> Result<(), String> {
    for st in steps {
        let setters = matches!(st.program(), "export" | "unset" | "declare" | "typeset" | "local" | "readonly");
        let words: &[String] = if setters { &st.words } else { st.assignments() };
        if let Some(v) =
            VARS_THAT_MOVE_THE_WALL.iter().find(|v| words.iter().any(|w| w == *v || w.starts_with(&format!("{v}="))))
        {
            return Err(format!("{v} decides which scope a command works in; a session does not set it."));
        }
    }
    Ok(())
}

/// The one place a line enters, if any: none other than the session's own.
fn check_entries(wall: &Wall, steps: &[Step]) -> Result<Option<Place>, String> {
    let mut enters = None;
    for r in named_entries(wall.all, steps) {
        let place = r?;
        match (&wall.pinned, &enters) {
            (Some(p), _) if *p != place => {
                return Err(format!(
                    "this session is in {}, and this line enters {}. Tell the person: `{}`.",
                    describe(p),
                    describe(&place),
                    open_hint(&place)
                ))
            }
            (None, Some(e)) if *e != place => return Err("one line enters one scope at most.".into()),
            _ => enters = Some(place),
        }
    }
    Ok(enters)
}

/// A crux command of the line: refused, or bound to the folder it runs from.
fn check_crux(wall: &Wall, st: &Step, scope_of_line: Option<&scope::Scope>) -> Result<(), String> {
    match (crux_step(wall, st), scope_of_line) {
        (CruxStep::Refused(why), _) => Err(why),
        (CruxStep::FolderBound, None) => Err(format!(
            "this session is at the front desk, and `crux {}` works in a scope: enter one first.",
            st.args().first().map_or("", String::as_str)
        )),
        (CruxStep::FolderBound, Some(s)) if wall.all.of_path(&st.here).is_none_or(|x| x.name != s.name) => {
            Err(format!(
                "crux works in the scope of the folder it runs from, and {} is outside scope '{}'. \
                 Run it from inside: `cd {} && {}`.",
                st.here.display(),
                s.name,
                s.root.display(),
                st.words.join(" ")
            ))
        }
        _ => Ok(()),
    }
}

/// The shell line, command by command: what it asks of the wall and every
/// path it touches. Returns the place it enters, if it enters one.
fn check_bash(wall: &Wall, command: &str, start: &Path, touches: &mut Vec<Touch>) -> Result<Option<Place>, String> {
    let steps = steps(command, start);
    check_assignments(&steps)?;
    if let Some(why) = wall.other_owner(&steps) {
        return Err(why);
    }
    let enters = check_entries(wall, &steps)?;
    let scope_of_line = enters.as_ref().or(wall.pinned.as_ref()).and_then(|p| wall.all.by_name(&p.scope));
    for st in &steps {
        if st.program() == "crux" {
            check_crux(wall, st, scope_of_line)?;
        }
        touches.extend(step_paths(st));
    }
    touches.extend(named_in_text(wall, command, &steps));
    Ok(enters)
}

/// The net under the shell reader, which can never be complete: every
/// foreign folder the raw line names, however it reaches a program (a pipe
/// into `sh`, `xargs`, a heredoc, `$(...)`), written as declared, resolved,
/// or through `~` and `$HOME`. Messages of git and gh are left out: citing a
/// path in a commit message reaches nothing.
fn named_in_text(wall: &Wall, command: &str, steps: &[Step]) -> Vec<Touch> {
    // Heredoc bodies only count when a shell reads them; quotes inside a
    // path (`"$HOME"/x`) and `/./` are spelled away; macOS folds case.
    let mut text = drop_heredocs(command).replace(['"', '\''], "").replace("/./", "/");
    for st in steps {
        let message = matches!(st.program(), "git" | "gh");
        for pair in st.args().windows(2) {
            if message && MESSAGE_OPTIONS.contains(&pair[0].as_str()) {
                text = text.replace(pair[1].as_str(), " ");
            }
        }
    }
    if cfg!(target_os = "macos") {
        text = text.to_lowercase();
    }
    let tree_reader = steps.iter().any(reads_a_tree);
    let home = env::home().to_string_lossy().into_owned();
    let spellings = |p: &Path| -> Vec<String> {
        let s = p.to_string_lossy().into_owned();
        let mut out = vec![s.clone()];
        if let Some(rest) = s.strip_prefix(&home) {
            out.extend(["~", "$HOME", "${HOME}"].iter().map(|h| format!("{h}{rest}")));
        }
        out
    };
    // A line that writes anywhere may write what it names.
    let writes =
        text.contains('>') || steps.iter().any(|st| WRITERS.contains(&st.program()) || COPIERS.contains(&st.program()));
    let end = |c: char| c.is_whitespace() || "'\";)|&`<>".contains(c);
    let mut out = vec![];
    let mut zones: Vec<PathBuf> = wall.foreign().into_iter().map(|(f, _)| f).collect();
    zones.extend(wall_paths());
    for folder in zones {
        let mut candidates = spellings(&folder);
        if let Some(s) = wall.all.list.iter().find(|s| s.real_root == folder) {
            candidates.extend(spellings(&s.root));
        }
        for c in &candidates {
            let c = if cfg!(target_os = "macos") { c.to_lowercase() } else { c.clone() };
            for (i, _) in text.match_indices(c.as_str()) {
                let after = &text[i + c.len()..];
                if !after.chars().next().is_none_or(|n| n == '/' || end(n)) {
                    continue;
                }
                // The whole path as written, so that a shared note inside
                // another root is judged as itself, not as the root.
                let tail: String = after.chars().take_while(|ch| !end(*ch)).collect();
                let named = format!("{}{tail}", folder.display());
                out.push(Touch {
                    path: PathBuf::from(named),
                    writes,
                    tree: tree_reader && tail.trim_matches('/').is_empty(),
                    wholesale: false,
                });
            }
        }
    }
    out
}

/// Where a session stands, and whether that still has to be pinned. One that
/// opened inside a root without going through session start is in that
/// root's place; with one scope, every session is in it.
fn session_place(all: &Scopes, session: &str, start: &Path) -> (Option<Place>, bool) {
    match scope::pinned(session) {
        Some(p) => (Some(Place::parse(&p)), false),
        None => match all.pin_place(start) {
            Some(place) => (Some(place), true),
            None if all.list.len() == 1 => (Some(Place { scope: all.list[0].name.clone(), project: None }), true),
            None => (None, false),
        },
    }
}

fn stop_with(reason: &str) -> Res {
    stop(&format!("Stopped by the scope wall (ADR-025): {reason}\n"))
}

pub(super) fn scope_guard() -> Res {
    let event = input();
    let session = session_or_parent(&event);
    let all = match scope::load() {
        Ok(a) if a.declared => a,
        // A pinned session whose scopes are gone has lost its wall, not
        // gained a free machine.
        Ok(_) if scope::pinned(&session).is_some() => {
            return stop_with("this session is pinned to a scope, and the scopes are gone. The person restores them.")
        }
        Ok(_) => return Ok(()),
        Err(e) => return stop_with(&format!("the scopes cannot be read, so nothing runs until they are fixed: {e}")),
    };
    let tool = field(&event, "tool_name");
    let params = event.get("tool_input").cloned().unwrap_or(Value::Null);
    let start = match field(&event, "cwd") {
        c if c.is_empty() => cwd(),
        c => PathBuf::from(c),
    };
    let (pinned, pin_now) = session_place(&all, &session, &start);
    let mut wall = Wall { all: &all, pinned, profile: person::dir(), session: &session, start: start.clone() };

    if let Some(rest) = tool.strip_prefix("mcp__") {
        if let Some(s) = wall.pinned.as_ref().and_then(|p| all.by_name(&p.scope)) {
            if s.mcp_deny.iter().any(|pat| crate::files::glob_match(pat, &tool)) {
                return stop_with(&format!(
                    "the connector '{rest}' is not used in scope '{}'. Tell the person; it belongs to another scope.",
                    s.name
                ));
            }
        }
    }

    let mut touches = vec![];
    let mut enters = None;
    if matches!(tool.as_str(), "Bash" | "Monitor") {
        match check_bash(&wall, &field(&params, "command"), &start, &mut touches) {
            Ok(e) => enters = e,
            Err(why) => return stop_with(&why),
        }
        // What the line runs after `crux scope enter` already stands inside
        // the scope it enters.
        if wall.pinned.is_none() {
            wall.pinned.clone_from(&enters);
        }
    } else {
        touches = tool_touches(&tool, &params, &start);
    }

    for t in touches.iter().filter(|t| t.writes) {
        if let Some(why) = writes_the_wall(&t.path) {
            return stop_with(&why);
        }
    }
    let foreign = wall.foreign();
    for t in touches.iter().filter(|t| t.tree || t.wholesale) {
        if let Some(why) = wall.holds_foreign(&foreign, &t.path) {
            return stop_with(&why);
        }
    }
    for t in &touches {
        if let Some(why) = wall.crossing(t) {
            return stop_with(&why);
        }
    }
    // Pinned only once the whole call has passed: a call stopped, or refused
    // by the person, leaves the session where it was.
    if let Some(place) = enters.as_ref().or(wall.pinned.as_ref().filter(|_| pin_now)) {
        if let Err(e) = scope::pin(&session, &place.as_pin()) {
            return stop_with(&format!("{e}. Tell the person: `{}`.", open_hint(place)));
        }
    }
    if scope::pinned(&session).is_some() {
        scope::refresh_pin(&session);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(cmd: &str, start: &str) -> Vec<PathBuf> {
        steps(cmd, Path::new(start)).iter().flat_map(step_paths).map(|t| t.path).collect()
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
    fn the_program_is_found_past_wrappers_paths_and_values() {
        let s = steps(
            r#"env "CRUX_SCOPE=x" /opt/bin/crux scope enter acme; sudo -E grep -r a /w; /usr/bin/env crux scope; nice -n 10 crux x"#,
            Path::new("/"),
        );
        let programs: Vec<&str> = s.iter().map(Step::program).collect();
        assert_eq!(programs, vec!["crux", "grep", "crux", "crux"], "{programs:?}");
        assert!(reads_a_tree(&s[1]));
    }

    #[test]
    fn other_shells_are_read_as_lines() {
        let s = steps("bash -lc 'cat /w/b/x'; zsh -ic \"crux scope enter y\"; eval cat /w/c", Path::new("/"));
        let p: Vec<PathBuf> = s.iter().flat_map(step_paths).map(|t| t.path).collect();
        assert!(p.contains(&PathBuf::from("/w/b/x")) && p.contains(&PathBuf::from("/w/c")), "{p:?}");
        assert!(s.iter().any(|st| st.program() == "crux"));
    }

    #[test]
    fn only_recursive_reads_are_tree_reads() {
        let s = steps("grep a f; cp a b; cp -r a b; ls -la; ls -R x", Path::new("/"));
        assert_eq!(s.iter().map(reads_a_tree).collect::<Vec<_>>(), vec![false, false, true, false, true]);
    }

    #[test]
    fn messages_are_not_paths_and_only_writers_write() {
        let s = steps(
            r#"git commit -m "/w/acme/x"; cat /w/a; cp /w/a /w/b; echo x > /w/c; echo y 2>/w/d; F=/w/e cat"#,
            Path::new("/w"),
        );
        let t: Vec<(String, bool)> = s
            .iter()
            .flat_map(step_paths)
            .filter(|t| t.path != Path::new("/w"))
            .map(|t| (t.path.display().to_string(), t.writes))
            .collect();
        assert!(!t.iter().any(|(p, _)| p.contains("acme")), "{t:?}");
        assert!(t.contains(&("/w/a".into(), false)) && t.contains(&("/w/b".into(), true)), "{t:?}");
        assert!(t.contains(&("/w/c".into(), true)) && t.contains(&("/w/d".into(), true)), "{t:?}");
        assert!(t.iter().any(|(p, _)| p == "/w/e"), "an assignment names a path: {t:?}");
    }

    #[test]
    fn the_folder_is_a_tree_read_only_when_no_path_is_named() {
        let named = steps("rg foo /w/a/src", Path::new("/home"));
        assert!(!step_paths(&named[0]).iter().any(|t| t.tree && t.path == Path::new("/home")));
        let bare = steps("rg foo", Path::new("/home"));
        assert!(step_paths(&bare[0]).iter().any(|t| t.tree && t.path == Path::new("/home")));
    }

    #[test]
    fn a_patch_names_its_files() {
        let p = patch_paths("*** Begin Patch\n*** Update File: src/a.rs\n*** Add File: /w/b.rs\n", Path::new("/w/r"));
        assert_eq!(p, vec![PathBuf::from("/w/r/src/a.rs"), PathBuf::from("/w/b.rs")]);
    }
}
