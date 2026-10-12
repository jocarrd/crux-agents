//! Tasks travel between machines: a replica of ~/.crux/tasks/<project>/ in
//! the `crux/tasks` branch of the project's docs repo. See ADR-016.
//!
//! The local file is the source of truth and the branch its replica. Only git
//! plumbing —hash-object, write-tree, commit-tree, push—, no worktree or
//! checkout: the branch never touches the docs repo's working tree, which may
//! be halfway through something else.

use super::record;
use crate::names;
use crate::{env, files};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const BRANCH: &str = "crux/tasks";
const REMOTE_REF: &str = "refs/remotes/origin/crux/tasks";
/// What the sync last saw on the remote. Its own ref, and the remote by URL
/// and not by name: writing REMOTE_REF makes a `git pull` at the same moment
/// fail with "cannot lock ref". git 2.56 and later update that ref on a push
/// to the remote's URL; with a fetch holding it, the push still succeeds.
const TRACK_REF: &str = "refs/crux/tasks-remote";
const REMOVED: &str = ".removed";

fn state_dir() -> PathBuf {
    env::state_dir().join("task-sync")
}

fn is_repo(d: &Path) -> bool {
    d.join(".git").exists()
}

/// A project's tasks travel in its docs repo; those of a standalone repo in
/// the root —the kernel itself— in that same repo.
pub fn transport(project: &str) -> Option<PathBuf> {
    let root = env::projects_root();
    let docs = root.join(project).join(format!("{project}-docs"));
    if is_repo(&docs) {
        return Some(docs);
    }
    let standalone = root.join(project);
    is_repo(&standalone).then_some(standalone)
}

// --- git ------------------------------------------------------------------------

struct Git<'a> {
    repo: &'a Path,
    env: Vec<(String, String)>,
}

