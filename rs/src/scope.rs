//! Work scopes (ADR-025): who the work is for. A scope is a root folder with
//! its remote, the owners its projects live under, a git identity, the secrets
//! that belong to it, the connectors it may not use and how much of the
//! person's profile it sees.
//!
//! Without scopes declared there is one implicit scope built from the machine
//! config, and every path stays where it always was.

use crate::{env, files, project};
use std::path::{Path, PathBuf};

/// How much of the person's profile a scope or a project sees.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Person {
    None,
    Shared,
    Full,
}

impl Person {
    pub fn parse(s: &str) -> Option<Person> {
        match s {
            "full" => Some(Person::Full),
            "shared" => Some(Person::Shared),
            "none" => Some(Person::None),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Person::Full => "full",
            Person::Shared => "shared",
            Person::None => "none",
        }
    }
}

/// What enforces the boundary: the agent hook alone, or the agent's own
/// sandbox as well, so the operating system stops what a pattern misses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Enforce {
    Guard,
    Sandbox,
}

#[derive(Debug, Clone)]
pub struct Scope {
    pub name: String,
    /// As declared, for messages.
    pub root: PathBuf,
    /// Resolved, for comparing.
    pub real_root: PathBuf,
    pub remote: Option<String>,
    pub owners: Vec<String>,
    pub git_name: Option<String>,
    pub git_email: Option<String>,
    pub gh_config_dir: Option<PathBuf>,
    pub person: Person,
    pub secrets: Vec<PathBuf>,
    /// The browser profile the browser skill copies in this scope: its
    /// cookies are a secret of the scope like any key.
    pub browser_profile: Option<PathBuf>,
    pub mcp_deny: Vec<String>,
    pub enforce: Enforce,
    pub primary: bool,
    /// The scope's own folder; none for the implicit scope.
    pub dir: Option<PathBuf>,
}

impl Scope {
    pub fn contains(&self, path: &Path) -> bool {
        inside(&real_lenient(path), &self.real_root)
    }

    /// Where the tasks of this scope's projects live. The primary scope keeps
    /// the machine's, so declaring scopes on a machine in use moves nothing.
    pub fn tasks_dir(&self) -> PathBuf {
        match (&self.dir, self.primary) {
            (Some(d), false) => d.join("tasks"),
            _ => env::machine_tasks_dir(),
        }
    }

    /// Every path that is this scope's secret: what it declares, and its
    /// browser profile.
    pub fn secret_paths(&self) -> Vec<PathBuf> {
        self.secrets.iter().cloned().chain(self.browser_profile.clone()).collect()
    }

    pub fn owns_secret(&self, path: &Path) -> bool {
        let p = real_lenient(path);
        self.secret_paths().iter().any(|s| inside(&p, &real_lenient(s)))
    }
}

#[derive(Debug, Clone)]
pub struct Scopes {
    pub list: Vec<Scope>,
    /// False when the only scope is the implicit one.
    pub declared: bool,
}

pub const CONFIG_FILE: &str = "config";

pub fn dir() -> PathBuf {
    env::var(crate::names::vars::SCOPES_DIR).map_or_else(|| env::crux_dir().join("scopes"), PathBuf::from)
}

/// `~` and `$HOME` as the shell would expand them, in a value of the config.
pub fn expand(value: &str) -> PathBuf {
    let home = env::home().to_string_lossy().into_owned();
    let v = value.trim();
    let v = if v == "~" {
        home.clone()
    } else if let Some(rest) = v.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        v.replace("${HOME}", &home).replace("$HOME", &home)
    };
    PathBuf::from(v)
}

/// The resolved form of a path that may not exist yet: the longest prefix that
/// exists is resolved and the rest appended. A file about to be written still
/// belongs where its folder does.
pub fn real_lenient(path: &Path) -> PathBuf {
    let path = if path.is_absolute() {
        project::normalize(path)
    } else {
        project::normalize(&std::env::current_dir().unwrap_or_default().join(path))
    };
    let mut existing = path.clone();
    let mut rest = vec![];
    while !existing.exists() {
        match (existing.file_name().map(|n| n.to_os_string()), existing.parent()) {
            (Some(n), Some(parent)) => {
                rest.push(n);
                existing = parent.to_path_buf();
            }
            _ => return path,
        }
    }
    let mut out = project::real(&existing);
    for n in rest.into_iter().rev() {
        out.push(n);
    }
    out
}

