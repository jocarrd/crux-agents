//! crux profile — the person's memory, in a repo that travels between machines.
//!
//!   crux profile            where it is, what it holds and whether something is unpublished
//!   crux profile init       creates it: skeleton, private repo on the remote, and loads it
//!   crux profile link       loads it into each agent on this machine (Claude, Codex)
//!   crux profile clone      brings it from the remote if this machine does not have it
//!
//! A project's knowledge lives in its docs repo. What belongs to the person
//! had nowhere to go but the agent's local memory, which does not travel and
//! which each agent keeps in its own way. This is that place (ADR-018).

use crate::args::Parser;
use crate::error::Res;
use crate::names;
use crate::{die, env, git, person, project, sh, ui};
use std::path::Path;

const PROFILE_SKELETON: &str = "---
# reminder: a line the agents get on every message, in your words (optional)
---

# Profile for agents

Write here, in your own language, how agents should work with you. Whatever
goes in this index is read in every session: keep it short and link the detail.

**When the person states a preference or something about themselves**, save it
here and not in the agent's local memory: one note per fact in `preferences/`
(how they want you to work) or `about/` (who they are, their plans, their
accounts), one line in this index, then `git commit` and `git push` right away.
What only holds on one computer goes in `machines/<hostname>.md`. A project's
knowledge goes to its `-docs` repo; keys and passwords go nowhere in git.

## Preferences

## About

## Machines
";

const README_SKELETON: &str = "# agent-profile

The person's memory for their agents: preferences, who they are and what only
holds on one machine. Plain markdown, tied to no agent: `crux profile link`
loads it into each one and `crux sync` carries it between machines.

| Folder | What goes there |
| ------ | --------------- |
| `PROFILE.md` | The index loaded in every session. Short: the rest is opened when needed |
| `preferences/` | How the agents should work |
| `about/` | Who the person is, their plans, their accounts |
| `machines/<hostname>.md` | What only holds on one computer; loaded only there |

What does not go here: a project's knowledge (its `-docs` repo) and keys (each machine).
";

/// Each machine adds its line at the end of the same index section, so two
/// preferences saved on two machines always clashed. The index is a list of
/// independent lines: keeping both is the right merge.
fn union_index(dir: &Path) {
    if !dir.join(".git").is_dir() {
        return;
    }
    let attrs = dir.join(".git/info/attributes");
    if std::fs::read_to_string(&attrs).is_ok_and(|t| t.lines().any(|l| l == "PROFILE.md merge=union")) {
        return;
    }
    let _ = std::fs::create_dir_all(dir.join(".git/info"));
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&attrs) {
        let _ = std::io::Write::write_all(&mut f, b"PROFILE.md merge=union\n");
    }
}

pub fn link() -> Res {
    let Some(dir) = person::dir() else {
        // An import of a profile that is gone would load as nothing, without
        // a word: the blocks are removed so what is left says the truth.
        let _ = person::load_into_claude(None, None);
        if env::codex_home_dir().is_dir() {
            let _ = person::load_into_codex(None, None);
        }
        die!(
            "there is no profile at {} — removed its block from the agents; 'crux profile init' or 'crux profile clone'",
            person::expected_dir().display()
        );
    };
    union_index(&dir);
    let note = person::machine_note(&dir);
    if let Err(e) = person::load_into_claude(Some(&dir), note.as_deref()) {
        die!("cannot write Claude's context: {e}");
    }
    ui::ok(format!("Claude: {}/CLAUDE.md imports {}/PROFILE.md", env::claude_config_dir().display(), dir.display()));
    // Only if Codex is on the machine: creating its folder installs nothing.
    let codex = env::codex_home_dir();
    if codex.is_dir() {
        if let Err(e) = person::load_into_codex(Some(&dir), note.as_deref()) {
            die!("cannot write Codex's context: {e}");
        }
        ui::ok(format!("Codex: {}/AGENTS.md carries a copy of the index", codex.display()));
        let size = std::fs::metadata(codex.join(names::AGENTS)).map(|m| m.len()).unwrap_or(0);
        if size > 24576 {
            ui::warn(format!(
                "Codex's AGENTS.md weighs {size} bytes: it stops reading at 32 KiB, keep the index short"
            ));
        }
    }
    if let Some(n) = note {
        ui::info(format!("and this machine's note: {}", n.display()));
    }
    Ok(())
}