impl<'a> Git<'a> {
    fn new(repo: &'a Path) -> Self {
        Git { repo, env: vec![] }
    }
    fn with(repo: &'a Path, env: &[(&str, &str)]) -> Self {
        Git { repo, env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new("git");
        c.arg("-C").arg(self.repo).args(args);
        c.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0");
        // With no terminal to answer, an ssh prompt would hang the publication.
        let ssh = std::env::var("GIT_SSH_COMMAND").unwrap_or_else(|_| "ssh".into());
        c.env("GIT_SSH_COMMAND", format!("{ssh} -o BatchMode=yes"));
        for (k, v) in &self.env {
            c.env(k, v);
        }
        c
    }
    /// stdout on success; stderr as the error.
    fn run(&self, args: &[&str], input: Option<&str>) -> Result<String, String> {
        let mut c = self.command(args);
        c.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
        let mut child = c.spawn().map_err(|e| e.to_string())?;
        if let Some(i) = input {
            let mut stdin = child.stdin.take().unwrap();
            let data = i.to_string();
            std::thread::spawn(move || {
                let _ = stdin.write_all(data.as_bytes());
            });
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        }
    }
    fn get(&self, args: &[&str]) -> Option<String> {
        self.run(args, None).ok().map(|s| s.trim().to_string())
    }
}

fn origin_url(repo: &Path, push: bool) -> Option<String> {
    let mut args = vec!["remote", "get-url"];
    if push {
        args.push("--push");
    }
    args.push("origin");
    Git::new(repo).get(&args).filter(|u| !u.is_empty())
}

/// false disables it, true forces it even if the repo is public, and with
/// nothing the visibility decides. A contract that cannot be read stops it.
fn contract_preference(repo: &Path) -> Result<Option<bool>, String> {
    let f = repo.join(names::CONTRACT);
    if !f.exists() {
        return Ok(None);
    }
    let c = files::read_json(&f)?;
    Ok(c.get("tasks").and_then(|t| t.get("sync")).and_then(Value::as_bool))
}

/// A record carries half-formed decisions, evidence and sometimes a client's
/// data: in a public repo it would be published for anyone. For GitHub the
/// visibility is asked and remembered; if it cannot be known, nothing is
/// published. Other remotes cannot be asked.
fn visibility(repo: &Path) -> String {
    // As configured: get-url applies insteadOf and could hide GitHub.
    let url = Git::new(repo).get(&["config", "--get", "remote.origin.url"]).unwrap_or_default();
    let re = crate::regex!(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$");
    let Some(m) = re.captures(&url) else { return "other".into() };
    let name = m[1].to_string();
    let cache = state_dir().join("visibility.json");
    let mut seen = files::read_json(&cache).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default();
    if let Some(v) = seen.get(&name).and_then(Value::as_str) {
        return v.to_string();
    }
    let mut c = Command::new("gh");
    c.args(["repo", "view", &name, "--json", "visibility", "--jq", ".visibility"]);
    let r = crate::sh::with_timeout(&mut c, 15);
    let v = r.stdout.trim().to_lowercase();
    if !r.ok() || v.is_empty() {
        return "unknown".into();
    }
    seen.insert(name, json!(v));
    let _ = files::mkdir_private(&state_dir());
    let _ = files::write_atomic(&cache, &Value::Object(seen).to_string(), Some(0o600));
    v
}

fn remote_tree(repo: &Path) -> (Option<String>, BTreeMap<String, String>) {
    let g = Git::new(repo);
    let mut files = BTreeMap::new();
    let Some(head) = g.get(&["rev-parse", "-q", "--verify", TRACK_REF]).filter(|h| !h.is_empty()) else {
        return (None, files);
    };
    for l in g.run(&["ls-tree", "-r", &head], None).unwrap_or_default().lines().filter(|l| !l.is_empty()) {
        if let Some((meta, path)) = l.split_once('\t') {
            if let Some(sha) = meta.split(' ').nth(2) {
                files.insert(path.to_string(), sha.to_string());
            }
        }
    }
    (Some(head), files)
}

fn blob(repo: &Path, sha: &str) -> String {
    Git::new(repo).run(&["cat-file", "blob", sha], None).unwrap_or_default()
}

// --- The local side ---------------------------------------------------------------

/// Conflict copies are a warning for this machine, not a task.
pub(super) fn is_task(name: &str) -> bool {
    name.ends_with(".md") && !is_conflict_copy(name)
}

/// `<task>.conflict-<who>.md`; earlier kernels wrote `.conflicto-`, and those
/// copies may still be on a machine.
pub fn is_conflict_copy(name: &str) -> bool {
    name.ends_with(".md") && (name.contains(".conflict-") || name.contains(".conflicto-"))
}

fn local_files(dir: &Path) -> Vec<String> {
    let mut out = vec![];
    for sub in ["", "done"] {
        let d = if sub.is_empty() { dir.to_path_buf() } else { dir.join(sub) };
        let Ok(entries) = fs::read_dir(&d) else { continue };
        let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        for n in names {
            let rel = if sub.is_empty() { n.clone() } else { format!("{sub}/{n}") };
            if is_task(&n) && dir.join(&rel).is_file() {
                out.push(rel);
            }
        }
    }
    out
}

fn hashes(repo: &Path, dir: &Path, paths: &[String]) -> HashMap<String, String> {
    let mut m = HashMap::new();
    if paths.is_empty() {
        return m;
    }
    let input = paths.iter().map(|r| dir.join(r).to_string_lossy().into_owned()).collect::<Vec<_>>().join("\n") + "\n";
    let out = Git::new(repo).run(&["hash-object", "-w", "--stdin-paths"], Some(&input)).unwrap_or_default();
    for (r, sha) in paths.iter().zip(out.trim().split('\n')) {
        m.insert(r.clone(), sha.to_string());
    }
    m
}

fn created(text: &str) -> String {
    record::parse(text).map(|d| d.text("created")).unwrap_or_default()
}

fn updated(text: &str) -> String {
    record::parse(text).map(|d| d.text("updated")).unwrap_or_default()
}

/// With the path and the creation date: with the path alone, a new task
/// reusing the name of an archived one would be deleted everywhere as soon
/// as it was born.
fn removal_key(path: &str, text: &str) -> String {
    format!("{path} {}", created(text)).trim().to_string()
}

fn is_removed(removed: &BTreeSet<String>, path: &str, text: &str) -> bool {
    removed.contains(&removal_key(path, text)) || (created(text).is_empty() && removed.contains(path))
}

fn read_removed(text: &str) -> BTreeSet<String> {
    text.split('\n').map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect()
}

pub fn record_removal(project_dir: &Path, path: &str, text: &str) {
    let _ = files::mkdir_private(project_dir);
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(project_dir.join(REMOVED)) {
        let _ = f.write_all(format!("{}\n", removal_key(path, text)).as_bytes());
    }
}

fn write_local(file: &Path, content: &str) {
    if let Some(d) = file.parent() {
        let _ = files::mkdir_private(d);
    }
    let _ = files::write_atomic(file, content, Some(0o600));
}

/// What each file last looked like when synced: without it "I changed it"
/// cannot be told from "they changed it there".
fn base_file(p: &str) -> PathBuf {
    state_dir().join(format!("{p}.json"))
}

fn pending_file(p: &str) -> PathBuf {
    state_dir().join(format!("{p}.pending"))
}

fn read_base(p: &str) -> HashMap<String, String> {
    files::read_json(&base_file(p))
        .ok()
        .and_then(|v| v.as_object().cloned())
        .map(|m| m.into_iter().filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string()))).collect())
        .unwrap_or_default()
}