/// Whether `path` is `root` or inside it. macOS volumes are case-insensitive
/// by default, so `~/desktop/acme` is the same folder as `~/Desktop/Acme`.
pub fn inside(path: &Path, root: &Path) -> bool {
    if cfg!(target_os = "macos") {
        let p = path.to_string_lossy().to_lowercase();
        let r = root.to_string_lossy().to_lowercase();
        let r = r.trim_end_matches('/');
        p == r || p.starts_with(&format!("{r}/"))
    } else {
        path.starts_with(root)
    }
}

fn words(v: Option<String>) -> Vec<String> {
    v.map(|s| s.split_whitespace().map(String::from).collect()).unwrap_or_default()
}

/// One scope from its folder. Every value it cannot make sense of is an error
/// with the file and the key: a typo in ENFORCE read as the default would
/// switch off what the person asked for.
pub fn parse(name: &str, folder: &Path) -> Result<Scope, String> {
    let file = folder.join(CONFIG_FILE);
    if !file.is_file() {
        return Err(format!("{}: missing", file.display()));
    }
    // Read once: the same rule as `env::config_value_in`, the last `KEY=`
    // line wins and quotes are dropped.
    let text = files::read_if_exists(&file)?;
    let get = |k: &str| {
        let prefix = format!("{k}=");
        text.lines()
            .rfind(|l| l.starts_with(&prefix))
            .map(|l| l[prefix.len()..].replace('"', ""))
            .filter(|v| !v.is_empty())
    };
    let where_ = |k: &str| format!("{} ({k})", file.display());
    let root = get("ROOT").ok_or_else(|| format!("{}: ROOT is required", file.display()))?;
    let root = expand(&root);
    if !root.is_absolute() {
        return Err(format!("{}: must be an absolute path", where_("ROOT")));
    }
    let person = match get("PERSON") {
        None => None,
        Some(v) => {
            Some(Person::parse(&v).ok_or_else(|| format!("{}: '{v}' is not full, shared or none", where_("PERSON")))?)
        }
    };
    let enforce = match get("ENFORCE").as_deref() {
        None | Some("guard") => Enforce::Guard,
        Some("sandbox") => Enforce::Sandbox,
        Some(v) => return Err(format!("{}: '{v}' is not guard or sandbox", where_("ENFORCE"))),
    };
    let primary = match get("PRIMARY").as_deref() {
        None | Some("false") => false,
        Some("true") => true,
        Some(v) => return Err(format!("{}: '{v}' is not true or false", where_("PRIMARY"))),
    };
    // A relative path would be resolved against whatever folder each command
    // runs in, and name a different place every time.
    let absolute = |key: &str, values: Vec<PathBuf>| -> Result<Vec<PathBuf>, String> {
        match values.iter().find(|p| !p.is_absolute()) {
            Some(p) => Err(format!("{}: '{}' must be an absolute path", where_(key), p.display())),
            None => Ok(values),
        }
    };
    let secrets = absolute("SECRETS", words(get("SECRETS")).iter().map(|s| expand(s)).collect())?;
    let browser_profile =
        absolute("BROWSER_PROFILE", get("BROWSER_PROFILE").map(|v| expand(&v)).into_iter().collect())?
            .into_iter()
            .next();
    let gh_config_dir =
        absolute("GH_CONFIG_DIR", get("GH_CONFIG_DIR").map(|v| expand(&v)).into_iter().collect())?.into_iter().next();
    Ok(Scope {
        name: name.to_string(),
        real_root: real_lenient(&root),
        root,
        remote: get("REMOTE"),
        owners: words(get("OWNERS")),
        git_name: get("GIT_NAME"),
        git_email: get("GIT_EMAIL"),
        gh_config_dir,
        // The primary scope is the person's own: it sees the whole profile
        // unless it says otherwise. Any other sees what is shared.
        person: person.unwrap_or(if primary { Person::Full } else { Person::Shared }),
        secrets,
        browser_profile,
        mcp_deny: words(get("MCP_DENY")),
        enforce,
        primary,
        dir: Some(folder.to_path_buf()),
    })
}

