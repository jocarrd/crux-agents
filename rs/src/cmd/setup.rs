//! crux setup — a machine with nothing on it, walked through step by step.
//!
//! Each step looks first at what is already done and skips it, so running it
//! again is safe. It asks only what it cannot work out; with no terminal it
//! asks nothing, takes the defaults and says what is missing.
//!
//! It is the one command written for a person rather than for an agent, so it
//! prints in its own indented style and runs the commands it chains quietly,
//! showing their output only when they fail.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::{die, env, person, project, sh, ui};
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

const USAGE: &str = "usage: crux setup [--owner <owner>] [--projects-dir <dir>]";
const STEPS: usize = 7;

fn done(msg: impl AsRef<str>) {
    let p = ui::palette();
    println!("    {}✓{} {}", p.green, p.off, msg.as_ref());
}

fn note(msg: impl AsRef<str>) {
    let p = ui::palette();
    println!("    {}!{} {}", p.yellow, p.off, msg.as_ref());
}

fn fail(msg: impl AsRef<str>) {
    let p = ui::palette();
    println!("    {}✗{} {}", p.red, p.off, msg.as_ref());
}

fn hint(msg: impl AsRef<str>) {
    let p = ui::palette();
    println!("      {}{}{}", p.dim, msg.as_ref(), p.off);
}

/// A path as a person reads it: under their home, with `~`.
fn shown(path: &Path) -> String {
    match path.strip_prefix(env::home()) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

fn expand_home(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => env::home().join(rest).display().to_string(),
        None => path.to_string(),
    }
}

/// Another crux command, without its output unless it fails: the steps say
/// in one line what it did.
fn quietly(dir: &Path, name: &str, args: &[&str]) -> bool {
    let run = super::call_quiet(dir, name, args);
    if !run.ok() {
        print!("{}{}", run.stdout, run.stderr);
    }
    run.ok()
}

struct Prompt {
    interactive: bool,
}

impl Prompt {
    fn new() -> Self {
        // In tests the answers come on stdin, as a person would type them.
        let test_tty = env::in_tests() && env::var("CRUX_TEST_TTY").is_some();
        Prompt { interactive: std::io::stdin().is_terminal() || test_tty }
    }

    fn line(&self, question: &str, default: &str) -> String {
        if !self.interactive {
            return default.to_string();
        }
        let p = ui::palette();
        let offered = if default.is_empty() { String::new() } else { format!(" {}[{default}]{}", p.dim, p.off) };
        print!("    {}?{} {question}{offered} {}›{} ", p.cyan, p.off, p.dim, p.off);
        let _ = std::io::stdout().flush();
        let mut answer = String::new();
        // A closed stdin is an empty answer, never a wait.
        if std::io::stdin().lock().read_line(&mut answer).unwrap_or(0) == 0 {
            println!();
            return default.to_string();
        }
        match answer.trim() {
            "" => default.to_string(),
            a => a.to_string(),
        }
    }

    fn yes(&self, question: &str, default: bool) -> bool {
        let options = if default { "Y/n" } else { "y/N" };
        match self.line(&format!("{question} ({options})"), "").to_lowercase().as_str() {
            "" => default,
            a => a.starts_with('y') || a.starts_with('s'),
        }
    }

    /// Several of a list, all by default: numbers or names, `none` for none.
    /// A yes still means all, as it did when the question was all or nothing.
    fn pick(&self, question: &str, options: &[String]) -> Vec<usize> {
        let p = ui::palette();
        for (i, o) in options.iter().enumerate() {
            println!("      {}{}{} {o}", p.cyan, i + 1, p.off);
        }
        loop {
            let answer = self.line(&format!("{question} (numbers or names, none for none)"), "all").to_lowercase();
            match answer.as_str() {
                "all" | "y" | "yes" | "s" | "si" | "sí" => return (0..options.len()).collect(),
                "none" | "n" | "no" | "0" => return vec![],
                _ => {}
            }
            let picked: Option<Vec<usize>> = answer
                .split([',', ' '])
                .filter(|w| !w.is_empty())
                .map(|w| match w.parse::<usize>() {
                    Ok(n) if (1..=options.len()).contains(&n) => Some(n - 1),
                    _ => options.iter().position(|o| o.to_lowercase() == w),
                })
                .collect();
            match picked {
                Some(mut v) if !v.is_empty() => {
                    v.sort_unstable();
                    v.dedup();
                    return v;
                }
                _ if !self.interactive => return (0..options.len()).collect(),
                _ => note(format!("numbers from 1 to {}, names from the list, all or none", options.len())),
            }
        }
    }

