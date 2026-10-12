//! crux doctor — checks that a docs repo meets the standard.
//!
//! A standard is worth little if it is only trusted to be followed. This
//! checks it. Exits with code 1 on errors; warnings do not block.

use crate::error::{exit, Res};
use crate::names;
use crate::template::LOCAL_POINTER;
use crate::{checks, die, env, files, git, mcp, policy, project, sh, ui};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Default)]
struct Tally {
    errors: u32,
    warns: u32,
    mark: u32,
    mark_warns: u32,
}

impl Tally {
    fn fail(&mut self, m: impl AsRef<str>) {
        ui::err(m);
        self.errors += 1;
    }
    fn note(&mut self, m: impl AsRef<str>) {
        ui::warn(m);
        self.warns += 1;
    }
    fn section(&mut self) {
        self.mark = self.errors;
        self.mark_warns = self.warns;
    }
    /// An 'ok' only if the section produced no errors: saying "ok" and
    /// "error" about the same check is worse than saying nothing.
    fn section_ok(&self, m: impl AsRef<str>) {
        if self.errors == self.mark {
            ui::ok(m);
        }
    }
    fn quiet_section(&self) -> bool {
        self.warns == self.mark_warns
    }
    /// A checker's line: "error …" fails, anything else warns.
    fn report(&mut self, line: &str, prefix: &str) {
        if let Some(r) = line.strip_prefix("error ") {
            self.fail(format!("{prefix}{r}"));
        } else {
            self.note(format!("{prefix}{}", line.strip_prefix("warning ").unwrap_or(line)));
        }
    }
    fn summary(&self) -> String {
        let (e, w) = (self.errors, self.warns);
        format!("{e} {}, {w} {}", if e == 1 { "error" } else { "errors" }, if w == 1 { "warning" } else { "warnings" })
    }
}

fn gh_ready() -> bool {
    sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok()
}

/// The system's, the bundler's own and libraries' debug switches.
const ENV_IGNORED: [&str; 18] = [
    "NODE_ENV",
    "CI",
    "HOME",
    "PATH",
    "PWD",
    "USER",
    "TZ",
    "LANG",
    "TERM",
    "SHELL",
    "TMPDIR",
    "PROD",
    "DEV",
    "MODE",
    "SSR",
    "BASE_URL",
    "DEBUG",
    "NODE_DEBUG",
];

const RIGOR: [&str; 3] = ["light", "normal", "strict"];

/// The variables the code reads. Bundled or third-party code reads variables
/// nobody has to set.
fn env_refs(dir: &Path) -> Vec<String> {
    let skip = [":!*.md", ":!*.min.js", ":!**/vendor/**", ":!**/node_modules/**", ":!**/dist/**", ":!**/build/**"];
    let mut found = BTreeSet::new();
    let mut args = vec!["grep", "-hoE", r"(process\.env|import\.meta\.env)\.[A-Z][A-Z0-9_]+", "--"];
    args.extend(skip);
    for m in git::out(dir, &args).unwrap_or_default().lines() {
        if let Some(v) = m.rsplit('.').next() {
            found.insert(v.to_string());
        }
    }
    let tail = crate::regex!(r"[A-Z][A-Z0-9_]+$");
    for m in git::out(dir, &["grep", "-hoE", r"os\.(environ|getenv)[^A-Z]{1,8}[A-Z][A-Z0-9_]+", "--", "*.py"])
        .unwrap_or_default()
        .lines()
    {
        if let Some(v) = tail.find(m) {
            found.insert(v.as_str().to_string());
        }
    }
    for m in git::out(dir, &["grep", "-hoE", r"\$\{[A-Z][A-Z0-9_]+", "--", "docker-compose*.yml", "compose*.yml"])
        .unwrap_or_default()
        .lines()
    {
        found.insert(m.chars().skip(2).collect());
    }
    found.into_iter().filter(|v| !ENV_IGNORED.contains(&v.as_str())).collect()
}

