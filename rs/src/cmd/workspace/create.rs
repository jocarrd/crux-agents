//! Opening workspaces: a new one, one resumed from another machine's task,
//! and one made by hand that the registry did not know.

use super::{free_slot, load_config, lock, workspace_path, Slot};
use crate::args::Parser;
use crate::error::{exit, Exit, Res};
use crate::names;
use crate::task::record;
use crate::{die, env, files, git, policy, project, registry, signals, template, ui};
use std::path::{Path, PathBuf};
use std::process::Command;

/// While a workspace is being created its slot is reserved in the registry.
/// If creation stops halfway, the reservation is released; with the worktree
/// already on disk the entry stays, because removing it would leave a
/// worktree the tool no longer recognises and a slot handed out twice.
struct Reservation {
    name: String,
    worktree_done: bool,
    finished: bool,
}

impl Drop for Reservation {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        if self.worktree_done {
            ui::warn(format!("workspace '{}' half-done — remove it with: crux workspace rm {}", self.name, self.name));
        } else if let Ok(_lock) = registry::lock(50) {
            let n = self.name.clone();
            let _ = registry::update(|l| l.retain(|w| w.name != n));
        }
    }
}

fn interrupted() -> Res {
    match signals::received() {
        Some(_) => Err(Exit(signals::exit_code())),
        None => Ok(()),
    }
}

pub struct NewArgs {
    pub name: String,
    pub repo: PathBuf,
    pub base: String,
    pub branch: String,
    pub force: bool,
    pub task: String,
    pub goal: String,
    pub defer_cd: bool,
}

pub fn new(argv: &[String]) -> Res {
    let Some(name) = argv.first().filter(|n| !n.is_empty()).cloned() else {
        die!("usage: crux workspace new <name> [--repo <dir>] [--base <branch>] [--branch <branch>]")
    };
    let mut a = NewArgs {
        name,
        repo: std::env::current_dir().unwrap_or_default(),
        base: String::new(),
        branch: String::new(),
        force: false,
        task: String::new(),
        goal: String::new(),
        defer_cd: env::var("CRUX_DEFER_CD").is_some(),
    };
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--repo" => a.repo = PathBuf::from(p.value()),
            "--task" => a.task = p.value(),
            "--goal" => a.goal = p.value(),
            "--base" => a.base = p.value(),
            "--branch" => a.branch = p.value(),
            "--force" => a.force = true,
            other => die!("unknown option: {other}"),
        }
    }
    create(a)
}