    fn choose(&self, question: &str, options: &[String], default: usize) -> usize {
        let p = ui::palette();
        for (i, o) in options.iter().enumerate() {
            println!("      {}{}{} {o}", p.cyan, i + 1, p.off);
        }
        loop {
            match self.line(question, &(default + 1).to_string()).parse::<usize>() {
                Ok(n) if (1..=options.len()).contains(&n) => return n - 1,
                _ if !self.interactive => return default,
                _ => note(format!("a number from 1 to {}", options.len())),
            }
        }
    }
}

#[derive(PartialEq)]
enum GitHub {
    Missing,
    LoggedOut,
    Ready,
}

impl GitHub {
    fn detect() -> Self {
        if !sh::exists("gh") {
            GitHub::Missing
        } else if sh::capture("gh", &["auth", "status"]).ok() {
            GitHub::Ready
        } else {
            GitHub::LoggedOut
        }
    }
}

enum Protocol {
    Ssh,
    Https,
}

impl Protocol {
    /// The one the account clones with, so the remote works without asking.
    fn of_account() -> Self {
        match sh::capture("gh", &["config", "get", "git_protocol"]).out().as_str() {
            "ssh" => Protocol::Ssh,
            _ => Protocol::Https,
        }
    }

    fn template(&self, owner: &str) -> String {
        match self {
            Protocol::Ssh => format!("git@github.com:{owner}/{{repo}}.git"),
            Protocol::Https => format!("https://github.com/{owner}/{{repo}}.git"),
        }
    }
}

/// Whose code a project holds, which is what decides its profile.
#[derive(Clone, Copy)]
enum Kind {
    Own,
    Client,
}

impl Kind {
    const ALL: [Kind; 2] = [Kind::Own, Kind::Client];

    fn profile(self) -> &'static str {
        match self {
            Kind::Own => "multi-repo",
            Kind::Client => "client-repo",
        }
    }

    fn description(self) -> &'static str {
        match self {
            Kind::Own => "ours: our conventions apply in its repos",
            Kind::Client => "a client's: nothing of ours goes into their repos",
        }
    }
}

struct Setup {
    ask: Prompt,
    config: PathBuf,
    github: GitHub,
    remote: String,
    root: PathBuf,
    /// One line per thing settled, for the closing summary.
    summary: Vec<(&'static str, String)>,
}

impl Setup {
    fn step(&self, n: usize, title: &str) {
        let p = ui::palette();
        println!();
        println!("  {}{}{n}/{STEPS}{}  {}{title}{}", p.cyan, p.bold, p.off, p.bold, p.off);
    }

    fn machine(&mut self) {
        self.step(1, "git and GitHub");
        if self.github == GitHub::LoggedOut
            && self.ask.interactive
            && self.ask.yes("gh has no session: log in to GitHub now?", true)
        {
            let _ = Command::new("gh").args(["auth", "login"]).status();
            self.github = GitHub::detect();
        }
        done("git");
        match self.github {
            GitHub::Ready => done("GitHub, through gh"),
            GitHub::LoggedOut => note("gh has no session: 'gh auth login'"),
            GitHub::Missing => {
                note("no gh: crux works without it, but cannot find your projects on GitHub nor create repos there");
                hint("https://cli.github.com");
            }
        }
    }