fn first_names(v: &[String]) -> String {
    v.iter().take(6).cloned().collect::<Vec<_>>().join(", ")
}

/// What every check needs to know about the project, read once.
struct Checkup {
    docs: PathBuf,
    docs_name: String,
    /// Where the project's repos live: the docs repo's parent.
    root: PathBuf,
    contract: Value,
    project_name: String,
    profile: String,
    declared_version: String,
    language: String,
    declared: Vec<String>,
    origin_docs: String,
    gh: bool,
    /// Whether the profile lets crux write into the code repos.
    writes: bool,
}

impl Checkup {
    fn field(&self, key: &str, default: &str) -> String {
        files::get_str(&self.contract, key).unwrap_or_else(|| default.to_string())
    }
    fn on_disk(&self) -> impl Iterator<Item = &String> {
        self.declared.iter().filter(|r| self.root.join(r).is_dir())
    }
}

pub fn run(argv: &[String]) -> Res {
    if argv.first().map(String::as_str) == Some("--machine") {
        return super::machine::run(&argv[1..]);
    }
    let start = argv.first().map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
    let Some(docs) = project::find_docs_repo(&start) else { die!("no docs repo found from {}", start.display()) };
    let mut t = Tally::default();
    let docs_name = files::name(&docs);
    println!("checking {docs_name}");
    println!();

    let Some(contract) = read_contract(&mut t, &docs) else {
        println!();
        println!("{}", t.summary());
        return exit(1);
    };
    let field = |k: &str, d: &str| files::get_str(&contract, k).unwrap_or_else(|| d.to_string());
    let profile = field("profile", "?");
    let c = Checkup {
        root: docs.parent().unwrap_or(Path::new("/")).to_path_buf(),
        project_name: field("project", "?"),
        declared_version: field("crux", "?"),
        language: field("language", "es"),
        declared: files::str_list(contract.get("repos")).into_iter().filter(|r| !r.is_empty()).collect(),
        origin_docs: git::remote_url(&docs, "origin").unwrap_or_default(),
        gh: gh_ready(),
        writes: policy::flag(&profile, Some(&docs), "pointers.write", true),
        profile,
        docs_name,
        docs,
        contract,
    };

    check_contract(&mut t, &c);
    check_structure(&mut t, &c);
    check_repos(&mut t, &c);
    check_profile_rules(&mut t, &c);
    check_remotes(&mut t, &c);
    check_visibility(&mut t, &c);
    check_sections(&mut t, &c);
    check_adrs(&mut t, &c);
    check_links(&mut t, &c);
    check_project_skills(&mut t, &c);
    check_credentials(&mut t, &c);
    check_orphans(&mut t, &c);
    check_drift(&mut t, &c);
    check_mcp(&mut t, &c);
    if c.writes {
        check_code_repos(&mut t, &c);
    }

    println!();
    if t.errors == 0 && t.warns == 0 {
        let p = ui::palette();
        println!("{}conformant{} — {} meets the standard", p.green, p.off, c.docs_name);
    } else {
        println!("{}", t.summary());
    }
    if t.errors > 0 {
        exit(1)
    } else {
        Ok(())
    }
}

/// Without stopping here, every check after this reads empty fields and
/// reports them as absences: false errors about what is actually there.
fn read_contract(t: &mut Tally, docs: &Path) -> Option<Value> {
    if !project::contract_file(docs).is_file() {
        t.fail("crux.json is missing — the project is not adopted ('crux adopt')");
        return None;
    }
    t.section();
    match project::read_contract(docs) {
        Ok(c) => Some(c),
        Err(e) => {
            t.fail(format!("crux.json is not valid JSON: {e}"));
            None
        }
    }
}

