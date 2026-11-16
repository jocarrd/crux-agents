//! crux scope — the work scopes of this machine (ADR-025).
//!
//!   crux scope                      the scopes and the one this folder is in
//!   crux scope show [<name>]        what a scope declares
//!   crux scope check                whether the scopes can be used, and why not
//!   crux scope of <path>            the scope a path belongs to
//!   crux scope map                  each scope and its projects, by name only
//!   crux scope enter <name> | --project <p>
//!                                   the context a session gets when it enters
//!   crux scope open <name> | --project <p> [--task <t>] [--prompt <text>]
//!                                   how to open a session there
//!   crux scope move <project> <scope>
//!                                   moves a project, with its tasks, to another scope
//!   crux scope apply                writes what each scope needs on this machine:
//!                                   the profile, git identity, ssh keys, sandbox

use crate::args::Parser;
use crate::error::Res;
use crate::scope::{self, context_text, map_text, Scope, Scopes};
use crate::{die, env, person, project, ui};
use std::path::{Path, PathBuf};

fn loaded() -> Result<Scopes, crate::error::Exit> {
    scope::load().map_err(|e| {
        ui::err(format!("the scopes cannot be used: {e}"));
        crate::error::Exit(1)
    })
}

fn cwd() -> PathBuf {
    std::env::current_dir().unwrap_or_default()
}

fn list(all: &Scopes) -> Res {
    if !all.declared {
        ui::info(format!("no scopes declared: one root, {}", all.list[0].root.display()));
        ui::info(format!("to declare one: {}/<name>/config with ROOT=\"...\"", scope::dir().display()));
        return Ok(());
    }
    let here = all.current(&cwd()).ok().flatten().map(|s| s.name.clone());
    for s in &all.list {
        let mark = if here.as_deref() == Some(s.name.as_str()) { "*" } else { " " };
        let primary = if s.primary { " (primary)" } else { "" };
        println!("{mark} {}{primary}  {}", s.name, s.root.display());
    }
    if here.is_none() {
        ui::info("this folder is in no scope: a session here starts at the front desk");
    }
    Ok(())
}

fn show(all: &Scopes, name: Option<&str>) -> Res {
    let s = match name {
        Some(n) => match all.by_name(n) {
            Some(s) => s,
            None => die!("no scope '{n}'"),
        },
        None => match all.current(&cwd()) {
            Ok(Some(s)) => s,
            Ok(None) => die!("this folder is in no scope: crux scope show <name>"),
            Err(e) => die!("{e}"),
        },
    };
    let opt = |v: &Option<String>| v.clone().unwrap_or_else(|| "-".into());
    println!("scope      {}{}", s.name, if s.primary { " (primary)" } else { "" });
    println!("root       {}", s.root.display());
    println!("remote     {}", opt(&s.remote));
    println!("owners     {}", if s.owners.is_empty() { "-".into() } else { s.owners.join(" ") });
    println!("git        {} <{}>", opt(&s.git_name), opt(&s.git_email));
    println!("gh         {}", s.gh_config_dir.as_ref().map_or("-".into(), |d| d.display().to_string()));
    println!("person     {}", s.person.as_str());
    println!("enforce    {}", if s.enforce == scope::Enforce::Sandbox { "sandbox" } else { "guard" });
    let secrets: Vec<String> = s.secrets.iter().map(|p| p.display().to_string()).collect();
    println!("secrets    {}", if secrets.is_empty() { "-".into() } else { secrets.join(" ") });
    println!("mcp deny   {}", if s.mcp_deny.is_empty() { "-".into() } else { s.mcp_deny.join(" ") });
    println!("browser    {}", s.browser_profile.as_ref().map_or("-".into(), |p| p.display().to_string()));
    println!("tasks      {}", s.tasks_dir().display());
    Ok(())
}