    fn account(&mut self, owner_arg: &str) -> Res {
        self.step(2, "where your projects live");
        if let Some(r) = env::config_value_in(&self.config, "CRUX_REMOTE").filter(|r| !r.is_empty()) {
            done(format!("the remote this machine already has: {r}"));
            self.remote = r;
        } else if self.github != GitHub::Ready {
            fail("I do not know where your repos live");
            hint("log in with 'gh auth login' and run crux setup again,");
            hint("or give a remote of your own: crux install --remote 'git@host:you/{repo}.git'");
            return exit(1);
        } else {
            let owners = if owner_arg.is_empty() { project::search_owners() } else { vec![owner_arg.to_string()] };
            let Some(mine) = owners.first().cloned() else { die!("gh does not say which account it is — {USAGE}") };
            let owner = if owners.len() == 1 {
                mine
            } else {
                let labels: Vec<String> = owners
                    .iter()
                    .map(|o| if *o == mine { format!("{o} (your account)") } else { format!("{o} (organisation)") })
                    .collect();
                owners[self.ask.choose("where do new projects go", &labels, 0)].clone()
            };
            self.remote = Protocol::of_account().template(&owner);
            done(format!("new repos go to {owner}"));
        }
        self.summary.push(("remote", self.remote.clone()));
        Ok(())
    }

    fn folder(&mut self, dir_arg: &str) -> Res {
        self.step(3, "the projects folder");
        let dir = if dir_arg.is_empty() {
            let default = env::config_value_in(&self.config, env::PROJECTS_DIR_KEY)
                .unwrap_or_else(|| env::default_projects_root().display().to_string());
            expand_home(&self.ask.line("where projects are cloned", &shown(Path::new(&default))))
        } else {
            dir_arg.to_string()
        };
        self.root = PathBuf::from(&dir);
        if let Err(e) = std::fs::create_dir_all(&self.root) {
            die!("cannot create {}: {e}", self.root.display());
        }
        done(format!("projects in {}", shown(&self.root)));
        // The commands this calls find the projects through it.
        std::env::set_var(env::PROJECTS_DIR_KEY, &dir);
        self.summary.push(("projects", shown(&self.root)));
        Ok(())
    }

    fn kernel(&mut self) -> Res {
        self.step(4, "crux on this machine");
        let here = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
        let dir = self.root.display().to_string();
        if !quietly(&here, "install", &["--projects-dir", &dir, "--remote", &self.remote]) {
            die!("the installation failed: see above");
        }
        done(format!("crux {} in ~/.crux, the command in ~/.local/bin", env::crux_version()));
        done("skills and hooks loaded into Claude and Codex");
        self.summary.push(("crux", env::crux_version()));
        Ok(())
    }

    fn profile(&mut self) {
        self.step(5, "your profile");
        let name = person::repo_name();
        let local = self.root.join(&name);
        let me = if self.github == GitHub::Ready { project::default_owner() } else { String::new() };
        let state = if local.join("PROFILE.md").is_file() {
            quietly(&self.root, "profile", &["link"]);
            done(format!("{} loaded into the agents", shown(&local)));
            "loaded"
        } else if !me.is_empty() && sh::capture("gh", &["repo", "view", &format!("{me}/{name}")]).ok() {
            if self.ask.yes(&format!("your profile is on {me}: bring it?"), true)
                && quietly(&self.root, "profile", &["clone", "--owner", &me])
            {
                done(format!("{me}/{name} brought and loaded into the agents"));
                "brought from the remote"
            } else {
                "on the remote, not here"
            }
        } else {
            hint("a private repo with how you like to work, loaded by every agent on every machine");
            if self.ask.yes("no profile yet: create it?", false) && quietly(&self.root, "profile", &["init"]) {
                done(format!("{} created, private, and loaded into the agents", shown(&local)));
                "created"
            } else {
                hint("'crux profile init' creates it later");
                "none"
            }
        };
        self.summary.push(("profile", state.to_string()));
    }