fn check_contract(t: &mut Tally, c: &Checkup) {
    for field in ["crux", "project", "profile"] {
        if files::get(&c.contract, field).is_none() {
            t.fail(format!("crux.json missing required field: {field}"));
        }
    }
    if !policy::exists(&c.profile, Some(&c.docs)) {
        t.fail(format!("unknown profile: {}", c.profile));
    }
    // Rigor decides how much review is paid for and who merges: a typo cannot
    // fall back to a default level unnoticed.
    if let Some(r) = files::get(&c.contract, "rigor") {
        let r = files::value_text(r);
        if !RIGOR.contains(&r.as_str()) {
            t.fail(format!("unknown rigor: '{r}' — valid values are light, normal or strict"));
        }
    }
    // Only the series: a patch brings no templates or checks.
    let series = |v: &str| v.rsplit_once('.').map(|(a, _)| a.to_string()).unwrap_or_else(|| v.to_string());
    let (declared, kernel) = (&c.declared_version, env::crux_version());
    if series(declared) != series(&kernel) {
        if project::version_greater_than(declared, &kernel) {
            t.note(format!("the project is ahead of the kernel ({declared} > {kernel}): update crux, not the project"));
        } else {
            t.note(format!("materialized with crux {declared}, the kernel is {kernel} ('crux upgrade')"));
        }
    }
    if c.docs_name != format!("{}-docs", c.project_name) {
        t.note(format!("the docs repo should be named {}-docs", c.project_name));
    }
    t.section_ok(format!("contract: {} · profile {} · crux {declared}", c.project_name, c.profile));
}

fn check_structure(t: &mut Tally, c: &Checkup) {
    t.section();
    for f in [names::README, names::AGENTS, "decisions/README.md", "decisions/index.md", "repos/README.md"] {
        if !c.docs.join(f).is_file() {
            t.fail(format!("missing {f}"));
        }
    }
    let claude = c.docs.join(names::CLAUDE);
    match std::fs::read_link(&claude) {
        Ok(target) => {
            if target != Path::new(names::AGENTS) {
                t.fail("CLAUDE.md should link to AGENTS.md");
            }
        }
        Err(_) if claude.is_file() => {
            t.note("CLAUDE.md is a file, not a symlink to AGENTS.md (two sources that diverge)")
        }
        Err(_) => t.fail("missing CLAUDE.md"),
    }
    t.section_ok("required structure");
}

fn check_repos(t: &mut Tally, c: &Checkup) {
    t.section();
    let archived = archived_repos(t, c);
    for repo in &c.declared {
        if !c.docs.join("repos").join(repo).is_dir() {
            t.fail(format!("declared repo without a doc folder: repos/{repo}/"));
        }
        if !c.docs.join("repos").join(repo).join(names::README).is_file() {
            t.note(format!("repos/{repo}/ has no README.md"));
        }
        if !c.root.join(repo).is_dir() {
            t.note(format!("declared repo not on disk: {repo}"));
        }
    }
    for name in project::subdirs(&c.docs.join("repos")) {
        if !c.declared.contains(&name) && !archived.contains(&name) {
            t.note(format!("repos/{name}/ is not declared in crux.json"));
        }
    }
    // The repo on disk that nobody declared: the checks above go from what is
    // declared to what exists, so this case would pass as conformant.
    for name in project::subdirs(&c.root) {
        if name == c.docs_name {
            continue;
        }
        let dir = c.root.join(&name);
        // Only the root of a repo, and not a workspace (a sibling worktree).
        let Some(top) = git::toplevel(&dir) else { continue };
        let same = std::fs::canonicalize(&dir).ok() == std::fs::canonicalize(&top).ok();
        if !same || git::is_worktree(&dir) {
            continue;
        }
        if archived.contains(&name) {
            ui::info(format!("{name}/ is archived and still cloned here: it can be deleted"));
            continue;
        }
        if !c.declared.contains(&name) {
            t.note(format!("{name}/ is on disk and not declared ('crux add-repo {name}')"));
        }
    }
    if c.origin_docs.contains("github.com") && c.gh {
        undeclared_on_remote(t, c, &archived);
    }
    if !archived.is_empty() && c.gh {
        archived_still_writable(t, c, &archived);
    }
    let arch = if archived.is_empty() { String::new() } else { format!(", {} archived", archived.len()) };
    t.section_ok(format!("repos: {} declared{arch}", c.declared.len()));
}