/// The scope a machine without scopes has always had.
pub fn implicit() -> Scope {
    let root = env::implicit_projects_root();
    Scope {
        name: "default".into(),
        real_root: real_lenient(&root),
        root,
        remote: env::config_value_in(&env::config_file_redirectable(), crate::names::vars::REMOTE),
        owners: vec![],
        git_name: None,
        git_email: None,
        gh_config_dir: None,
        person: Person::Full,
        secrets: vec![],
        browser_profile: None,
        mcp_deny: vec![],
        enforce: Enforce::Guard,
        primary: true,
        dir: None,
    }
}

/// Everything that makes two scopes ambiguous, or one unusable. Each problem
/// stops crux: falling back to the implicit scope would switch isolation off
/// without a word (rule 5).
pub fn problems(list: &[Scope]) -> Vec<String> {
    let mut out: Vec<String> = list
        .iter()
        .filter(|s| !project::valid_name(&s.name))
        .map(|s| format!("scope '{}': not a valid name (letters, digits, - and _)", s.name))
        .collect();
    for (i, a) in list.iter().enumerate() {
        for b in &list[i + 1..] {
            out.extend(clashes(a, b));
        }
    }
    out.extend(primary_problem(list));
    for s in list {
        for secret in &s.secret_paths() {
            for other in list.iter().filter(|o| o.name != s.name && o.contains(secret)) {
                out.push(format!(
                    "a secret of '{}' is inside the root of '{}': {}",
                    s.name,
                    other.name,
                    secret.display()
                ));
            }
        }
    }
    out
}

/// What two scopes cannot share: a folder, an owner, a browser profile.
fn clashes(a: &Scope, b: &Scope) -> Vec<String> {
    let mut out = vec![];
    if inside(&a.real_root, &b.real_root) || inside(&b.real_root, &a.real_root) {
        out.push(format!(
            "scopes '{}' and '{}' overlap: {} and {}",
            a.name,
            b.name,
            a.root.display(),
            b.root.display()
        ));
    }
    for o in a.owners.iter().filter(|o| b.owners.iter().any(|x| x.eq_ignore_ascii_case(o))) {
        out.push(format!("owner '{o}' is in two scopes: '{}' and '{}'", a.name, b.name));
    }
    if let (Some(x), Some(y)) = (&a.browser_profile, &b.browser_profile) {
        if real_lenient(x) == real_lenient(y) {
            out.push(format!("scopes '{}' and '{}' share one browser profile: {}", a.name, b.name, x.display()));
        }
    }
    out
}

/// Several scopes need exactly one that is the person's own.
fn primary_problem(list: &[Scope]) -> Option<String> {
    let primaries: Vec<&str> = list.iter().filter(|s| s.primary).map(|s| s.name.as_str()).collect();
    match (list.len() > 1, primaries.len()) {
        (true, 0) => Some("several scopes and none is PRIMARY=\"true\": the person's own one has to be named".into()),
        (true, n) if n > 1 => Some(format!("only one scope can be primary, and {n} are: {}", primaries.join(", "))),
        _ => None,
    }
}

/// The scopes of this machine. An error when one cannot be read or they
/// contradict each other.
pub fn load() -> Result<Scopes, String> {
    // The scopes do not change while one command or hook runs, and the guard
    // asks for them many times per tool call: read once per process and
    // folder. A command that changes them (`scope move`) reads `load_fresh`.
    static CACHE: std::sync::Mutex<Option<(PathBuf, Result<Scopes, String>)>> = std::sync::Mutex::new(None);
    let d = dir();
    let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((cached, r)) = cache.as_ref() {
        if *cached == d {
            return r.clone();
        }
    }
    let r = load_fresh();
    *cache = Some((d, r.clone()));
    r
}