fn status() -> Res {
    let Some(dir) = person::dir() else {
        ui::warn(format!("no profile on this machine ({})", person::expected_dir().display()));
        ui::info("'crux profile clone' brings it if it exists; 'crux profile init' creates it");
        return Ok(());
    };
    println!("profile in {}", dir.display());
    match person::field(&dir, "reminder").filter(|r| !r.is_empty()) {
        Some(r) => ui::info(format!("reminder on every message: {r}")),
        None => ui::info("no reminder on every message (reminder: in PROFILE.md)"),
    }
    for sub in ["preferences", "about", "machines"] {
        // git does not keep empty folders: a cloned profile may lack them.
        let n = std::fs::read_dir(dir.join(sub))
            .map(|e| e.flatten().filter(|x| x.file_name().to_string_lossy().ends_with(".md")).count())
            .unwrap_or(0);
        ui::info(format!("{sub}: {n}"));
    }
    match person::machine_note(&dir) {
        Some(n) => ui::info(format!("this machine: {}", crate::files::name(&n))),
        None => ui::info("this machine has no note of its own"),
    }
    let dirty = git::out(&dir, &["status", "--porcelain"]).map(|s| s.lines().count()).unwrap_or(0);
    let ahead = git::out(&dir, &["rev-list", "--count", "@{u}..HEAD"]).unwrap_or_else(|| "?".into());
    if dirty > 0 {
        ui::warn(format!("{} not committed", ui::count(dirty, "file", "files")));
    }
    if ahead != "0" && ahead != "?" {
        ui::warn(format!("{} not pushed", ui::count(ahead.parse().unwrap_or(0), "commit", "commits")));
    }
    if ahead == "?" {
        ui::warn("no remote branch: what it holds lives only here");
    }
    let file = env::claude_config_dir().join(names::CLAUDE);
    if std::fs::read_to_string(&file).is_ok_and(|t| t.contains(&format!("@{}/PROFILE.md", dir.display()))) {
        ui::ok("Claude loads it");
    } else {
        ui::warn("Claude does not load it — 'crux profile link'");
    }
    Ok(())
}

fn skeleton(dir: &Path) -> std::io::Result<()> {
    for sub in ["preferences", "about", "machines"] {
        std::fs::create_dir_all(dir.join(sub))?;
        // Empty folders do not travel in git; the other machine would get none.
        std::fs::write(dir.join(sub).join(".gitkeep"), "")?;
    }
    if !dir.join("PROFILE.md").is_file() {
        std::fs::write(dir.join("PROFILE.md"), PROFILE_SKELETON)?;
    }
    if !dir.join(names::README).is_file() {
        std::fs::write(dir.join(names::README), README_SKELETON)?;
    }
    Ok(())
}

/// gh only covers GitHub. Elsewhere —GitLab, a server of your own, a bare repo
/// on disk— the URL comes from the same template crux init uses, and creating
/// the repo on the provider is left to the person, as init does.
fn uses_gh() -> bool {
    let t = project::remote_template().unwrap_or_default();
    sh::exists("gh") && (t.is_empty() || t.contains("github.com"))
}