/// Archived repos are known but not active. Their entries say since when and
/// why; the ones that do not are reported and left out.
fn archived_repos(t: &mut Tally, c: &Checkup) -> Vec<String> {
    let mut archived = vec![];
    let date = crate::regex!(r"^\d{4}-\d{2}-\d{2}$");
    for (name, entry) in c.contract.get("archived").and_then(Value::as_object).cloned().unwrap_or_default() {
        let mut problems = vec![];
        if c.declared.contains(&name) {
            problems.push("it is also in repos: archived or active, not both");
        }
        if !date.is_match(entry.get("since").and_then(Value::as_str).unwrap_or("")) {
            problems.push("since must be a date (YYYY-MM-DD)");
        }
        if entry.get("reason").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
            problems.push("reason is missing: say why it is out of production");
        }
        if problems.is_empty() {
            archived.push(name);
        } else {
            t.fail(format!("archived repo {name}: {}", problems.join("; ")));
        }
    }
    archived
}

/// The repo on the remote that nobody cloned here: invisible on this machine,
/// it can spend half a year outside the contract.
fn undeclared_on_remote(t: &mut Tally, c: &Checkup, archived: &[String]) {
    let owner =
        crate::regex!(r"^.*github\.com[:/]").replace(&c.origin_docs, "").split('/').next().unwrap_or("").to_string();
    let list =
        sh::capture("gh", &["repo", "list", &owner, "--limit", "200", "--json", "name", "--jq", ".[].name"]).stdout;
    let lower = c.project_name.to_lowercase();
    for remote in list.lines().filter(|r| !r.is_empty() && **r != c.docs_name) {
        let r = remote.to_lowercase();
        if r == lower || r.starts_with(&format!("{lower}-")) {
            let known = c.declared.iter().chain(archived.iter()).any(|x| x.to_lowercase() == r);
            if !known {
                t.note(format!("{remote} is on the remote and not declared ('crux add-repo {remote}')"));
            }
        }
    }
}

/// Archived in the contract and still writable on GitHub: its workflows still
/// run on a merge.
fn archived_still_writable(t: &mut Tally, c: &Checkup, archived: &[String]) {
    let re = crate::regex!(r"github\.com[:/]([^/]+)/([^/]+)$");
    for name in archived {
        let url = project::remote_url(&c.contract, name).unwrap_or_default();
        let Some(m) = re.captures(&url) else { continue };
        let slug = format!("{}/{}", &m[1], m[2].strip_suffix(".git").unwrap_or(&m[2]));
        if sh::capture("gh", &["api", &format!("repos/{slug}"), "--jq", ".archived"]).out() == "false" {
            t.note(format!(
                "{name} is archived in crux.json but not on GitHub: its workflows still run ('gh repo archive {slug}')"
            ));
        }
    }
}

fn check_profile_rules(t: &mut Tally, c: &Checkup) {
    t.section();
    if c.writes {
        for repo in c.on_disk() {
            for file in [names::AGENTS, names::CLAUDE] {
                let f = c.root.join(repo).join(file);
                if !f.is_file() {
                    t.note(format!("{repo}/ has no {file} ('crux link')"));
                } else if !files::read_or_empty(&f).contains("crux:begin") {
                    t.note(format!("{repo}/{file} predates the managed block ('crux link --refresh')"));
                }
            }
        }
    } else {
        foreign_repo_pointers(t, c);
    }
    let rules = policy::get(&c.profile, Some(&c.docs), "rules").unwrap_or_default();
    let block = crate::regex!(r"crux:begin (perfil|profile)");
    if !rules.is_empty() && !block.is_match(&files::read_or_empty(&c.docs.join(names::AGENTS))) {
        t.note("the profile rules are not in AGENTS.md ('crux link')");
    }
    t.section_ok(format!("profile {} rules", c.profile));
}