/// What is wrong and what only deserves a warning. Exit 1 on the former.
fn check() -> Res {
    let all = match scope::load() {
        Ok(a) => a,
        Err(e) => {
            for l in e.lines() {
                ui::err(l);
            }
            return Err(crate::error::Exit(1));
        }
    };
    if !all.declared {
        ui::ok("no scopes declared: crux works with one root, as always");
        return Ok(());
    }
    for s in &all.list {
        if !s.root.is_dir() {
            ui::warn(format!("scope '{}': its root does not exist yet: {}", s.name, s.root.display()));
        }
    }
    if let Some(d) = env::declared_projects_root() {
        let d = scope::expand(&d);
        if !all.list.iter().any(|s| scope::inside(&scope::real_lenient(&d), &s.real_root)) {
            ui::warn(format!(
                "{} points to {}, which is in no scope: with scopes declared it is not used",
                crate::names::vars::PROJECTS_DIR,
                d.display()
            ));
        }
    }
    let mut wrong = 0;
    for s in &all.list {
        for (repo, warn) in placement(&all, s) {
            if warn {
                ui::warn(repo);
            } else {
                wrong += 1;
                ui::err(repo);
            }
        }
    }
    if wrong > 0 {
        return Err(crate::error::Exit(1));
    }
    if all.list.len() > 1 && all.unpinned_default().ok().flatten().is_none() {
        ui::info(format!(
            "sessions opened outside every root start at the front desk ({} names a scope instead)",
            crate::names::vars::UNPINNED_SESSIONS
        ));
    }
    ui::ok(format!("{} usable", ui::count(all.list.len(), "scope", "scopes")));
    Ok(())
}

fn github_owner(url: &str) -> Option<String> {
    crate::regex!(r"github\.com[:/]([A-Za-z0-9_.-]+)/").captures(url).map(|c| c[1].to_string())
}

/// What lives in one scope and belongs to another: a repo whose remote is an
/// owner another scope declares is in the wrong root (an error: move it), and
/// recent commits with another scope's email were signed with the wrong
/// identity (a warning: history is not rewritten).
fn placement(all: &Scopes, s: &Scope) -> Vec<(String, bool)> {
    let mut out = vec![];
    let others: Vec<&Scope> = all.list.iter().filter(|o| o.name != s.name).collect();
    for repo in repos_under(&s.root) {
        let shown = repo.strip_prefix(&s.root).unwrap_or(&repo).display().to_string();
        if let Some(owner) = crate::git::remote_url(&repo, crate::names::git::REMOTE).and_then(|u| github_owner(&u)) {
            if let Some(o) = others.iter().find(|o| o.owners.iter().any(|x| x.eq_ignore_ascii_case(&owner))) {
                let project = shown.split('/').next().unwrap_or(&shown).to_string();
                out.push((
                    format!(
                        "{shown} (scope '{}') pushes to '{owner}', an owner of scope '{}': crux scope move {project} {}",
                        s.name, o.name, o.name
                    ),
                    false,
                ));
            }
        }
        let emails: Vec<(&str, &str)> =
            others.iter().filter_map(|o| o.git_email.as_deref().map(|e| (e, o.name.as_str()))).collect();
        if emails.is_empty() {
            continue;
        }
        let log = crate::git::out(&repo, &["log", "-n", "30", "--format=%ae"]).unwrap_or_default();
        for (email, other) in emails {
            let n = log.lines().filter(|l| l.eq_ignore_ascii_case(email)).count();
            if n > 0 {
                out.push((
                    format!(
                        "{shown} (scope '{}'): {} with {email}, the email of scope '{other}' — run crux scope apply",
                        s.name,
                        ui::count(n, "recent commit", "recent commits")
                    ),
                    true,
                ));
            }
        }
    }
    out
}

fn resolve<'a>(all: &'a Scopes, name: Option<&str>, project_name: Option<&str>) -> Result<&'a Scope, String> {
    match (name, project_name) {
        (Some(n), _) => all.by_name(n).ok_or_else(|| format!("no scope '{n}'")),
        (None, Some(p)) => all.scope_of_project(p),
        (None, None) => Err("which scope: <name> or --project <name>".into()),
    }
}