fn init(argv: &[String]) -> Res {
    let (mut remote, mut owner) = (true, String::new());
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--no-remote" => remote = false,
            "--owner" => owner = p.value(),
            _ => die!("usage: crux profile init [--owner <owner>] [--no-remote]"),
        }
    }
    let dir = person::expected_dir();
    let name = person::repo_name();
    if dir.join("PROFILE.md").is_file() {
        ui::ok(format!("there is already a profile in {}", dir.display()));
    } else {
        if let Err(e) = skeleton(&dir) {
            die!("cannot write the skeleton in {}: {e}", dir.display());
        }
        ui::ok(format!("skeleton in {}", dir.display()));
    }
    if !dir.join(".git").is_dir() {
        git::run(&dir, &["init", "-q", "-b", "main"]);
        git::run(&dir, &["add", "-A"]);
        git::run(&dir, &["commit", "-qm", "chore: agent profile skeleton"]);
    }
    let has_origin = |d: &Path| git::remote_url(d, "origin").is_some();
    if remote && !has_origin(&dir) && !uses_gh() {
        let Some(template) = project::remote_template() else {
            die!("no remote: set CRUX_REMOTE in ~/.crux/config, install gh for GitHub, or pass --no-remote")
        };
        let url = template.replace("{repo}", &name);
        git::run(&dir, &["remote", "add", "origin", &url]);
        if git::ok(&dir, &["push", "-q", "-u", "origin", "HEAD"]) {
            ui::ok(format!("pushed to {url}"));
        } else {
            ui::warn("the remote repo does not exist yet: create it on your provider as **private**");
            ui::info(format!("cd {} && git push -u origin HEAD", dir.display()));
        }
    }
    if remote && !has_origin(&dir) {
        if owner.is_empty() {
            owner = project::default_owner();
        }
        if owner.is_empty() {
            die!("I do not know which account to create it under — pass it with --owner");
        }
        // Private: it says how the person works and who they are.
        let code = sh::status(
            std::process::Command::new("gh")
                .args([
                    "repo",
                    "create",
                    &format!("{owner}/{name}"),
                    "--private",
                    "--source",
                    &dir.to_string_lossy(),
                    "--push",
                    "-d",
                    "Agent profile: preferences, about, machines",
                ])
                .stdout(std::process::Stdio::null()),
        );
        if code != 0 {
            return crate::error::exit(code);
        }
        ui::ok(format!("private repo {owner}/{name}"));
    }
    link()
}

fn clone(argv: &[String]) -> Res {
    let mut owner = if argv.first().map(String::as_str) == Some("--owner") {
        argv.get(1).cloned().unwrap_or_default()
    } else {
        String::new()
    };
    let dir = person::expected_dir();
    let name = person::repo_name();
    if dir.join(".git").is_dir() {
        ui::ok(format!("the profile is already here: {}", dir.display()));
        return link();
    }
    if !uses_gh() {
        let Some(template) = project::remote_template() else {
            die!("no remote: set CRUX_REMOTE in ~/.crux/config, or install gh for GitHub")
        };
        let url = template.replace("{repo}", &name);
        if !sh::capture("git", &["clone", "-q", &url, &dir.to_string_lossy()]).ok() {
            ui::warn(format!("{url} could not be cloned — 'crux profile init' creates it"));
            return Ok(());
        }
        ui::ok(format!("profile cloned in {}", dir.display()));
        return link();
    }
    if owner.is_empty() {
        owner = project::default_owner();
    }
    if owner.is_empty() {
        die!("I do not know which account to look under — pass it with --owner");
    }
    if !sh::capture("gh", &["repo", "view", &format!("{owner}/{name}")]).ok() {
        ui::warn(format!("{owner}/{name} does not exist — 'crux profile init' creates it"));
        return Ok(());
    }
    sh::status(std::process::Command::new("gh").args([
        "repo",
        "clone",
        &format!("{owner}/{name}"),
        &dir.to_string_lossy(),
        "--",
        "-q",
    ]));
    ui::ok(format!("profile cloned in {}", dir.display()));
    link()
}

pub fn run(argv: &[String]) -> Res {
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    match argv.first().map(String::as_str).unwrap_or("status") {
        "status" => status(),
        "link" => link(),
        "init" => init(rest),
        "clone" => clone(rest),
        _ => die!("usage: crux profile [status|link|init|clone]"),
    }
}