/// In someone else's code, a client's own AGENTS.md is theirs; the intrusion
/// is the file we put there, recognised by the managed block or by not being
/// versioned.
fn foreign_repo_pointers(t: &mut Tally, c: &Checkup) {
    for repo in c.on_disk() {
        let dir = c.root.join(repo);
        for intruder in [names::AGENTS, names::CLAUDE] {
            let f = dir.join(intruder);
            if f.symlink_metadata().is_err() {
                continue;
            }
            if files::read_or_empty(&f).contains("crux:begin")
                || !git::ok(&dir, &["ls-files", "--error-unmatch", intruder])
            {
                t.fail(format!("profile {}: {repo}/{intruder} should not exist (someone else's code)", c.profile));
            } else {
                t.note(format!("{repo}/{intruder} belongs to the client — respected, not touched"));
            }
        }
    }
    // Without the local pointer the agent loads nothing of ours in the
    // client's repo.
    if !policy::flag(&c.profile, Some(&c.docs), "pointers.local", false) {
        return;
    }
    for repo in c.on_disk() {
        let dir = c.root.join(repo);
        if !git::ok(&dir, &["rev-parse", "--git-dir"]) {
            continue;
        }
        if git::ok(&dir, &["ls-files", "--error-unmatch", LOCAL_POINTER]) {
            t.note(format!("{repo}/{LOCAL_POINTER} belongs to the client — respected, not touched"));
        } else if !dir.join(LOCAL_POINTER).is_file() {
            t.fail(format!(
                "{repo}/ has no {LOCAL_POINTER}: the agent will not discover {} ('crux link')",
                c.docs_name
            ));
        } else if !git::ok(&dir, &["check-ignore", "-q", LOCAL_POINTER]) {
            t.fail(format!("{repo}/{LOCAL_POINTER} is not excluded from git and could be committed ('crux link')"));
        }
    }
}

/// Declared remote against the real one: everything works here and the clone
/// fails on the next machine, which is when you least want to debug it.
fn check_remotes(t: &mut Tally, c: &Checkup) {
    t.section();
    if !git::ok(&c.docs, &["rev-parse", "--git-dir"]) {
        t.fail("the docs repo is not in git: the documentation does not survive a change of machine");
        return;
    }
    if files::get(&c.contract, "remote").is_none() {
        t.note("no 'remote' in crux.json — 'crux clone' will not be able to fetch this project");
        return;
    }
    for repo in c.declared.iter().filter(|r| c.root.join(r).join(".git").is_dir()) {
        let Some(real) = git::remote_url(&c.root.join(repo), "origin") else { continue };
        match project::remote_url(&c.contract, repo) {
            None => {
                t.note(format!("{repo}: no remote in the contract — 'crux clone' will not know where to fetch it from"))
            }
            Some(d) if project::normalize_git_url(&d) != project::normalize_git_url(&real) => {
                t.note(format!("{repo}: the contract says {d} and origin is {real}"))
            }
            Some(_) => {}
        }
    }
    if t.quiet_section() {
        t.section_ok("remote consistent with the contract");
    }
}

/// A public docs repo with internal documentation is an incident. Where there
/// is no API to ask, it says it was not checked.
fn check_visibility(t: &mut Tally, c: &Checkup) {
    t.section();
    if !(c.origin_docs.contains("github.com") && c.gh) {
        ui::info("visibility not checked (needs gh and a GitHub remote)");
        return;
    }
    let expected = c.field("remote.visibility", "private");
    let slug = crate::regex!(r"^.*github\.com[:/]").replace(&c.origin_docs, "").into_owned();
    let slug = slug.strip_suffix(".git").unwrap_or(&slug).to_string();
    let actual =
        sh::capture("gh", &["repo", "view", &slug, "--json", "visibility", "-q", ".visibility"]).out().to_lowercase();
    if actual.is_empty() {
        t.note(format!("could not query the visibility of {slug}"));
    } else if actual == "public" && expected != "public" {
        t.fail(format!("the docs repo is PUBLIC and the contract expects {expected}"));
        if c.profile == "client-repo" {
            ui::err("and it contains a client's documentation");
        }
    } else if actual != expected {
        t.note(format!("actual visibility '{actual}', the contract says '{expected}'"));
    }
    t.section_ok(format!("visibility: {actual}"));
}