fn enter(all: &Scopes, argv: &[String]) -> Res {
    let (mut name, mut proj) = (None, None);
    let mut p = Parser::new(argv);
    while let Some(a) = p.next() {
        match a {
            "--project" => proj = p.value_opt(),
            s if !s.starts_with('-') && name.is_none() => name = Some(s.to_string()),
            other => die!("unknown option: {other}"),
        }
    }
    let s = match resolve(all, name.as_deref(), proj.as_deref()) {
        Ok(s) => s,
        Err(e) => die!("{e}"),
    };
    let project = proj.filter(|p| scope::project_rules(s, p).isolated);
    println!("{}", context_text(all, &scope::Place { scope: s.name.clone(), project }));
    Ok(())
}

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Where a session for that scope or task should start: the task's live
/// workspace if it has one in that scope, the project's folder, or the root.
fn start_dir(s: &Scope, proj: Option<&str>, task: Option<&str>) -> PathBuf {
    if let Some(t) = task {
        if let Some(w) = crate::registry::read()
            .unwrap_or_default()
            .into_iter()
            .find(|w| w.name == t && Path::new(&w.path).is_dir() && s.contains(Path::new(&w.path)))
        {
            return PathBuf::from(w.path);
        }
    }
    match proj.map(|p| s.root.join(p)).filter(|d| d.is_dir()) {
        Some(d) => d,
        None => s.root.clone(),
    }
}

fn open(all: &Scopes, argv: &[String]) -> Res {
    let (mut name, mut proj, mut task, mut prompt) = (None, None, None, None);
    let mut p = Parser::new(argv);
    while let Some(a) = p.next() {
        match a {
            "--project" => proj = p.value_opt(),
            "--task" => task = p.value_opt(),
            "--prompt" => prompt = p.value_opt(),
            s if !s.starts_with('-') && name.is_none() => name = Some(s.to_string()),
            other => die!("unknown option: {other}"),
        }
    }
    let s = match resolve(all, name.as_deref(), proj.as_deref()) {
        Ok(s) => s,
        Err(e) => die!("{e}"),
    };
    let dir = start_dir(s, proj.as_deref(), task.as_deref());
    let key = crate::names::vars::AGENT;
    let agent =
        env::var(key).or_else(|| env::config_value_in(&env::config_file(), key)).unwrap_or_else(|| "claude".into());
    let mut cmd = format!("cd {} && {agent}", quote(&dir.to_string_lossy()));
    if let Some(t) = prompt.filter(|t| !t.is_empty()) {
        cmd.push(' ');
        cmd.push_str(&quote(&t));
    }
    ui::info(format!("a new session in scope '{}', from {}:", s.name, dir.display()));
    println!("{cmd}");
    Ok(())
}

// --- Applying the scopes to the machine ---------------------------------------
//
// Everything below is generated between markers, in files that are otherwise
// the person's: regenerated whole, the rest left as written (rule 4).

const BEGIN: &str = "# crux:scopes:begin";
const END: &str = "# crux:scopes:end";

fn git_config_file() -> PathBuf {
    env::var(crate::names::agents::GIT_CONFIG_GLOBAL).map_or_else(|| env::home().join(".gitconfig"), PathBuf::from)
}

fn ssh_config_file() -> PathBuf {
    env::var(crate::names::vars::SSH_CONFIG).map_or_else(|| env::home().join(".ssh/config"), PathBuf::from)
}

fn ssh_keys_dir(s: &Scope) -> PathBuf {
    env::home().join(".ssh").join(&s.name)
}

/// A scope's git identity, included only for repos under its root. macOS
/// folders ignore case, so the match does too there.
fn apply_git(all: &Scopes) -> Result<Vec<String>, String> {
    let mut block = vec![];
    let mut done = vec![];
    for s in &all.list {
        let Some(dir) = &s.dir else { continue };
        let mut body = String::new();
        if s.git_name.is_some() || s.git_email.is_some() {
            body.push_str("[user]\n");
            if let Some(n) = &s.git_name {
                body.push_str(&format!("\tname = {n}\n"));
            }
            if let Some(e) = &s.git_email {
                body.push_str(&format!("\temail = {e}\n"));
            }
        }
        if let Some(gh) = &s.gh_config_dir {
            // Quoted for the shell git hands the helper to: macOS folders
            // often carry spaces (`Application Support`).
            body.push_str(&format!(
                "[credential \"https://github.com\"]\n\thelper =\n\thelper = !{}='{}' gh auth git-credential\n",
                crate::names::agents::GH_CONFIG_DIR,
                gh.display().to_string().replace('\'', "'\\''")
            ));
        }
        if body.is_empty() {
            continue;
        }
        let file = dir.join("gitconfig");
        crate::files::write(
            &file,
            &format!(
                "# Generated by `crux scope apply` from {}; edit that.\n{body}",
                dir.join(scope::CONFIG_FILE).display()
            ),
        )?;
        let kind = if cfg!(target_os = "macos") { "gitdir/i" } else { "gitdir" };
        block.push(format!("[includeIf \"{kind}:{}/\"]\n\tpath = {}", s.real_root.display(), file.display()));
        done.push(s.name.clone());
    }
    let text = if block.is_empty() { String::new() } else { format!("{BEGIN}\n{}\n{END}", block.join("\n")) };
    crate::template::replace_or_append_block(&git_config_file(), BEGIN, END, &text).map_err(|e| e.to_string())?;
    Ok(done)
}