    fn projects(&mut self) {
        self.step(6, "your projects");
        let here = projects_here(&self.root);
        for p in &here {
            done(format!("{p} is on this machine"));
        }
        let owners = if self.github == GitHub::Ready { project::search_owners() } else { vec![] };
        let missing: Vec<(String, String)> = owners
            .iter()
            .flat_map(|o| projects_on(o).into_iter().map(move |p| (o.clone(), p)))
            .filter(|(_, p)| !here.contains(p))
            .collect();
        let mut names = here.clone();
        if !missing.is_empty() {
            hint("on your account and not here:");
            let list: Vec<String> = missing.iter().map(|(_, p)| p.clone()).collect();
            let chosen = self.ask.pick("which to bring to this machine", &list);
            if chosen.is_empty() {
                hint("none brought: crux clone <project> brings one later");
            } else {
                let dir = self.root.display().to_string();
                for (owner, p) in chosen.iter().map(|&i| &missing[i]) {
                    let from = self.template_of(owner);
                    if quietly(&self.root, "clone", &[p, "--parent", &dir, "--from", &from]) {
                        done(format!("{p}: its repos, pointers and hooks"));
                        names.push(p.clone());
                    }
                }
            }
        } else if here.is_empty() && self.ask.yes("no project yet: create your first project?", false) {
            if let Some(p) = self.create_first() {
                names.push(p);
            }
        }
        self.summary.push(("projects here", if names.is_empty() { "none yet".into() } else { names.join(", ") }));
    }

    /// The machine's remote pointing at `owner`. One that is not GitHub's has
    /// no owner to swap, and is used as it is.
    fn template_of(&self, owner: &str) -> String {
        let current = project::owner_from_template(&self.remote);
        if current.is_empty() || current == owner {
            self.remote.clone()
        } else {
            project::template_with_owner(&self.remote, owner)
        }
    }

    fn create_first(&self) -> Option<String> {
        let name = loop {
            let n = self.ask.line("its name, in lowercase with hyphens", "");
            if !n.is_empty() && project::valid_name(&n) {
                break n;
            }
            if !self.ask.interactive {
                return None;
            }
            note("letters, digits and hyphens: shop, client-portal");
        };
        let owner = project::owner_from_template(&self.remote);
        if self.github == GitHub::Ready && !owner.is_empty() {
            let profile_repo = person::repo_name();
            let listed =
                sh::capture("gh", &["repo", "list", &owner, "--limit", "100", "--json", "name", "--jq", ".[].name"]);
            let repos: Vec<&str> =
                listed.stdout.lines().filter(|r| !r.ends_with("-docs") && *r != profile_repo).collect();
            if !repos.is_empty() {
                hint(format!("repos on {owner}: {}", repos.join(", ")));
            }
        }
        let repos = self.ask.line("its code repos, separated by commas (empty: none yet)", "").replace(' ', "");
        let labels: Vec<String> = Kind::ALL.iter().map(|k| k.description().to_string()).collect();
        let kind = Kind::ALL[self.ask.choose("whose code is it", &labels, 0)];

        let dir = self.root.display().to_string();
        let mut args = vec![name.as_str(), "--parent", &dir, "--profile", kind.profile()];
        if !repos.is_empty() {
            args.extend(["--repos", &repos]);
        }
        if !quietly(&self.root, "init", &args) {
            fail(format!("{name} could not be created: see above"));
            return None;
        }
        let docs = self.root.join(&name).join(format!("{name}-docs"));
        done(format!("{name}-docs created on the remote, with its contract and templates"));
        // The code repos are on the remote already: brought here, they get
        // their pointers and their hooks.
        for repo in repos.split(',').filter(|r| !r.is_empty() && project::valid_name(r)) {
            let target = self.root.join(&name).join(repo);
            let url = self.remote.replace("{repo}", repo);
            if target.exists() || sh::capture("git", &["clone", "-q", &url, &target.to_string_lossy()]).ok() {
                done(format!("{repo} cloned"));
            } else {
                note(format!("{repo} could not be cloned from {url}"));
            }
        }
        if quietly(&docs, "link", &[&docs.to_string_lossy()]) && quietly(&docs, "hooks", &["install"]) {
            done("pointers and git hooks in each repo");
        }
        Some(name)
    }