fn check_sections(t: &mut Tally, c: &Checkup) {
    for s in files::str_list(c.contract.get("sections")).into_iter().filter(|s| !s.is_empty()) {
        if !c.docs.join(&s).is_dir() {
            t.note(format!("declared section without a folder: {s}/"));
        }
    }
}

/// Two parallel sessions pick the same "next number" and git does not see the
/// conflict; a "Superseded" that does not say by what cuts the chain right
/// where someone was following it.
fn check_adrs(t: &mut Tally, c: &Checkup) {
    t.section();
    let (notes, problems) = checks::decisions(&c.docs);
    for n in notes {
        t.note(n);
    }
    for p in problems {
        t.fail(p);
    }
    t.section_ok("ADR status and numbering");
}

fn check_links(t: &mut Tally, c: &Checkup) {
    let (report, broken) = checks::doc_paths(&c.docs);
    if broken == 0 {
        ui::ok("markdown links resolve");
        return;
    }
    t.fail("broken markdown links:");
    for l in report.lines().take(20) {
        println!("      {l}");
    }
}

/// The same bar as the kernel's catalog.
fn check_project_skills(t: &mut Tally, c: &Checkup) {
    t.section();
    let dir = c.docs.join(".claude/skills");
    let skills = if dir.is_dir() { count_skills(&dir) } else { 0 };
    for line in checks::skill_descriptions(&dir, &c.language) {
        t.report(&line, "");
    }
    if skills > 0 {
        t.section_ok(format!("project skills: {skills}"));
    }
}

/// A committed secret stays in the history and in every clone. It says where
/// it is so that it is a decision and not a slip.
fn check_credentials(t: &mut Tally, c: &Checkup) {
    t.section();
    let found = checks::secrets_in(&c.docs);
    for f in &found {
        t.note(format!("credential in the documentation: {f}"));
    }
    if found.is_empty() {
        t.section_ok("no credentials in plain sight in the documentation");
    }
    for s in checks::staleness(&c.docs, 6) {
        t.note(s);
    }
}

/// Documents nobody links to: opened by no agent, they age and end up
/// contradicting the ones that do get read.
fn check_orphans(t: &mut Tally, c: &Checkup) {
    t.section();
    let mut orphans = 0;
    let all_md = markdown_files(&c.docs);
    let texts: Vec<(PathBuf, String)> = all_md.iter().map(|p| (p.clone(), files::read_or_empty(p))).collect();
    for doc in all_md.iter().filter(|p| !p.to_string_lossy().contains("/.claude/")) {
        let base = files::name(doc);
        // A README is the index of its own folder: nobody links to it.
        if [names::README, names::AGENTS, names::CLAUDE].contains(&base.as_str()) {
            continue;
        }
        if !texts.iter().any(|(p, text)| p != doc && text.contains(&base)) {
            let rel = doc.strip_prefix(&c.docs).unwrap_or(doc).to_string_lossy().into_owned();
            t.note(format!("nobody links to {rel} — add it to an index or delete it"));
            orphans += 1;
        }
    }
    if orphans == 0 {
        t.section_ok("every document is in an index");
    }
}

/// The auditable part of the closing discipline.
fn check_drift(t: &mut Tally, c: &Checkup) {
    t.section();
    let drift = checks::drift(&c.docs);
    for d in &drift {
        t.note(format!("code ↔ doc drift: {d}"));
    }
    if drift.is_empty() {
        t.section_ok("documentation up to date with the code");
    }
}