/// One block per scope with a keys folder: a key named after its host,
/// offered only when ssh runs from inside the scope. Written at the top of the
/// file, before any `Host *` that would otherwise answer first.
fn apply_ssh(all: &Scopes) -> Result<Vec<String>, String> {
    let crux = env::crux_home().map(|h| h.join("bin/crux")).unwrap_or_else(|| PathBuf::from("crux"));
    let mut block = vec![];
    let mut done = vec![];
    for s in all.list.iter().filter(|s| ssh_keys_dir(s).is_dir()) {
        block.push(format!(
            "Match exec \"'{}' __fn scope_of_cwd {}\"\n  IdentityFile {}/%h\n  IdentitiesOnly yes",
            crux.display(),
            s.name,
            ssh_keys_dir(s).display()
        ));
        done.push(s.name.clone());
    }
    let text = if block.is_empty() { String::new() } else { format!("{BEGIN}\n{}\n{END}", block.join("\n")) };
    let file = ssh_config_file();
    if text.is_empty() && !file.exists() {
        return Ok(done);
    }
    crate::template::write_marked_block(&file, BEGIN, END, &text).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600));
    }
    Ok(done)
}

/// The repos under a root: projects' repos, workspaces and loose repos.
fn repos_under(root: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    for a in project::subdirs(root) {
        let d = root.join(&a);
        if d.join(".git").exists() {
            out.push(d.clone());
            continue;
        }
        for b in project::subdirs(&d) {
            let r = d.join(b);
            if r.join(".git").exists() {
                out.push(r);
            }
        }
    }
    out
}

/// The agent settings a repo of a scope gets: the sandbox with every other
/// scope out of reach when the scope asks for it, and the gh account when it
/// has one of its own. Merged into what the file already holds.
/// Whether a sandbox block is the one `apply` writes: it always denies writing
/// the scopes' folder, which nobody else would think to name.
fn sandbox_is_ours(v: &serde_json::Value) -> bool {
    let guarded = scope::dir().display().to_string();
    v.pointer("/sandbox/filesystem/denyWrite")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|a| a.iter().any(|x| x.as_str() == Some(guarded.as_str())))
}

/// What the sandbox denies a repo of scope `s`: everything `scope-guard`
/// stops, so a shell command the guard's parsing misses still hits a wall.
fn sandbox_denied(all: &Scopes, s: &Scope, repo: &Path) -> Vec<String> {
    let mut deny: Vec<PathBuf> = vec![env::claude_transcripts_dir()];
    for o in all.list.iter().filter(|o| o.name != s.name) {
        deny.push(o.real_root.clone());
        deny.extend(o.secret_paths());
        deny.push(ssh_keys_dir(o));
        deny.extend(o.dir.clone());
        if o.primary {
            deny.push(env::machine_tasks_dir());
        }
    }
    if s.person != scope::Person::Full {
        deny.extend(person::dir());
    }
    // Inside its own scope: the projects its isolation leaves out.
    let own = scope::project_of_path(s, repo);
    let own_isolated = own.as_deref().is_some_and(|p| scope::project_rules(s, p).isolated);
    for p in scope::projects(s) {
        let closed =
            if own_isolated { own.as_deref() != Some(p.as_str()) } else { scope::project_rules(s, &p).isolated };
        if closed && own.as_deref() != Some(p.as_str()) {
            deny.push(s.root.join(p));
        }
    }
    deny.iter().map(|p| p.display().to_string()).collect()
}