pub fn create(a: NewArgs) -> Res {
    signals::install();
    let name = a.name.clone();
    if !project::valid_name(&name) {
        die!("invalid workspace name: '{name}' — letters, numbers, dot, hyphen and underscore, no slashes or '..'");
    }
    let Some(repo) = (if a.repo.is_dir() { git::toplevel(&a.repo) } else { None }) else {
        die!("not a git repo: {}", a.repo.display())
    };
    project::refuse_if_archived(&repo)?;
    let repo_name = files::name(&repo);
    let path = repo.parent().unwrap_or(Path::new("/")).join(format!("{repo_name}-ws-{name}"));
    // A task touching several repos opens a workspace in each with the same
    // --task: all of them write to the same record.
    let task = if a.task.is_empty() { name.clone() } else { a.task.clone() };
    if !project::valid_name(&task) {
        die!("invalid task name: '{task}'");
    }
    let project_name = crate::task::project_name_for(&repo);
    let docs = project::find_docs_repo(&repo);
    let profile = docs.as_deref().and_then(|d| project::contract_field(d, "profile")).unwrap_or_default();
    // The workspace name is local; the branch name is published. In a client's
    // repo `ws/<whatever>` shows our naming: the profile decides the pattern.
    let pattern = policy::get(&profile, docs.as_deref(), "branch.pattern").unwrap_or_else(|| "ws/{{name}}".into());
    let branch = if a.branch.is_empty() { pattern.replace("{{name}}", &name) } else { a.branch.clone() };
    if branch == project::main_branch(&repo) {
        die!("{branch} is the main branch, checked out in {}: --branch takes a work branch", repo.display());
    }
    if path.exists() {
        die!("{} already exists", path.display());
    }
    warn_before_creating(&a, &repo, &repo_name, &profile, docs.as_deref(), &branch);
    let config = load_config(docs.as_deref(), &repo_name)?;
    super::clean::heal(true)?;
    if let Err(e) = registry::init() {
        die!("cannot prepare the registry: {e}");
    }

    let entry = registry::Workspace {
        name: name.clone(),
        slot: 0,
        repo: repo.to_string_lossy().into_owned(),
        path: path.to_string_lossy().into_owned(),
        branch: branch.clone(),
        ports: (0, 0),
        task: task.clone(),
        project: project_name.clone(),
        extra: [(registry::CREATING.to_string(), serde_json::json!(std::process::id()))].into_iter().collect(),
    };
    let (mut reservation, number) = reserve_slot(entry, &config)?;
    let slot = Slot { number, first_port: config.port_base + number * config.per_slot, name: &name, branch: &branch };

    add_worktree(&repo, &path, &branch, &a.base)?;
    reservation.worktree_done = true;
    created(&name);
    ui::ok(format!("worktree {} (branch {branch})", path.display()));
    interrupted()?;

    let record_file = env::tasks_dir().join(&project_name).join(format!("{task}.md"));
    if register_task(&record_file, &task, &project_name, &repo_name, &name, &branch, &a.goal) {
        ui::info(format!(
            "write it in '{}': the proposal description comes from it",
            policy::commit_language(&profile, docs.as_deref())
        ));
    }
    exclude_local_state(&path, &config.env_file);
    // An unversioned file does not travel with `git worktree add`.
    if let Some(d) = docs.as_deref() {
        if policy::flag(&profile, Some(d), "pointers.local", false) {
            if let Ok(template::LocalPointer::Written) = template::write_local_pointer(&path, &files::name(d)) {
                ui::ok(format!("{} points to {} (excluded from git)", template::LOCAL_POINTER, files::name(d)));
            }
        }
    }
    if config.env_file.is_empty() {
        ui::info(format!("no workspace configuration for {repo_name}: only the port range is reserved"));
    } else {
        write_env(&config, &repo, &path, &slot, &repo_name);
    }
    interrupted()?;
    if config.install {
        install_dependencies(&path)?;
    }
    if !config.setup.is_empty() {
        let code =
            signals::run_interruptible(Command::new("bash").args(["-c", &slot.fill(&config.setup)]).current_dir(&path));
        interrupted()?;
        if code == 0 {
            ui::ok("setup executed");
        } else {
            ui::warn("the setup failed — the workspace exists, but check its resources");
        }
    }
    interrupted()?;
    reservation.finished = true;
    println!();
    ui::ok(format!("workspace '{name}' ready"));
    ui::info(format!("slot {number} · ports {}-{}", slot.first_port, slot.first_port + config.per_slot - 1));
    // resume says where to go once, after everything else it reports.
    if !a.defer_cd {
        ui::info(format!("cd {}", path.display()));
    }
    Ok(())
}

fn warn_before_creating(a: &NewArgs, repo: &Path, repo_name: &str, profile: &str, docs: Option<&Path>, branch: &str) {
    // Another workspace on this repo is the sign of another live session.
    let others: Vec<String> = registry::read()
        .unwrap_or_default()
        .iter()
        .filter(|w| Path::new(&w.repo) == repo)
        .map(|w| format!("{} ({})", w.name, w.branch))
        .collect();
    if !others.is_empty() {
        ui::warn(format!("there is already open work on {repo_name}: {}", others.join(", ")));
    }
    // `pointers.write: false` says the standard's documentation is not written
    // in the code repo, not that you cannot work in it: a local branch is not
    // documentation. What does go out to the client is `finish`.
    if profile.is_empty() || a.force || policy::flag(profile, docs, "pointers.write", true) {
        return;
    }
    let docs_name = docs.map(files::name).unwrap_or_default();
    ui::warn(format!("profile {profile}: the branch and the worktree are local and yours, but the"));
    ui::warn(format!("documentation of {repo_name} goes to {docs_name}, not to the client's repo"));
    if a.branch.is_empty() {
        ui::warn(format!("and the branch '{branch}' will be seen in their repository, with our naming"));
        ui::info(format!("to choose it: crux workspace new {} --branch fix/<something-in-english>", a.name));
    }
}