/// Shape and drift, no network.
fn check_mcp(t: &mut Tally, c: &Checkup) {
    t.section();
    for line in mcp::check(&c.docs) {
        t.report(&line, "mcp: ");
    }
    if !mcp::declared(&c.contract).is_empty() {
        t.section_ok("MCP servers declared and written where they belong");
    }
}

/// What lives in your own code repos: documentation written next to the code,
/// and variables the code reads that the example does not list.
fn check_code_repos(t: &mut Tally, c: &Checkup) {
    t.section();
    for repo in &c.declared {
        let dir = c.root.join(repo);
        if !git::ok(&dir, &["rev-parse", "--git-dir"]) {
            continue;
        }
        let tracked = git::out(&dir, &["ls-files"]).unwrap_or_default();
        stray_documentation(t, c, repo, &dir, &tracked);
        environment_example(t, repo, &dir, &tracked);
    }
    if t.quiet_section() {
        t.section_ok("code repos: documentation in the docs repo, environment listed in its example");
    }
}

fn stray_documentation(t: &mut Tally, c: &Checkup, repo: &str, dir: &Path, tracked: &str) {
    let allowed =
        crate::regex!(r"^(README|AGENTS|CLAUDE|CHANGELOG|CONTRIBUTING|SECURITY|CODE_OF_CONDUCT|LICENSE)\.md$");
    let mut stray: BTreeSet<String> = BTreeSet::new();
    for f in tracked.lines() {
        if f.split('/').next() == Some("docs") && f.contains('/') {
            stray.insert("docs/".into());
        } else if !f.contains('/') && f.ends_with(".md") && !allowed.is_match(f) {
            stray.insert(f.to_string());
        }
    }
    let docs_name = &c.docs_name;
    if !stray.is_empty() {
        let list: Vec<String> = stray.into_iter().collect();
        t.note(format!("{repo} holds documentation ({}): it goes in {docs_name}/repos/{repo}/", first_names(&list)));
    }
    if let Some(text) = crate::files::read_optional(&dir.join(names::README)) {
        let lines = text.matches('\n').count();
        if lines > 60 {
            t.note(format!("{repo}/README.md has {lines} lines: say what it is and where the docs are, and leave the rest to {docs_name}/repos/{repo}/"));
        }
    }
}

fn environment_example(t: &mut Tally, repo: &str, dir: &Path, tracked: &str) {
    let name_re = crate::regex!(r"^[[:space:]]*(?:export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)");
    let example =
        [".env.example", ".env.sample", ".env.template"].into_iter().find(|f| tracked.lines().any(|l| l == *f));
    let refs = env_refs(dir);
    let local_env = [".env", ".env.development", ".env.local"].into_iter().find(|f| dir.join(f).exists());
    match example {
        None => {
            if !refs.is_empty() {
                t.note(format!(
                    "{repo} reads environment variables and has no .env.example ({}): names without values, committed",
                    first_names(&refs)
                ));
            } else if let Some(l) = local_env {
                t.note(format!("{repo} has {l} but no .env.example: names without values, committed"));
            }
        }
        Some(ex) if !refs.is_empty() => {
            let listed: BTreeSet<String> = files::read_or_empty(&dir.join(ex))
                .lines()
                .filter_map(|l| name_re.captures(l).map(|c| c[1].to_string()))
                .collect();
            let missing: Vec<String> = refs.iter().filter(|r| !listed.contains(*r)).cloned().collect();
            if !missing.is_empty() {
                t.note(format!("{repo}/{ex} lacks what the code reads: {}", first_names(&missing)));
            }
        }
        _ => {}
    }
}

fn count_skills(dir: &Path) -> usize {
    let mut n = 0;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if e.file_name() == names::SKILL {
                n += 1;
            }
        }
    }
    n
}

fn markdown_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            if e.file_name() == ".git" {
                continue;
            }
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "md") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}