/// The agent settings a repo of a scope gets: the sandbox with every other
/// scope out of reach when the scope asks for it, and the gh account when it
/// has one of its own. Merged into what the file already holds, and taken out
/// again when the scope no longer asks for it.
pub fn apply_repo(all: &Scopes, repo: &Path) -> Result<bool, String> {
    let s = all.of_path(repo).filter(|_| all.declared);
    let sandbox = s.filter(|s| s.enforce == scope::Enforce::Sandbox);
    let gh = s.and_then(|s| s.gh_config_dir.clone());
    let file = repo.join(crate::names::CLAUDE_LOCAL_SETTINGS);
    if !file.exists() && sandbox.is_none() && gh.is_none() {
        return Ok(false);
    }
    let mut v = if file.exists() { crate::files::read_json(&file)? } else { serde_json::json!({}) };
    let before = v.clone();
    let ours = sandbox_is_ours(&v);
    let obj = v.as_object_mut().ok_or_else(|| format!("{}: not a JSON object", file.display()))?;
    match sandbox {
        Some(s) => {
            obj.insert(
                "sandbox".into(),
                serde_json::json!({
                    "enabled": true,
                    "allowUnsandboxedCommands": false,
                    "filesystem": {
                        "denyRead": sandbox_denied(all, s, repo),
                        "denyWrite": [scope::dir().display().to_string(), scope::pins_dir().display().to_string()],
                    },
                }),
            );
        }
        None if ours => {
            obj.shift_remove("sandbox");
        }
        None => {}
    }
    let key = crate::names::agents::GH_CONFIG_DIR;
    match &gh {
        Some(dir) => {
            let env_obj = obj.entry("env").or_insert_with(|| serde_json::json!({}));
            if let Some(e) = env_obj.as_object_mut() {
                e.insert(key.into(), serde_json::json!(dir.display().to_string()));
            }
        }
        None => {
            let declared: Vec<String> =
                all.list.iter().filter_map(|o| o.gh_config_dir.as_ref().map(|d| d.display().to_string())).collect();
            if let Some(e) = obj.get_mut("env").and_then(serde_json::Value::as_object_mut) {
                if e.get(key).and_then(serde_json::Value::as_str).is_some_and(|d| declared.iter().any(|x| x == d)) {
                    e.shift_remove(key);
                }
            }
        }
    }
    if v == before {
        return Ok(false);
    }
    if let Some(d) = file.parent() {
        std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
    }
    crate::files::write(&file, &crate::files::json_pretty(&v))?;
    crate::git::exclude(repo, &[crate::names::CLAUDE_LOCAL_SETTINGS])?;
    Ok(true)
}

/// Without scopes, what apply generated earlier is taken out: the blocks in
/// git's and ssh's configs and the sandbox it wrote into repos.
fn unapply(all: &Scopes) -> Res {
    // Only a file that holds the block is rewritten: one that never had it is
    // left byte for byte as it was.
    for (what, file) in [("git", git_config_file()), ("ssh", ssh_config_file())] {
        if crate::files::read_optional(&file).is_some_and(|t| t.contains(BEGIN)) {
            if let Err(e) = crate::template::write_marked_block(&file, BEGIN, END, "") {
                die!("{what}: {e}");
            }
        }
    }
    let mut n = 0;
    for root in env::all_projects_roots() {
        for r in repos_under(&root) {
            match apply_repo(all, &r) {
                Ok(true) => n += 1,
                Ok(false) => {}
                Err(e) => ui::warn(format!("{}: {e}", r.display())),
            }
        }
    }
    ui::ok(format!(
        "no scopes declared: removed what scopes had written (git, ssh{})",
        if n > 0 { format!(", {}", ui::count(n, "repo", "repos")) } else { String::new() }
    ));
    Ok(())
}

fn apply(all: &Scopes) -> Res {
    if !all.declared {
        return unapply(all);
    }
    if person::dir().is_some() {
        crate::cmd::profile::link()?;
    }
    match apply_git(all) {
        Ok(d) if !d.is_empty() => ui::ok(format!("git: identity per scope for {}", d.join(", "))),
        Ok(_) => ui::info("git: no scope declares an identity"),
        Err(e) => die!("git: {e}"),
    }
    match apply_ssh(all) {
        Ok(d) if !d.is_empty() => ui::ok(format!("ssh: keys per scope for {}", d.join(", "))),
        Ok(_) => ui::info("ssh: no scope has a keys folder (~/.ssh/<scope>/<host>)"),
        Err(e) => die!("ssh: {e}"),
    }
    let mut n = 0;
    for s in &all.list {
        for r in repos_under(&s.root) {
            match apply_repo(all, &r) {
                Ok(true) => n += 1,
                Ok(false) => {}
                Err(e) => ui::warn(format!("{}: {e}", r.display())),
            }
        }
    }
    if n > 0 {
        ui::ok(format!("agent settings in {}", ui::count(n, "repo", "repos")));
    }
    Ok(())
}