/// The scopes as they are on disk now.
pub fn load_fresh() -> Result<Scopes, String> {
    let d = dir();
    let mut names = match std::fs::read_dir(&d) {
        Ok(entries) => entries
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect::<Vec<_>>(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => vec![],
        Err(e) => return Err(format!("cannot read {}: {e}", d.display())),
    };
    names.sort();
    if names.is_empty() {
        return Ok(Scopes { list: vec![implicit()], declared: false });
    }
    let mut list = vec![];
    for n in &names {
        list.push(parse(n, &d.join(n))?);
    }
    if list.len() == 1 {
        list[0].primary = true;
        if env::config_value_in(&d.join(&names[0]).join(CONFIG_FILE), "PERSON").is_none() {
            list[0].person = Person::Full;
        }
    }
    let p = problems(&list);
    if !p.is_empty() {
        return Err(p.join("\n"));
    }
    Ok(Scopes { list, declared: true })
}

/// The worktree's main repo, when `path` is inside a linked worktree: its
/// `.git` is a file that points into the main repo's git dir. Read, not asked
/// to git: this runs on every tool call.
fn main_repo_of_worktree(path: &Path) -> Option<PathBuf> {
    let mut probe = Some(path);
    while let Some(dir) = probe {
        let dot_git = dir.join(".git");
        if dot_git.is_file() {
            let text = files::read_optional(&dot_git)?;
            let gitdir = PathBuf::from(text.trim().strip_prefix("gitdir:")?.trim());
            let gitdir = if gitdir.is_absolute() { gitdir } else { dir.join(gitdir) };
            // <main>/.git/worktrees/<name> -> <main>
            let common = gitdir.parent()?.parent()?;
            return common.parent().map(Path::to_path_buf);
        }
        if dot_git.is_dir() {
            return None;
        }
        probe = dir.parent();
    }
    None
}

impl Scopes {
    pub fn primary(&self) -> &Scope {
        self.list.iter().find(|s| s.primary).unwrap_or(&self.list[0])
    }

    pub fn by_name(&self, name: &str) -> Option<&Scope> {
        self.list.iter().find(|s| s.name == name)
    }

    /// The scope a path belongs to, by where it lives. A worktree another tool
    /// made outside every root belongs where its repo does.
    pub fn of_path(&self, path: &Path) -> Option<&Scope> {
        let real = real_lenient(path);
        if let Some(s) = self.list.iter().find(|s| inside(&real, &s.real_root)) {
            return Some(s);
        }
        let main = main_repo_of_worktree(&real)?;
        let main = real_lenient(&main);
        self.list.iter().find(|s| inside(&main, &s.real_root))
    }

    /// The scope a command works in: the one it is told, the one its folder
    /// belongs to, the one sessions outside every root are pinned to, and with
    /// no scopes declared the implicit one. None at the front desk.
    pub fn current(&self, cwd: &Path) -> Result<Option<&Scope>, String> {
        if !self.declared {
            return Ok(Some(&self.list[0]));
        }
        if let Some(n) = env::var(crate::names::vars::SCOPE) {
            return self.by_name(&n).map(Some).ok_or_else(|| format!("{}: no scope '{n}'", crate::names::vars::SCOPE));
        }
        if let Some(s) = self.of_path(cwd) {
            return Ok(Some(s));
        }
        self.unpinned_default()
    }

    /// The scope named by CRUX_UNPINNED_SESSIONS, if any.
    pub fn unpinned_default(&self) -> Result<Option<&Scope>, String> {
        let key = crate::names::vars::UNPINNED_SESSIONS;
        match env::var(key).or_else(|| env::config_value_in(&env::config_file(), key)) {
            None => Ok(None),
            Some(n) => self.by_name(&n).map(Some).ok_or_else(|| format!("{key}: no scope '{n}'")),
        }
    }

    pub fn roots(&self) -> Vec<PathBuf> {
        self.list.iter().map(|s| s.root.clone()).collect()
    }
}

/// Loads the scopes, and on failure says why on stderr. For the places that
/// cannot return an error but must not carry on as if nothing happened: they
/// get the implicit scope only when there are no scopes declared at all.
pub fn load_or_report() -> Option<Scopes> {
    match load() {
        Ok(s) => Some(s),
        Err(e) => {
            crate::ui::err_stderr(format!("the scopes cannot be used: {e}"));
            None
        }
    }
}

// --- Boundaries -----------------------------------------------------------
//
// A scope and an isolated project are the same thing to the guard: a set of
// paths a session either is inside of or must not touch.

/// What a project declares in its contract about isolation. A client's
/// project (`code.foreign`, the client-repo profile) is isolated and sees only
/// the shared profile unless it says otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProjectRules {
    pub isolated: bool,
    pub person: Option<Person>,
}