fn save_base(p: &str, map: &BTreeMap<String, String>) {
    let _ = files::mkdir_private(&state_dir());
    let obj: Map<String, Value> = map.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
    // One-space indentation: the format earlier kernels wrote and still read.
    let text = serde_json::to_string_pretty(&Value::Object(obj)).unwrap_or_default();
    let text =
        crate::regex!(r"(?m)^( +)").replace_all(&text, |c: &regex::Captures| " ".repeat(c[1].len() / 2)).into_owned();
    write_local(&base_file(p), &text);
}

pub fn mark_pending(p: &str) {
    let _ = files::mkdir_private(&state_dir());
    let _ = fs::write(pending_file(p), chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
}

fn conflict_copy(local: &Path, who: &str) -> PathBuf {
    let text = local.to_string_lossy();
    let stem = text.strip_suffix(".md").unwrap_or(&text);
    PathBuf::from(format!("{stem}.conflict-{who}.md"))
}

fn machine() -> String {
    let h = env::hostname();
    let short = h.split('.').next().unwrap_or("");
    let clean: String = short.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    if clean.is_empty() {
        "machine".into()
    } else {
        clean
    }
}

struct Merged {
    commit: Option<String>,
    fin: BTreeMap<String, String>,
    /// Paths written here after the merge looked at them: left as they are,
    /// and their base kept, so the next round sees the change.
    unsettled: BTreeSet<String>,
    warnings: Vec<String>,
    pulled: u32,
    published: u32,
}

/// The base to remember after a merge: what was synced, except the paths
/// written meanwhile, which keep the base they had.
fn settled_base(p: &str, m: &Merged) -> BTreeMap<String, String> {
    let old = read_base(p);
    let mut base = m.fin.clone();
    for path in &m.unsettled {
        match old.get(path) {
            Some(b) => base.insert(path.clone(), b.clone()),
            None => base.remove(path),
        };
    }
    base
}

fn merge(p: &str, repo: &Path) -> Result<Merged, String> {
    let dir = env::tasks_dir().join(p);
    let mut warnings = vec![];
    let (mut pulled, mut published) = (0, 0);
    let (head, remote_files) = remote_tree(repo);
    let base = read_base(p);
    let locals = hashes(repo, &dir, &local_files(&dir));
    if env::in_tests() {
        if let Some(ms) = env::var("CRUX_TEST_SYNC_PAUSE_MS").and_then(|v| v.parse().ok()) {
            std::thread::sleep(std::time::Duration::from_millis(ms));
        }
    }
    // A task is written without this lock, while a sync may take seconds: what
    // is about to be replaced is looked at again, and a newer write wins.
    let mut unsettled = BTreeSet::new();
    let still = |path: &str, seen: Option<&String>| -> bool {
        hashes(repo, &dir, &[path.to_string()]).get(path) == seen || (seen.is_none() && !dir.join(path).exists())
    };

    let local_removed = files::read_or_empty(&dir.join(REMOVED));
    let remote_removed = remote_files.get(REMOVED).map(|s| blob(repo, s)).unwrap_or_default();
    let mut removed: BTreeSet<String> =
        read_removed(&local_removed).into_iter().chain(read_removed(&remote_removed)).collect();

    let mut fin = BTreeMap::new();
    let mut paths: BTreeSet<String> = locals.keys().cloned().chain(remote_files.keys().cloned()).collect();
    paths.remove(REMOVED);

    for path in paths {
        let mut l = locals.get(&path).cloned();
        let mut r = remote_files.get(&path).cloned();
        let b = base.get(&path).cloned();
        let local = dir.join(&path);

        // Each version is looked at separately: the local one may be the task
        // that was archived and the remote one a new task with the same name.
        if l.is_some() && is_removed(&removed, &path, &files::read_or_empty(&local)) {
            if b.is_some() && l != b {
                let aside = conflict_copy(&local, &machine());
                write_local(&aside, &files::read_or_empty(&local));
                warnings
                    .push(format!("{p}/{path}: it was archived on another machine and had changes here — saved aside"));
            }
            let _ = fs::remove_file(&local);
            l = None;
        }
        if let Some(rs) = &r {
            if is_removed(&removed, &path, &blob(repo, rs)) {
                r = None;
            }
        }
        match (&l, &r) {
            (None, None) => continue,
            (Some(a), Some(b2)) if a == b2 => {
                fin.insert(path, a.clone());
            }
            (Some(a), None) => {
                fin.insert(path, a.clone());
                published += 1;
            }
            (None, Some(rs)) => {
                if b.as_ref() == Some(rs) {
                    // Synced and no longer here: deleted by hand. Respected and
                    // noted, so it does not come back.
                    removed.insert(removal_key(&path, &blob(repo, rs)));
                    continue;
                }
                if !still(&path, None) {
                    unsettled.insert(path.clone());
                    fin.insert(path, rs.clone());
                    continue;
                }
                write_local(&local, &blob(repo, rs));
                fin.insert(path, rs.clone());
                pulled += 1;
            }
            (Some(ls), Some(rs)) => {
                if Some(ls) == b.as_ref() {
                    if !still(&path, Some(ls)) {
                        unsettled.insert(path.clone());
                        fin.insert(path, rs.clone());
                        continue;
                    }
                    write_local(&local, &blob(repo, rs));
                    fin.insert(path, rs.clone());
                    pulled += 1;
                } else if Some(rs) == b.as_ref() {
                    fin.insert(path, ls.clone());
                    published += 1;
                } else {
                    // Changed on both. The most recent wins; the other stays alongside.
                    let local_text = files::read_or_empty(&local);
                    let remote_text = blob(repo, rs);
                    let remote_wins = updated(&remote_text) > updated(&local_text) && still(&path, Some(ls));
                    let loser = if remote_wins { &local_text } else { &remote_text };
                    let suffix = if remote_wins { machine() } else { "remote".into() };
                    let aside = conflict_copy(&local, &suffix);
                    write_local(&aside, loser);
                    if remote_wins {
                        write_local(&local, &remote_text);
                        fin.insert(path.clone(), rs.clone());
                        pulled += 1;
                    } else {
                        fin.insert(path.clone(), ls.clone());
                        published += 1;
                    }
                    warnings.push(format!("{p}/{path}: changed on both machines — the most recent stays and the other is alongside as .conflict-"));
                }
            }
        }
    }

    // What is removed travels as a list, not as an absence.
    let removed_text =
        removed.iter().cloned().collect::<Vec<_>>().join("\n") + if removed.is_empty() { "" } else { "\n" };
    if !removed.is_empty() {
        let _ = files::mkdir_private(&dir);
        write_local(&dir.join(REMOVED), &removed_text);
    }

    let index = std::env::temp_dir().join(format!(
        "crux-task-sync-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_millis()
    ));
    let index_s = index.to_string_lossy().into_owned();
    let result = (|| {
        let g = Git::with(repo, &[("GIT_INDEX_FILE", &index_s)]);
        let mut entries: Vec<(String, String)> = fin.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        if !removed.is_empty() {
            let sha = Git::new(repo).run(&["hash-object", "-w", "--stdin"], Some(&removed_text))?.trim().to_string();
            entries.push((REMOVED.into(), sha));
        }
        g.run(&["read-tree", "--empty"], None)?;
        if !entries.is_empty() {
            let input =
                entries.iter().map(|(r, sha)| format!("100644 {sha}\t{r}")).collect::<Vec<_>>().join("\n") + "\n";
            g.run(&["update-index", "--add", "--index-info"], Some(&input))?;
        }
        let tree = g.run(&["write-tree"], None)?.trim().to_string();
        let current_tree = match &head {
            Some(h) => Some(Git::new(repo).run(&["rev-parse", &format!("{h}^{{tree}}")], None)?.trim().to_string()),
            None => None,
        };
        let mut commit = None;
        if Some(&tree) != current_tree.as_ref() && !entries.is_empty() {
            let msg = format!("[skip ci] tasks: {}", machine());
            let mut args = vec!["commit-tree", "--no-gpg-sign", tree.as_str()];
            if let Some(h) = &head {
                args.push("-p");
                args.push(h);
            }
            args.push("-m");
            args.push(&msg);
            let author = Git::with(
                repo,
                &[
                    ("GIT_INDEX_FILE", &index_s),
                    ("GIT_AUTHOR_NAME", "crux"),
                    ("GIT_AUTHOR_EMAIL", "crux@localhost"),
                    ("GIT_COMMITTER_NAME", "crux"),
                    ("GIT_COMMITTER_EMAIL", "crux@localhost"),
                ],
            );
            commit = Some(author.run(&args, None)?.trim().to_string());
        }
        Ok::<_, String>(commit)
    })();
    let _ = fs::remove_file(&index);
    let commit = result?;
    Ok(Merged { commit, fin, unsettled, warnings, pulled, published })
}

pub(super) fn live_workspaces() -> BTreeSet<String> {
    let r = files::read_json(&env::registry_file()).ok();
    r.and_then(|v| v.get("workspaces").and_then(Value::as_object).cloned())
        .map(|m| {
            m.into_iter()
                .filter(|(_, w)| {
                    w.get("path").and_then(Value::as_str).is_some_and(|p| !p.is_empty() && Path::new(p).exists())
                })
                .map(|(n, _)| n)
                .collect()
        })
        .unwrap_or_default()
}

/// A task whose proposal is merged outside `crux merge` would stay "proposed"
/// forever. GitHub is asked about those with a proposal: they are marked, and
/// without a live workspace here, archived. Without gh, nothing is touched.
pub fn reconcile(p: &str) -> Vec<String> {
    let dir = env::tasks_dir().join(p);
    let Ok(entries) = fs::read_dir(&dir) else { return vec![] };
    let cache = state_dir().join("pr-state.json");
    let mut seen = files::read_json(&cache).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default();
    let live = live_workspaces();
    let mut done = vec![];
    let now = chrono::Utc::now().timestamp_millis();
    let mut names: Vec<String> = entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    for n in names {
        if !is_task(&n) {
            continue;
        }
        let f = dir.join(&n);
        let Ok(mut doc) = record::read(&f) else { continue };
        let pr = doc.text("pr");
        if pr.is_empty() || !matches!(doc.status(), Some(record::Status::Verified | record::Status::Proposed)) {
            continue;
        }
        // An open proposal is looked at again every six hours at most.
        if seen.get(&pr).and_then(Value::as_i64).is_some_and(|t| now - t < 6 * 3_600_000) {
            continue;
        }
        let mut c = Command::new("gh");
        c.args(["pr", "view", &pr, "--json", "state", "--jq", ".state"]);
        let r = crate::sh::with_timeout(&mut c, 15);
        if !r.ok() {
            break;
        }
        seen.insert(pr.clone(), json!(now));
        if r.stdout.trim() != "MERGED" {
            continue;
        }
        record::advance(&mut doc, record::Status::Merged);
        let _ = record::write(&f, &mut doc, false);
        let alive = doc.list("workspaces").iter().any(|w| live.contains(w));
        if !alive {
            let _ = record::archive(&f, false);
        }
        done.push(format!(
            "{p}/{}: its proposal was already merged — {}",
            doc.text("task"),
            if alive { "marked" } else { "archived" }
        ));
    }
    let _ = files::mkdir_private(&state_dir());
    write_local(&cache, &Value::Object(seen).to_string());
    done
}

struct ProjectLock(PathBuf);

impl Drop for ProjectLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Per project: the background publication of a write and that of `crux sync`
/// cannot merge at once over the same state.
fn lock(p: &str) -> Result<ProjectLock, String> {
    let _ = files::mkdir_private(&state_dir());
    let dir = state_dir().join(format!("{p}.lock"));
    let mut i = 0;
    loop {
        if fs::create_dir(&dir).is_ok() {
            return Ok(ProjectLock(dir));
        }
        let old = fs::metadata(&dir)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|e| e.as_secs() > 120);
        if old {
            let _ = fs::remove_dir_all(&dir);
            continue;
        }
        i += 1;
        if i > 600 {
            return Err(format!("{p}: another task sync does not finish"));
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

/// One trip to the remote: each costs seconds over ssh. The error tells a
/// branch that does not exist yet from having no network.
fn fetch_branch(repo: &Path) -> &'static str {
    let Some(url) = origin_url(repo, false) else { return "offline" };
    match Git::new(repo)
        .run(&["fetch", "-q", "--no-write-fetch-head", &url, &format!("+refs/heads/{BRANCH}:{TRACK_REF}")], None)
    {
        Ok(_) => "ok",
        Err(e) if e.to_lowercase().contains("couldn't find remote ref") => {
            let _ = Git::new(repo).run(&["update-ref", "-d", TRACK_REF], None);
            "no-branch"
        }
        Err(_) => "offline",
    }
}

/// `crux sync` fetches every remote by name: what it brought is copied into
/// the sync's own ref.
/// What `crux sync` already fetched, unless it is older than what this
/// machine last saw: a publication made while crux sync ran moves TRACK_REF
/// on, and going back to the earlier fetch would bring old tasks back.
fn adopt_fetched(repo: &Path) -> &'static str {
    let g = Git::new(repo);
    let verify = |r: &str| g.get(&["rev-parse", "-q", "--verify", r]).filter(|s| !s.is_empty());
    let Some(fetched) = verify(REMOTE_REF) else { return fetch_branch(repo) };
    let newer_known = verify(TRACK_REF).is_some_and(|known| {
        known == fetched || g.run(&["merge-base", "--is-ancestor", &fetched, &known], None).is_ok()
    });
    if !newer_known {
        let _ = g.run(&["update-ref", TRACK_REF, &fetched], None);
    }
    "ok"
}

fn result(p: &str, status: &str) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("project".into(), json!(p));
    m.insert("status".into(), json!(status));
    m
}