/// A project that needs another account goes to another scope: its folder
/// and its tasks move, and the target scope's identity applies from then on.
/// Refused while it has workspaces: a worktree moved halfway is worse than
/// one not moved.
fn move_project(all: &Scopes, argv: &[String]) -> Res {
    let (Some(name), Some(to)) = (argv.first(), argv.get(1)) else { die!("usage: crux scope move <project> <scope>") };
    let from = match all.scope_of_project(name) {
        Ok(s) => s,
        Err(e) => die!("{e}"),
    };
    let Some(target) = all.by_name(to) else { die!("no scope '{to}'") };
    if from.name == target.name {
        ui::ok(format!("'{name}' is already in scope '{to}'"));
        return Ok(());
    }
    let src = from.root.join(name);
    let dst = target.root.join(name);
    if dst.exists() {
        die!("{} already exists", dst.display());
    }
    let open: Vec<String> = crate::registry::read()
        .unwrap_or_default()
        .into_iter()
        .filter(|w| {
            Path::new(&w.path).starts_with(&from.root) && crate::task::project_name_for(Path::new(&w.path)) == *name
        })
        .map(|w| w.name)
        .collect();
    let siblings: Vec<String> =
        project::subdirs(&from.root).into_iter().filter(|d| d.starts_with(&format!("{name}-ws-"))).collect();
    if !open.is_empty() || !siblings.is_empty() {
        let mut names = open;
        names.extend(siblings);
        die!("'{name}' has workspaces open ({}): finish or remove them first", names.join(", "));
    }
    if let Err(e) = std::fs::create_dir_all(&target.root).and_then(|_| std::fs::rename(&src, &dst)) {
        die!(
            "cannot move {} to {}: {e} — on another disk, move it by hand and run this again",
            src.display(),
            dst.display()
        );
    }
    ui::ok(format!("{} → {}", src.display(), dst.display()));
    let (t_src, t_dst) = (from.tasks_dir().join(name), target.tasks_dir().join(name));
    if t_src.is_dir() {
        if t_dst.exists() {
            ui::warn(format!("tasks left in {}: {} already exists", t_src.display(), t_dst.display()));
        } else if let Err(e) = std::fs::create_dir_all(target.tasks_dir()).and_then(|_| std::fs::rename(&t_src, &t_dst))
        {
            ui::warn(format!("the tasks stay in {}: {e}", t_src.display()));
        } else {
            ui::ok(format!("its tasks → {}", t_dst.display()));
        }
    }
    let fresh = match scope::load_fresh() {
        Ok(a) => a,
        Err(e) => die!("{e}"),
    };
    for r in repos_under(&dst) {
        if let Err(e) = apply_repo(&fresh, &r) {
            ui::warn(format!("{}: {e}", r.display()));
        }
    }
    ui::info(format!(
        "its remote is still where it was: if '{to}' uses another account, move the repos there and update crux.json"
    ));
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let sub = argv.first().map(String::as_str).unwrap_or("");
    let rest = if argv.is_empty() { argv } else { &argv[1..] };
    if sub == "check" {
        return check();
    }
    let all = loaded()?;
    match sub {
        "" | "list" => list(&all),
        "show" => show(&all, rest.first().map(String::as_str)),
        "of" => {
            let Some(path) = rest.first() else { die!("usage: crux scope of <path>") };
            match all.of_path(Path::new(path)) {
                Some(s) => {
                    println!("{}", s.name);
                    Ok(())
                }
                None => Err(crate::error::Exit(1)),
            }
        }
        "map" => {
            println!("{}", map_text(&all));
            Ok(())
        }
        "enter" => enter(&all, rest),
        "open" => open(&all, rest),
        "apply" => apply(&all),
        "move" => move_project(&all, rest),
        other => die!("unknown subcommand: {other} — crux scope --help"),
    }
}