/// It fails closed: a contract that is there and cannot be read, or an
/// `isolation` it does not understand, makes the project isolated and its
/// profile shared. A client's contract half-merged must not open the client's
/// project to every session of the scope.
pub fn project_rules(scope: &Scope, project: &str) -> ProjectRules {
    let docs = scope.root.join(project).join(format!("{project}-docs"));
    let closed = ProjectRules { isolated: true, person: Some(Person::Shared) };
    if !project::contract_file(&docs).is_file() {
        return ProjectRules { isolated: false, person: None };
    }
    let Ok(c) = project::read_contract(&docs) else { return closed };
    let profile = files::get_str(&c, "profile").unwrap_or_default();
    let foreign = crate::policy::code_is_foreign(&profile, Some(&docs));
    let isolated = match files::get_str(&c, "isolation").as_deref() {
        Some("isolated") => true,
        Some("shared") => false,
        None => foreign,
        Some(_) => return closed,
    };
    let person = files::get_str(&c, "person").and_then(|p| Person::parse(&p)).or(if foreign {
        Some(Person::Shared)
    } else {
        None
    });
    ProjectRules { isolated, person }
}

/// Where a path is: its scope and, inside the scope's root, its project (the
/// first folder, a workspace counted as its project).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    pub scope: String,
    pub project: Option<String>,
}

impl Place {
    pub fn parse(pin: &str) -> Place {
        match pin.split_once('/') {
            Some((s, p)) => Place { scope: s.into(), project: Some(p.into()) },
            None => Place { scope: pin.into(), project: None },
        }
    }

    pub fn as_pin(&self) -> String {
        match &self.project {
            Some(p) => format!("{}/{p}", self.scope),
            None => self.scope.clone(),
        }
    }
}

/// The project a path belongs to inside its scope.
pub fn project_of_path(scope: &Scope, path: &Path) -> Option<String> {
    let real = real_lenient(path);
    let rel = if inside(&real, &scope.real_root) {
        real.strip_prefix(&scope.real_root).ok().map(Path::to_path_buf).or_else(|| {
            let r = real.to_string_lossy().to_lowercase();
            let root = scope.real_root.to_string_lossy().to_lowercase();
            r.strip_prefix(&root).map(|x| PathBuf::from(x.trim_start_matches('/')))
        })?
    } else {
        let main = real_lenient(&main_repo_of_worktree(&real)?);
        main.strip_prefix(&scope.real_root).ok()?.to_path_buf()
    };
    let first = rel.components().next()?.as_os_str().to_string_lossy().into_owned();
    Some(first.split("-ws-").next().unwrap_or(&first).to_string())
}

impl Scopes {
    /// The place a path belongs to: inside a root, or a secret a scope
    /// declares, or the state crux keeps for a scope.
    pub fn place_of(&self, path: &Path) -> Option<Place> {
        if let Some(s) = self.of_path(path) {
            return Some(Place { scope: s.name.clone(), project: project_of_path(s, path) });
        }
        if let Some(s) = self.list.iter().find(|s| s.owns_secret(path)) {
            return Some(Place { scope: s.name.clone(), project: None });
        }
        let real = real_lenient(path);
        for s in &self.list {
            if inside(&real, &real_lenient(&s.tasks_dir())) {
                return Some(Place { scope: s.name.clone(), project: None });
            }
        }
        None
    }

    /// How much of the profile a session at a place sees: its scope's, which
    /// its project can narrow and never widen.
    pub fn person_at(&self, place: &Place) -> Person {
        let Some(s) = self.by_name(&place.scope) else { return Person::None };
        let narrowed = place.project.as_deref().and_then(|p| project_rules(s, p).person);
        narrowed.map_or(s.person, |p| p.min(s.person))
    }

    /// The place a session opened in a folder is pinned to: the scope, and
    /// the project too when that project is isolated.
    pub fn pin_place(&self, path: &Path) -> Option<Place> {
        let s = self.of_path(path)?;
        let project = project_of_path(s, path).filter(|p| project_rules(s, p).isolated);
        Some(Place { scope: s.name.clone(), project })
    }
}

// --- What a session is told -------------------------------------------------