fn ok_result(p: &str, pulled: u32, published: u32, warnings: Vec<String>) -> Map<String, Value> {
    let mut m = result(p, "ok");
    m.insert("pulled".into(), json!(pulled));
    m.insert("published".into(), json!(published));
    m.insert("warnings".into(), json!(warnings));
    m
}

pub fn sync_project(p: &str, already_fetched: bool) -> Result<Map<String, Value>, String> {
    let Some(repo) = transport(p) else { return Ok(result(p, "no-transport")) };
    let preference = contract_preference(&repo)?;
    let never = |status: &str| {
        let _ = fs::remove_file(pending_file(p));
        Ok(result(p, status))
    };
    if preference == Some(false) {
        return never("disabled");
    }
    if origin_url(&repo, false).is_none() {
        return never("no-remote");
    }
    if preference != Some(true) {
        match visibility(&repo).as_str() {
            "public" => return never("public"),
            "unknown" => {
                mark_pending(p);
                return Ok(result(p, "unchecked"));
            }
            _ => {}
        }
    }
    let _guard = lock(p)?;
    // Removed before starting: a write during the sync marks it again.
    let _ = fs::remove_file(pending_file(p));
    let mut last_warnings = vec![];
    for attempt in 0..4 {
        // On the first round what `crux sync` fetched is enough; if the remote
        // turns out to have moved on, the next round goes and gets it.
        let fetched = if already_fetched && attempt == 0 { adopt_fetched(&repo) } else { fetch_branch(&repo) };
        if fetched == "offline" {
            mark_pending(p);
            return Ok(result(p, "offline"));
        }
        let has_branch =
            Git::new(&repo).get(&["rev-parse", "-q", "--verify", TRACK_REF]).is_some_and(|s| !s.is_empty());
        if !has_branch && !env::tasks_dir().join(p).exists() {
            return Ok(ok_result(p, 0, 0, vec![]));
        }
        let m = merge(p, &repo)?;
        last_warnings = m.warnings.clone();
        let settled = settled_base(p, &m);
        let Some(commit) = &m.commit else {
            save_base(p, &settled);
            return Ok(ok_result(p, m.pulled, m.published, m.warnings));
        };
        // No hooks: the branch is internal, and a docs repo's pre-push has
        // nothing to say about it.
        let push_url = origin_url(&repo, true).unwrap_or_default();
        if Git::new(&repo)
            .run(&["push", "-q", "--no-verify", &push_url, &format!("{commit}:refs/heads/{BRANCH}")], None)
            .is_ok()
        {
            let _ = Git::new(&repo).run(&["update-ref", TRACK_REF, commit], None);
            save_base(p, &settled);
            return Ok(ok_result(p, m.pulled, m.published, m.warnings));
        }
        // Another machine published in between: pull and merge again.
    }
    mark_pending(p);
    let mut r = result(p, "rejected");
    r.insert("warnings".into(), json!(last_warnings));
    Ok(r)
}