/// Takes the lowest free slot and writes the entry with it. The lock is held
/// only for this: installing and running the setup takes minutes, and another
/// workspace must not wait for it.
fn reserve_slot(mut entry: registry::Workspace, config: &super::Config) -> Result<(Reservation, i64), Exit> {
    let guard = lock()?;
    // The registry is indexed by workspace name: two repos with the same name
    // would trample each other.
    let list = match registry::read() {
        Ok(l) => l,
        Err(e) => die!("{e}"),
    };
    if let Some(taken) = list.iter().find(|w| w.name == entry.name) {
        drop(guard);
        ui::err(format!("there is already a workspace called {} in the registry", entry.name));
        ui::info(format!("it is at {}", taken.path));
        ui::info(format!("use another name, or remove it with: crux workspace rm {}", entry.name));
        return Err(Exit(1));
    }
    let Some(slot) = free_slot(&list, config.port_base, config.per_slot) else { die!("could not allocate a slot") };
    let port0 = config.port_base + slot * config.per_slot;
    entry.slot = slot;
    entry.ports = (port0, port0 + config.per_slot - 1);
    let name = entry.name.clone();
    if let Err(e) = registry::update(|l| l.push(entry)) {
        die!("{e}");
    }
    Ok((Reservation { name, worktree_done: false, finished: false }, slot))
}

/// The worktree exists: the entry stops being a reservation.
fn created(name: &str) {
    if let Ok(_lock) = lock() {
        let _ = registry::update(|l| {
            for w in l.iter_mut().filter(|w| w.name == name) {
                w.extra.remove(registry::CREATING);
            }
        });
    }
}

/// A requested base that fails stops it: falling back to HEAD in silence means
/// working for hours on the wrong base. Without one, an existing branch is
/// checked out, or a new one is created from HEAD.
fn add_worktree(repo: &Path, path: &Path, branch: &str, base: &str) -> Res {
    let path = path.to_string_lossy();
    if !base.is_empty() {
        if !git::has_ref(repo, &format!("refs/heads/{base}"))
            && !git::has_ref(repo, &format!("refs/remotes/origin/{base}"))
        {
            die!("the base {base} does not exist in {}", repo.display());
        }
        let r = git::run(repo, &["worktree", "add", "-b", branch, &path, base]);
        eprint!("{}", r.stderr);
        if !r.ok() {
            die!("could not create the worktree from {base}");
        }
    } else if !git::ok(repo, &["worktree", "add", &path, branch]) {
        let r = git::run(repo, &["worktree", "add", "-b", branch, &path]);
        eprint!("{}", r.stderr);
        if !r.ok() {
            die!("could not create the worktree");
        }
    }
    Ok(())
}