    fn finish(&self) {
        self.step(7, "what is left");
        let check = super::call_quiet(&self.root, "machine", &[]);
        let findings: Vec<&str> =
            check.stdout.lines().filter(|l| l.starts_with("warn") || l.starts_with("error")).collect();
        if findings.is_empty() {
            done("nothing: every tool the skills use is here");
        }
        for f in findings {
            let (kind, text) = f.split_once(char::is_whitespace).unwrap_or(("", f));
            if kind == "error" {
                fail(text.trim());
            } else {
                note(text.trim());
            }
        }

        let p = ui::palette();
        let width = self.summary.iter().map(|(k, _)| k.len()).max().unwrap_or(0);
        println!();
        println!("  {}{}✓ ready{}", p.green, p.bold, p.off);
        println!();
        for (k, v) in &self.summary {
            println!("    {}{k:<width$}{}  {v}", p.dim, p.off);
        }
        println!();
        // The commands are the agent's: a person starts working by talking to it.
        println!("  Open Claude Code or Codex in any of your projects and start working:");
        println!("  the agent already knows how, crux is in place.");
        println!();
    }
}

fn banner() {
    const WIDTH: usize = 46;
    let p = ui::palette();
    // Each line as it is seen and as it is printed: the padding counts what is
    // seen, not the colour codes.
    let lines = [
        ("◆ crux · agents".to_string(), format!("{}{}◆ crux{} {}· agents{}", p.cyan, p.bold, p.off, p.dim, p.off)),
        (
            format!("this machine, ready for agents in {STEPS} steps"),
            format!("this machine, ready for agents in {STEPS} steps"),
        ),
    ];
    println!();
    println!("  {}╭{}╮{}", p.dim, "─".repeat(WIDTH), p.off);
    for (seen, printed) in &lines {
        let pad = WIDTH.saturating_sub(seen.chars().count() + 2);
        println!("  {}│{}  {printed}{}{}│{}", p.dim, p.off, " ".repeat(pad), p.dim, p.off);
    }
    println!("  {}╰{}╯{}", p.dim, "─".repeat(WIDTH), p.off);
}

/// The repos of an owner that are projects of crux: a `-docs` repo with a
/// contract.
fn projects_on(owner: &str) -> Vec<String> {
    project::candidate_projects(owner)
        .into_iter()
        .filter(|p| sh::capture("gh", &["api", &format!("repos/{owner}/{p}-docs/contents/crux.json")]).ok())
        .collect()
}

fn projects_here(dir: &Path) -> Vec<String> {
    project::subdirs(dir)
        .into_iter()
        .filter(|p| dir.join(p).join(format!("{p}-docs")).join("crux.json").is_file())
        .collect()
}

pub fn run(argv: &[String]) -> Res {
    let (mut owner_arg, mut dir_arg) = (String::new(), String::new());
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--owner" => owner_arg = p.value(),
            "--projects-dir" => dir_arg = expand_home(&p.value()),
            other => die!("unknown option: {other} — {USAGE}"),
        }
    }
    if !sh::exists("git") {
        die!("git is needed: install it and run crux setup again");
    }
    banner();
    let mut s = Setup {
        ask: Prompt::new(),
        config: env::home().join(".crux/config"),
        github: GitHub::detect(),
        remote: String::new(),
        root: PathBuf::new(),
        summary: vec![],
    };
    s.machine();
    s.account(&owner_arg)?;
    s.folder(&dir_arg)?;
    s.kernel()?;
    s.profile();
    s.projects();
    s.finish();
    Ok(())
}