/// The projects of a scope, by folder: what hangs from its root, without
/// workspaces, hidden folders or the person's profile.
pub fn projects(s: &Scope) -> Vec<String> {
    let profile = crate::person::repo_name();
    project::subdirs(&s.root)
        .into_iter()
        .filter(|n| !n.starts_with('.') && !n.contains("-ws-") && *n != profile)
        .collect()
}

impl Scopes {
    /// The scope a project lives in, by its folder in each root. Two scopes
    /// may hold a project with the same name: then the name alone does not
    /// say which, and it is an error rather than a guess.
    pub fn scope_of_project(&self, name: &str) -> Result<&Scope, String> {
        let found: Vec<&Scope> = self.list.iter().filter(|s| s.root.join(name).is_dir()).collect();
        match found.as_slice() {
            [one] => Ok(one),
            [] => Err(format!("no scope has a project '{name}'")),
            many => Err(format!(
                "project '{name}' is in several scopes ({}): name the scope instead",
                many.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().join(", ")
            )),
        }
    }
}

/// The front desk's map: enough to tell where a request belongs, and only
/// names. What is inside a scope is loaded once the session enters it.
pub fn map_text(all: &Scopes) -> String {
    let mut out = vec!["Scopes on this machine and their projects (names only):".to_string()];
    for s in &all.list {
        let ps = projects(s);
        out.push(format!(
            "· {}{}: {}",
            s.name,
            if s.primary { " (the person's own)" } else { "" },
            if ps.is_empty() { "no projects yet".into() } else { ps.join(", ") }
        ));
    }
    out.join("\n")
}

/// What a session is told when it is pinned: where it is, the profile it may
/// see, and how to leave. Also what `crux scope enter` prints, which is how a
/// session pinned from the front desk gets it.
pub fn context_text(all: &Scopes, place: &Place) -> String {
    let Some(s) = all.by_name(&place.scope) else { return String::new() };
    let here = match &place.project {
        Some(p) => format!("the isolated project '{p}' of scope '{}'", s.name),
        None => format!("scope '{}'", s.name),
    };
    let mut out = vec![format!(
        "This session is in {here} (root {}). It stays there: work that belongs to another scope or isolated \
         project is done in a new session, opened with `crux scope open <scope>` or `crux scope open --project \
         <name>`. Say so to the person instead of trying. Run crux commands from inside that root.",
        s.root.display()
    )];
    if place.project.is_none() {
        let ps = projects(s);
        if !ps.is_empty() {
            out.push(format!("Its projects: {}.", ps.join(", ")));
        }
    }
    if all.person_at(place) == Person::Full {
        if let Some(d) = crate::person::dir() {
            let index = files::read_or_empty(&d.join("PROFILE.md"));
            out.push(format!(
                "The person's full profile applies here (paths relative to {}):\n{}",
                d.display(),
                index.trim_end()
            ));
        }
    }
    out.join("\n\n")
}

/// Where agents keep their sessions' conversations: Claude's transcripts,
/// Codex's sessions, and whatever else the machine names in
/// CRUX_SESSION_STORES (paths separated by `:`), such as an agent app's own
/// store. They hold every scope's conversations at once.
pub fn session_stores() -> Vec<PathBuf> {
    let mut out = vec![env::claude_transcripts_dir(), env::codex_home_dir().join("sessions")];
    let key = crate::names::vars::SESSION_STORES;
    if let Some(v) = env::var(key).or_else(|| env::config_value_in(&env::config_file(), key)) {
        out.extend(v.split(':').filter(|p| !p.is_empty()).map(expand));
    }
    out
}

// --- Pins --------------------------------------------------------------------
//
// A session is pinned to one scope and the pin never moves: what leaks
// between scopes is the conversation as much as the files, so another scope
// means another session.

pub fn pins_dir() -> PathBuf {
    env::state_dir().join("scope-pins")
}

fn pin_file(session: &str) -> PathBuf {
    let safe: String = session.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
    pins_dir().join(safe)
}