/// Creates the task record, or joins the one already open, and notes this
/// repo's branch so another machine knows how to resume it. Failing to write
/// it is reported but does not undo the workspace: it returns whether the
/// record exists.
fn register_task(
    record_file: &Path,
    task: &str,
    project_name: &str,
    repo_name: &str,
    name: &str,
    branch: &str,
    goal: &str,
) -> bool {
    let archived = (!record_file.exists())
        .then(|| record_file.parent().and_then(|dir| record::archived_copy(dir, task)))
        .flatten();
    let ensured = if record_file.exists() {
        record::edit(record_file, true, |d| {
            record::join(d, repo_name, name);
            Ok(true)
        })
    } else if let Some(old) = &archived {
        // A new workspace for an archived task reopens it instead of starting an empty one
        record::read(old).and_then(|mut d| {
            record::reopen(&mut d, &crate::files::name(old));
            record::join(&mut d, repo_name, name);
            record::write(record_file, &mut d, true)?;
            std::fs::remove_file(old).map_err(|e| e.to_string())?;
            ui::ok(format!("reopens the archived task '{task}'"));
            Ok(true)
        })
    } else {
        let mut d = record::create(task, project_name, repo_name, name);
        record::write(record_file, &mut d, true).map(|_| false)
    };
    match ensured {
        Ok(true) => ui::ok(format!("joins the already open task '{task}'")),
        Ok(false) => {
            ui::ok(format!("task '{task}' registered"));
            hint_unattended_tasks(project_name, task, name);
        }
        Err(e) => {
            ui::warn(format!("could not write the task record: {e}"));
            return false;
        }
    }
    let noted = record::edit(record_file, true, |d| {
        let mut list: Vec<String> =
            d.list("branches").into_iter().filter(|e| !e.starts_with(&format!("{repo_name}="))).collect();
        list.push(format!("{repo_name}={branch}"));
        d.set("branches", record::Meta::List(list));
        if !goal.is_empty() {
            record::set_section(d, "Objective", goal);
        }
        Ok(())
    });
    if noted.is_err() {
        ui::warn("could not note the branch in the task: without it, another machine will not know how to resume it");
    }
    true
}

/// A new task while others in the project sit open with no workspace: the
/// work may belong to one of them, and a second record leaves the first open
/// forever.
fn hint_unattended_tasks(project_name: &str, task: &str, name: &str) {
    let live = crate::task::sync::live_workspaces();
    let others: Vec<String> = crate::task::remind::open_tasks(Some(project_name))
        .into_iter()
        .filter(|t| t.task != task && t.waiting.is_none() && !t.workspaces.iter().any(|w| live.contains(w)))
        .map(|t| t.task)
        .collect();
    if others.is_empty() {
        return;
    }
    ui::info(format!("open tasks in {project_name} with no workspace: {}", others.join(", ")));
    ui::info(format!("if this work is one of them: crux workspace new {name} --task <task>"));
}

/// The gate marker and the env file are local state: into the common
/// directory's exclude, which git honours from a worktree, never the
/// versioned .gitignore.
fn exclude_local_state(path: &Path, env_file: &str) {
    let Some(common) = git::common_dir(path) else { return };
    let _ = std::fs::create_dir_all(common.join("info"));
    let exclude = common.join("info/exclude");
    let mut current = match files::read_if_exists(&exclude) {
        Ok(t) => t,
        Err(e) => {
            ui::warn(format!("{e} — the gate receipt and {env_file} are not ignored, and could be committed"));
            return;
        }
    };
    // uv run writes uv.lock; a Python repo that does not version it would see
    // it as a change and finish would refuse the proposal over it
    let lockfile = path.join("pyproject.toml").is_file()
        && git::out(path, &["ls-files", "--", "uv.lock"]).unwrap_or_default().trim().is_empty();
    let uv_lock = if lockfile { "/uv.lock" } else { "" };
    for entry in [names::GATE_RECEIPT, names::VISUAL_RECEIPT, env_file, uv_lock].into_iter().filter(|e| !e.is_empty()) {
        if !current.lines().any(|l| l == entry) {
            if !current.is_empty() && !current.ends_with('\n') {
                current.push('\n');
            }
            current.push_str(entry);
            current.push('\n');
        }
    }
    if let Err(e) = files::write(&exclude, &current) {
        ui::warn(format!("{e} — the gate receipt and {env_file} are not ignored, and could be committed"));
    }
}

const INSTALLERS: [(&str, &str); 9] = [
    ("pnpm-lock.yaml", "pnpm install --prefer-offline"),
    ("package-lock.json", "npm ci --prefer-offline"),
    ("yarn.lock", "yarn install"),
    ("bun.lockb", "bun install"),
    ("uv.lock", "uv sync"),
    ("poetry.lock", "poetry install"),
    ("requirements.txt", "pip install -r requirements.txt"),
    ("go.mod", "go mod download"),
    ("Cargo.toml", "cargo fetch"),
];