/// Those with tasks here, all those with a docs repo —on a machine that is
/// arriving their tasks exist only on the remote— and standalone repos whose
/// tasks branch the `crux sync` fetch already brought.
pub fn projects_with_tasks() -> Vec<String> {
    let mut p = BTreeSet::new();
    if let Ok(entries) = fs::read_dir(env::tasks_dir()) {
        for e in entries.flatten() {
            if e.path().is_dir() {
                p.insert(e.file_name().to_string_lossy().into_owned());
            }
        }
    }
    let root = env::projects_root();
    if let Ok(entries) = fs::read_dir(&root) {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if p.contains(&n) || n.contains("-ws-") {
                continue;
            }
            if is_repo(&root.join(&n).join(format!("{n}-docs"))) {
                p.insert(n);
                continue;
            }
            if let Some(repo) = transport(&n) {
                let g = Git::new(&repo);
                if [REMOTE_REF, TRACK_REF]
                    .iter()
                    .any(|r| g.get(&["rev-parse", "-q", "--verify", r]).is_some_and(|s| !s.is_empty()))
                {
                    p.insert(n);
                }
            }
        }
    }
    p.into_iter().collect()
}

/// A marker whose project is no longer here can never be published from
/// here: it is dropped instead of being reported on every `sync --leave`.
pub fn pending_projects() -> Vec<String> {
    let Ok(entries) = fs::read_dir(state_dir()) else { return vec![] };
    let mut out = vec![];
    for e in entries.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let Some(p) = n.strip_suffix(".pending") else { continue };
        if transport(p).is_none() {
            let _ = fs::remove_file(e.path());
            continue;
        }
        out.push(p.to_string());
    }
    out.sort();
    out
}