/// The scope a session is pinned to, if it is.
pub fn pinned(session: &str) -> Option<String> {
    if session.is_empty() {
        return None;
    }
    files::read_optional(&pin_file(session)).map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

#[derive(Debug, PartialEq, Eq)]
pub enum Pin {
    /// It was not pinned and now is.
    New,
    /// It already was, to this same scope.
    Same,
}

/// Pins a session. Refused when it is pinned elsewhere: that is the whole
/// point of a pin. The file is created only if absent, so two tool calls of
/// one session racing to pin it cannot leave it in the scope of the later.
pub fn pin(session: &str, scope: &str) -> Result<Pin, String> {
    if session.is_empty() {
        return Err("no session id to pin".into());
    }
    let f = pin_file(session);
    files::mkdir_private(&pins_dir()).map_err(|e| format!("{}: {e}", pins_dir().display()))?;
    let created = std::fs::OpenOptions::new().write(true).create_new(true).open(&f);
    match created {
        Ok(mut file) => match std::io::Write::write_all(&mut file, format!("{scope}\n").as_bytes()) {
            Ok(()) => Ok(Pin::New),
            Err(e) => {
                // A pin left empty would stop the session for good.
                let _ = std::fs::remove_file(&f);
                Err(format!("{}: {e}", f.display()))
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => match pinned(session) {
            Some(s) if s == scope => Ok(Pin::Same),
            Some(s) => Err(format!("this session is already in '{s}'; '{scope}' needs a new session")),
            None => Err(format!("{}: exists and cannot be read", f.display())),
        },
        Err(e) => Err(format!("{}: {e}", f.display())),
    }
}

/// Marks a pin as alive. Pins older than a month are swept, and a session
/// resumed after that would otherwise be pinned again wherever it stands,
/// with the earlier scope's conversation in it. Rewritten at most once a day.
pub fn refresh_pin(session: &str) {
    let f = pin_file(session);
    let stale = std::fs::metadata(&f)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age > std::time::Duration::from_secs(86400));
    if stale {
        if let Some(content) = files::read_optional(&f) {
            let _ = files::write(&f, &content);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope(name: &str, root: &str) -> Scope {
        let mut s = implicit();
        s.name = name.into();
        s.root = PathBuf::from(root);
        s.real_root = PathBuf::from(root);
        s.primary = false;
        s
    }

    #[test]
    fn a_path_is_inside_its_root_and_not_in_a_sibling_with_the_same_prefix() {
        assert!(inside(Path::new("/w/acme/web"), Path::new("/w/acme")));
        assert!(inside(Path::new("/w/acme"), Path::new("/w/acme")));
        assert!(!inside(Path::new("/w/acme-old/web"), Path::new("/w/acme")));
    }

    #[test]
    fn overlapping_roots_and_shared_owners_are_problems() {
        let mut a = scope("a", "/w/a");
        let b = scope("b", "/w/a/inner");
        a.primary = true;
        let p = problems(&[a.clone(), b]);
        assert!(p.iter().any(|x| x.contains("overlap")), "{p:?}");

        let mut c = scope("c", "/w/c");
        a.owners = vec!["org".into()];
        c.owners = vec!["ORG".into()];
        let p = problems(&[a, c]);
        assert!(p.iter().any(|x| x.contains("two scopes")), "{p:?}");
    }

    #[test]
    fn several_scopes_need_exactly_one_primary() {
        let a = scope("a", "/w/a");
        let b = scope("b", "/w/b");
        assert!(problems(&[a.clone(), b.clone()]).iter().any(|x| x.contains("none is PRIMARY")));
        let (mut a2, mut b2) = (a, b);
        a2.primary = true;
        b2.primary = true;
        assert!(problems(&[a2, b2]).iter().any(|x| x.contains("only one scope")));
    }

    #[test]
    fn a_secret_inside_another_root_is_a_problem() {
        let mut a = scope("a", "/w/a");
        a.primary = true;
        a.secrets = vec![PathBuf::from("/w/b/keys")];
        let b = scope("b", "/w/b");
        assert!(problems(&[a, b]).iter().any(|x| x.contains("a secret of 'a'")));
    }

    #[test]
    fn the_home_is_expanded_in_every_spelling() {
        let home = env::home().to_string_lossy().into_owned();
        assert_eq!(expand("~/x"), PathBuf::from(format!("{home}/x")));
        assert_eq!(expand("$HOME/x"), PathBuf::from(format!("{home}/x")));
        assert_eq!(expand("${HOME}/x"), PathBuf::from(format!("{home}/x")));
        assert_eq!(expand("/abs"), PathBuf::from("/abs"));
    }
}
