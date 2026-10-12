//! crux memory — what the agent knows that the project does not know yet.
//!
//!   crux memory           the memories by type, and the ones missing from git
//!   crux memory --brief   one line with what is missing, to hook into a hook
//!   crux memory --check   silent; exits 1 if any should have been promoted
//!   crux memory search <t> looks for the text in the profile and every docs repo
//!
//! `project` and `reference` belong to the project and go to git; `user` and
//! `feedback` belong to the person and go to their profile. It does not decide
//! where each memory goes nor move it: that is a decision, and decisions are
//! not made by a hook.

use crate::error::{exit, Res};
use crate::{die, env, person, project, ui};
use std::path::{Path, PathBuf};

/// One memory as the agent stores it: its declared type (`?` if none, `!` if
/// it cannot be read), its scope as the agent names it, and its path.
pub struct Memory {
    pub kind: String,
    pub scope: String,
    pub path: PathBuf,
}

/// Claude Code's memories: ~/.claude/projects/<scope>/memory/*.md, the type in
/// the frontmatter. The scope is the working path with separators changed to
/// hyphens, left undecoded: the way back is ambiguous, and the kernel is the
/// one that knows which projects exist.
pub fn claude_memories() -> Vec<Memory> {
    let root = env::claude_config_dir().join("projects");
    let mut out = vec![];
    for scope in project::subdirs(&root) {
        let dir = root.join(&scope).join("memory");
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        let mut files: Vec<PathBuf> =
            entries.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "md")).collect();
        files.sort();
        for f in files {
            // The index is not a memory: it is the table of contents.
            if f.file_name().is_some_and(|n| n == "MEMORY.md") {
                continue;
            }
            let kind = match std::fs::read(&f).map(|b| String::from_utf8_lossy(&b).into_owned()) {
                Err(_) => "!".to_string(),
                Ok(text) => {
                    let mut kind = String::new();
                    for (i, l) in text.lines().enumerate() {
                        if (i == 0 && l != "---") || (i > 0 && l == "---") {
                            break;
                        }
                        if let Some(rest) = l.trim_start().strip_prefix("type:") {
                            kind = rest.chars().filter(|c| !c.is_whitespace() && *c != '"' && *c != '\'').collect();
                            break;
                        }
                    }
                    if kind.is_empty() {
                        "?".into()
                    } else {
                        kind
                    }
                }
            };
            out.push(Memory { kind, scope: scope.clone(), path: f });
        }
    }
    out
}

fn search(argv: &[String]) -> Res {
    if argv.is_empty() {
        die!("usage: crux memory search <text>");
    }
    let query = argv.join(" ").to_lowercase();
    let root = env::projects_root();
    let mut places = vec![];
    if let Some(p) = person::dir() {
        places.push(p);
    }
    for p in project::subdirs(&root) {
        for d in project::subdirs(&root.join(&p)).into_iter().filter(|d| d.ends_with("-docs")) {
            places.push(root.join(&p).join(d));
        }
    }
    if places.is_empty() {
        die!("nothing to search: no profile and no docs repo in {}", root.display());
    }
    let mut found = vec![];
    for place in places {
        for f in markdown_under(&place) {
            let Some(text) = crate::files::read_optional(&f) else { continue };
            for (n, l) in text.lines().enumerate().filter(|(_, l)| l.to_lowercase().contains(&query)).take(3) {
                let shown = f.strip_prefix(&root).map(Path::to_path_buf).unwrap_or(f.clone());
                found.push(format!("{}:{}:{l}", shown.display(), n + 1));
            }
        }
    }
    if found.is_empty() {
        ui::info(format!("nothing found for \"{}\"", argv.join(" ")));
        return Ok(());
    }
    for l in found.iter().take(60) {
        println!("{}", l.chars().take(220).collect::<String>());
    }
    Ok(())
}

fn markdown_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() {
                if name != ".git" && name != "node_modules" {
                    stack.push(p);
                }
            } else if name.ends_with(".md") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

fn slug_of(p: &str) -> String {
    p.replace(['/', '.'], "-")
}

/// Agents name a scope with the working path and separators replaced by
/// hyphens. Undoing that is ambiguous, doing it forwards is not: the longest
/// existing project that fits wins, so one project does not take the memories
/// of another whose name starts the same.
fn project_of_scope(root: &Path, scope: &str) -> String {
    let mut best = (String::new(), 0);
    for name in project::subdirs(root) {
        if !root.join(&name).join(format!("{name}-docs")).is_dir() {
            continue;
        }
        let slug = slug_of(&root.join(&name).to_string_lossy());
        if (scope == slug || scope.starts_with(&format!("{slug}-"))) && slug.len() > best.1 {
            best = (name, slug.len());
        }
    }
    best.0
}