/// A worktree shares the history but not ignored files: it is born without
/// dependencies, and the first command run there fails without saying why.
fn install_dependencies(path: &Path) -> Res {
    let Some((_, install)) = INSTALLERS.into_iter().find(|(f, _)| path.join(f).is_file()) else { return Ok(()) };
    let code = signals::run_interruptible(
        Command::new("bash")
            .args(["-c", install])
            .current_dir(path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null()),
    );
    interrupted()?;
    if code == 0 {
        ui::ok(format!("dependencies installed ({})", install.split(' ').next().unwrap_or(install)));
    } else {
        ui::warn(format!("could not install the dependencies: do it with '{install}'"));
    }
    Ok(())
}

/// Starts from the main checkout's file: it is ignored by git, so the
/// worktree never gets it, and the template's variables alone leave the
/// workspace without the keys the app needs. The template wins where both
/// define a variable: ports and databases are per slot.
fn write_env(config: &super::Config, repo: &Path, path: &Path, slot: &Slot, repo_name: &str) {
    let key_re = crate::regex!(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=");
    let key_of = |l: &str| key_re.captures(l).map(|c| c[1].to_string());
    let tmpl: Vec<(String, String)> =
        config.env_template.iter().map(|(k, v)| (k.clone(), slot.fill(&files::value_text(v)))).collect();
    let base = repo.join(&config.env_file);
    let lines: Vec<String> = if !base.is_file() {
        vec![]
    } else {
        match files::read_if_exists(&base) {
            Ok(t) => t.split('\n').map(String::from).collect(),
            Err(e) => {
                ui::warn(format!("{e} — the workspace gets only the per-slot variables, not the app's keys"));
                vec![]
            }
        }
    };
    let mut seen = vec![];
    let mut out: Vec<String> = lines
        .iter()
        .map(|l| match key_of(l) {
            Some(k) => {
                seen.push(k.clone());
                match tmpl.iter().find(|(tk, _)| *tk == k) {
                    Some((_, v)) => format!("{k}={v}"),
                    None => l.clone(),
                }
            }
            None => l.clone(),
        })
        .collect();
    while out.last().is_some_and(|l| l.is_empty()) {
        out.pop();
    }
    for (k, v) in &tmpl {
        if !seen.contains(k) {
            out.push(format!("{k}={v}"));
        }
    }
    let file = path.join(&config.env_file);
    if let Err(e) = files::write_atomic(&file, &(out.join("\n") + "\n"), Some(0o600)) {
        ui::warn(format!("cannot write {}: {e} — the workspace has no environment", file.display()));
    }
    let have: Vec<String> = out.iter().filter_map(|l| key_of(l)).collect();
    let example = path.join(".env.example");
    let mut missing: Vec<String> = vec![];
    for k in files::read_or_empty(&example).split('\n').filter_map(key_of) {
        if !have.contains(&k) && !missing.contains(&k) {
            missing.push(k);
        }
    }
    if !lines.is_empty() {
        ui::ok(format!(
            "{} from {repo_name}'s, with slot {} (ports from {})",
            config.env_file, slot.number, slot.first_port
        ));
    } else {
        ui::ok(format!("{} with slot {} (ports from {})", config.env_file, slot.number, slot.first_port));
    }
    if !missing.is_empty() {
        ui::warn(format!("{} lacks what .env.example asks for: {}", config.env_file, missing.join(" ")));
    }
}

/// Resume on this machine a task started on another. The record already
/// arrived with `crux sync`; a workspace is opened, in each repo it declares,
/// on the same branch brought from the remote, and it joins the task.
pub fn resume(argv: &[String]) -> Res {
    let Some(task) = argv.first().filter(|t| !t.is_empty()).cloned() else {
        die!("usage: crux workspace resume <task> [--project <project>]")
    };
    let mut project_arg = String::new();
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--project" => project_arg = p.value(),
            other => die!("unknown option: {other}"),
        }
    }
    if !project::valid_name(&task) {
        die!("invalid task name: '{task}'");
    }
    let dir = env::tasks_dir();
    let candidates: Vec<PathBuf> = project::subdirs(&dir)
        .into_iter()
        .filter(|p| project_arg.is_empty() || *p == project_arg)
        .map(|p| dir.join(p).join(format!("{task}.md")))
        .filter(|f| f.is_file())
        .collect();
    if candidates.is_empty() {
        ui::err(format!("there is no open task '{task}' on this machine"));
        ui::info("if it was opened on another, pull the tasks first: crux sync");
        return exit(1);
    }
    if candidates.len() > 1 {
        ui::err(format!("there is a task '{task}' in several projects:"));
        for f in &candidates {
            ui::info(files::name(f.parent().unwrap()));
        }
        die!("choose with --project <project>");
    }
    let record_file = candidates[0].clone();
    let project_name = files::name(record_file.parent().unwrap());
    let doc = match record::read(&record_file) {
        Ok(d) => d,
        Err(e) => die!("could not read the record {}: {e}", record_file.display()),
    };
    let repos = doc.list("repos");
    if repos.is_empty() {
        die!("the task '{task}' declares no repo: open it with crux workspace new");
    }
    let branches: Vec<(String, String)> = doc
        .list("branches")
        .iter()
        .filter_map(|e| e.split_once('=').map(|(a, b)| (a.to_string(), b.split('=').next().unwrap_or("").to_string())))
        .collect();
    let workspaces = doc.list("workspaces");
    let root = env::projects_root();
    let (mut done, mut opened) = (0, vec![]);
    for (idx, repo_name) in repos.iter().enumerate() {
        let mut dir_repo = root.join(&project_name).join(repo_name);
        if !dir_repo.join(".git").is_dir() {
            dir_repo = root.join(repo_name);
        }
        if !dir_repo.join(".git").is_dir() {
            ui::err(format!("{repo_name} is not on this machine"));
            ui::info(format!("bring it with: crux clone {project_name}"));
            continue;
        }
        let mut ws_name = workspaces.get(idx).cloned().unwrap_or_default();
        if ws_name.is_empty() {
            ws_name = if repos.len() > 1 { format!("{task}-{repo_name}") } else { task.clone() };
        }
        // A task registered before the branch was noted: the pattern one.
        let mut branch = branches.iter().find(|(r, _)| r == repo_name).map(|(_, b)| b.clone()).unwrap_or_default();
        if branch.is_empty() {
            branch = format!("ws/{ws_name}");
        }
        if let Some(w) = registry::find(&ws_name).filter(|w| Path::new(&w.path).exists()) {
            ui::ok(format!("{repo_name}: the workspace is already here — {}", w.path));
            opened.push(PathBuf::from(w.path));
            done += 1;
            continue;
        }
        git::run(&dir_repo, &["fetch", "-q", "origin", &format!("+refs/heads/{branch}:refs/remotes/origin/{branch}")]);
        // A branch retired when going into waiting is not missing: a new one
        // is opened from the main branch, because what it had was merged.
        let retired = record::read(&record_file).ok().and_then(|d| {
            d.get("retired")
                .map(record::Meta::list)
                .unwrap_or_default()
                .into_iter()
                .find_map(|e| e.split_once('=').filter(|(r, _)| r == repo_name).map(|(_, b)| b.to_string()))
        });
        let args = |branch: String, base: String| NewArgs {
            name: ws_name.clone(),
            repo: dir_repo.clone(),
            base,
            branch,
            force: false,
            task: task.clone(),
            goal: String::new(),
            defer_cd: true,
        };
        if let Some(retired_branch) = retired {
            if create(args(retired_branch, project::main_branch(&dir_repo))).is_ok() {
                let _ = record::edit(&record_file, true, |d| {
                    record::reopen_branch(d, repo_name);
                    Ok(())
                });
                opened.extend(workspace_path(&ws_name));
                done += 1;
            }
            continue;
        }
        if !git::has_ref(&dir_repo, &format!("refs/heads/{branch}"))
            && !git::has_ref(&dir_repo, &format!("refs/remotes/origin/{branch}"))
        {
            ui::err(format!("{repo_name}: the branch {branch} is neither here nor on the remote"));
            ui::info("on the other machine: crux sync --leave tells you what is left to push");
            continue;
        }
        if create(args(branch, String::new())).is_ok() {
            opened.extend(workspace_path(&ws_name));
            done += 1;
        }
    }
    if done == 0 {
        return exit(1);
    }
    // Resuming it means the answer arrived: it stops waiting.
    let mut cleared = false;
    let _ = record::edit(&record_file, true, |d| {
        cleared = record::clear_waiting(d);
        Ok(())
    });
    if cleared {
        ui::ok("the task no longer waits for an answer");
    }
    println!();
    let s = record::summary(&record::read(&record_file).unwrap_or_default());
    ui::ok(format!(
        "task '{task}' resumed · {}{}",
        s.status,
        if s.steps.is_empty() { String::new() } else { format!(" · steps {}", s.steps) }
    ));
    if !s.next.is_empty() {
        ui::info(format!("next: {}", s.next));
    }
    ui::info(format!("record: {}", record_file.display()));
    for p in opened {
        ui::info(format!("cd {}", p.display()));
    }
    Ok(())
}