/// After each write: publish without making the writer wait. The pending
/// mark goes first, in this process, so that if the publication never runs
/// —offline, powered off— `crux sync --leave` knows.
pub fn publish_in_background(file: &Path) {
    if env::in_tests() && env::var("CRUX_TASK_SYNC").as_deref() != Some("1") {
        return;
    }
    if env::var("CRUX_TASK_SYNC").as_deref() == Some("0") {
        return;
    }
    let mut dir = file.parent().unwrap_or(Path::new("/")).to_path_buf();
    if dir.file_name().is_some_and(|n| n == "done") {
        dir = dir.parent().unwrap_or(Path::new("/")).to_path_buf();
    }
    if dir.parent() != Some(crate::project::normalize(&env::tasks_dir()).as_path())
        && dir.parent() != Some(env::tasks_dir().as_path())
    {
        return;
    }
    let p = files::name(&dir);
    mark_pending(&p);
    if let Ok(exe) = std::env::current_exe() {
        let mut c = Command::new(exe);
        c.args(["__task-sync", "sync", "--project", &p])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // Its own session: it must outlive the command and the terminal.
        // SAFETY: setsid is async-signal-safe and runs in the child before exec.
        unsafe {
            use std::os::unix::process::CommandExt;
            c.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        let _ = c.spawn();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflict_copies_are_not_tasks_in_either_spelling() {
        assert!(is_task("checkout.md"));
        for copy in ["checkout.conflict-remote.md", "checkout.conflict-laptop.md", "checkout.conflicto-remota.md"] {
            assert!(is_conflict_copy(copy), "{copy}");
            assert!(!is_task(copy), "{copy}");
        }
        assert_eq!(
            conflict_copy(Path::new("/t/checkout.md"), "remote"),
            PathBuf::from("/t/checkout.conflict-remote.md")
        );
    }
}