pub fn run(argv: &[String]) -> Res {
    if argv.first().map(String::as_str) == Some("search") {
        return search(&argv[1..]);
    }
    let (mut check, mut brief) = (false, false);
    for a in argv {
        match a.as_str() {
            "--check" => check = true,
            "--brief" => brief = true,
            _ => die!("usage: crux memory [--brief|--check] | crux memory search <text>"),
        }
    }
    let root = env::projects_root();
    // Without a projects root every memory would read as "belongs to none":
    // it is said, and the listing goes on.
    if !root.is_dir() && !check && !brief {
        ui::warn(format!("the projects root does not exist: {}", root.display()));
        ui::info("without it there is no telling which docs repo each memory belongs to");
        println!();
    }
    // Folders that are not the profile owner's: on a shared machine another
    // person works with the agent too.
    let home = env::home().to_string_lossy().into_owned();
    let ignored: Vec<String> = env::preference("CRUX_MEMORY_IGNORE", "")
        .split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| slug_of(&p.strip_prefix('~').map(|r| format!("{home}{r}")).unwrap_or_else(|| p.to_string())))
        .collect();
    let is_ignored = |s: &str| ignored.iter().any(|i| s == i || s.starts_with(&format!("{i}-")));

    // With a profile, what belongs to the person also has a place in git and
    // stops being "local by design" (ADR-018).
    let profile = person::dir();
    let profile_name = profile.as_ref().map(|p| crate::files::name(p)).unwrap_or_default();
    let (mut total, mut scopes, mut n_ignored, mut n_user, mut n_feedback) = (0, vec![], 0, 0, 0);
    let (mut unpromoted, mut personal, mut untyped, mut unreadable) = (vec![], vec![], vec![], vec![]);
    for m in claude_memories() {
        if is_ignored(&m.scope) {
            n_ignored += 1;
            continue;
        }
        total += 1;
        if !scopes.contains(&m.scope) {
            scopes.push(m.scope.clone());
        }
        let name = m.path.file_stem().unwrap().to_string_lossy().into_owned();
        match m.kind.as_str() {
            "project" | "reference" => {
                // Without a project it is not guessed: the scope it came from
                // is the datum that allows deciding.
                let p = project_of_scope(&root, &m.scope);
                let target = if !p.is_empty() {
                    format!("{p}-docs")
                } else if profile.is_some() {
                    format!("{profile_name}/about or a -docs repo")
                } else {
                    format!("scope {}", m.scope)
                };
                unpromoted.push((m.kind.clone(), name, target));
            }
            "user" | "feedback" => {
                if profile.is_some() {
                    let folder = if m.kind == "user" { "about" } else { "preferences" };
                    personal.push((m.kind.clone(), name, format!("{profile_name}/{folder}")));
                }
                if m.kind == "user" {
                    n_user += 1
                } else {
                    n_feedback += 1
                }
            }
            "?" => untyped.push(name),
            "!" => unreadable.push(m.path.display().to_string()),
            other => untyped.push(format!("{name} ({other})")),
        }
    }
    // A file that is there and cannot be read does not count as "nothing to
    // promote": that is exactly the failure that looks like it works.
    if !unreadable.is_empty() {
        ui::err("there are memories that cannot be read:");
        for u in &unreadable {
            println!("      {u}");
        }
        return exit(1);
    }
    if check {
        return if unpromoted.len() + personal.len() > 0 { exit(1) } else { Ok(()) };
    }
    if brief {
        if !personal.is_empty() {
            ui::warn(format!(
                "{} personal memories are not in the profile ({profile_name}): they do not reach the other machine",
                personal.len()
            ));
            ui::info("crux memory lists them · move each one to its folder, add it to PROFILE.md and push");
            if unpromoted.is_empty() {
                return exit(1);
            }
        }
        if unpromoted.is_empty() {
            return Ok(());
        }
        let mut sample = unpromoted.iter().take(3).map(|(_, n, _)| n.as_str()).collect::<Vec<_>>().join(", ");
        if unpromoted.len() > 3 {
            sample.push_str(&format!(", +{}", unpromoted.len() - 3));
        }
        ui::warn(format!("{} project memories live only on this machine: {sample}", unpromoted.len()));
        ui::info("crux memory lists them · /promote-to-docs puts them in git");
        return exit(1);
    }

    println!("agent memories — {total} in {} scope(s)", scopes.len());
    println!();
    if !unpromoted.is_empty() {
        ui::warn(format!("unpromoted ({})", unpromoted.len()));
        println!();
        for (kind, name, target) in &unpromoted {
            println!("      {kind:<10} {name:<34} → {target}");
        }
        println!();
        ui::info("they go to git: locally they do not survive a change of machine.");
        ui::info("/promote-to-docs puts them in the docs repo and deletes the local copy.");
        if unpromoted.iter().any(|(_, _, t)| t.starts_with("scope ")) {
            ui::info("those shown with a scope instead of a docs repo come from a");
            ui::info("directory that is not any project: the destination is up to you.");
        }
        println!();
    } else {
        ui::ok("nothing unpromoted");
        println!();
    }
    if !untyped.is_empty() {
        ui::warn(format!("no declared type ({})", untyped.len()));
        for n in &untyped {
            println!("      {n}");
        }
        ui::info("none is assumed for them: declare the type or delete them.");
        println!();
    }
    if !personal.is_empty() {
        ui::warn(format!("personal, not in the profile ({})", personal.len()));
        println!();
        for (kind, name, target) in &personal {
            println!("      {kind:<10} {name:<34} → {target}");
        }
        println!();
        let p = profile.as_ref().unwrap();
        ui::info(format!("they go to {}: one note per fact, a line in PROFILE.md, commit and push;", p.display()));
        ui::info("then delete the local copy, or the agent reads both and they drift apart.");
        println!();
        return Ok(());
    }
    if n_ignored > 0 {
        ui::info(format!(
            "ignored by CRUX_MEMORY_IGNORE: {} of folders that are someone else's",
            ui::count(n_ignored, "memory", "memories")
        ));
    }
    match &profile {
        Some(p) => ui::ok(format!("no personal memory outside the profile ({})", p.display())),
        None => {
            let mut summary = vec![];
            if n_user > 0 {
                summary.push(format!("{n_user} user"));
            }
            if n_feedback > 0 {
                summary.push(format!("{n_feedback} feedback"));
            }
            if !summary.is_empty() {
                ui::info(format!(
                    "local, with no profile to go to: {} — 'crux profile init' gives them a repo that travels",
                    summary.join(" · ")
                ));
            }
        }
    }
    Ok(())
}