/// A hand-made worktree does not exist for crux: it appears in no list and
/// `gc --include-disk` would treat it as garbage.
pub fn adopt(argv: &[String]) -> Res {
    let Some(given) = argv.first().filter(|p| !p.is_empty()).cloned() else {
        die!("usage: crux workspace adopt <path> [--task <task>]")
    };
    let mut task = String::new();
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--task" => task = p.value(),
            other => die!("unknown option: {other}"),
        }
    }
    let Some(path) = project::resolve_dir(Path::new(&given)) else { die!("{given} does not exist") };
    if !git::is_worktree(&path) {
        die!("{} is not a git worktree", path.display());
    }
    let base = files::name(&path);
    let Some((_, name)) = base.split_once("-ws-") else {
        die!("the name does not follow the pattern <repo>-ws-<name>: {base}")
    };
    let name = name.to_string();
    let repo = project::normalize(&git::main_repo(&path).unwrap_or_default());
    let branch = git::out(&path, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    if !project::valid_name(&name) {
        die!("invalid workspace name: '{name}'");
    }
    let task = if task.is_empty() { name.clone() } else { task };
    let project_name = crate::task::project_name_for(&repo);
    if let Err(e) = registry::init() {
        die!("cannot prepare the registry: {e}");
    }
    let guard = lock()?;
    let list = registry::read().unwrap_or_default();
    if list.iter().any(|w| w.name == name) {
        eprintln!("there is already a workspace called {name}");
        return exit(1);
    }
    if list.iter().any(|w| Path::new(&w.path) == path) {
        eprintln!("that worktree is already registered");
        return exit(1);
    }
    let repo_name = files::name(&repo);
    let config = load_config(project::find_docs_repo(&repo).as_deref(), &repo_name)?;
    let slot = free_slot(&list, config.port_base, config.per_slot).unwrap_or(0);
    let port0 = config.port_base + slot * config.per_slot;
    let entry = registry::Workspace {
        name: name.clone(),
        slot,
        repo: repo.to_string_lossy().into_owned(),
        path: path.to_string_lossy().into_owned(),
        branch: branch.clone(),
        ports: (port0, port0 + config.per_slot - 1),
        task: task.clone(),
        project: project_name.clone(),
        extra: Default::default(),
    };
    if let Err(e) = registry::update(|l| l.push(entry)) {
        die!("{e}");
    }
    drop(guard);
    let record_file = env::tasks_dir().join(&project_name).join(format!("{task}.md"));
    let ensured = if record_file.exists() {
        record::edit(&record_file, true, |d| {
            record::join(d, &repo_name, &name);
            Ok(())
        })
    } else {
        let mut d = record::create(&task, &project_name, &repo_name, &name);
        record::write(&record_file, &mut d, true)
    };
    if let Err(e) = ensured {
        ui::warn(format!("could not write the task record: {e}"));
    }
    ui::ok(format!("'{name}' adopted ({branch}, slot {slot})"));
    ui::info(format!("task '{task}': {}", record_file.display()));
    Ok(())
}
