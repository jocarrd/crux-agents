//! A task record: one markdown file with a header per task.
//!
//! The commands write it, not the agent by hand: a checkbox or a status that
//! depends on someone remembering to edit a file ends up lying. See ADR-012.
//! The file is the source of truth; its replica in the docs repo is written
//! by `task::sync` from it. See ADR-016.

use crate::files;
use regex::Regex;
use std::path::{Path, PathBuf};

/// Where a task is in its life, in the order it goes through them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Open,
    Planned,
    InProgress,
    Verified,
    Proposed,
    Merged,
    Deployed,
    Closed,
}

impl Status {
    pub const ALL: [Status; 8] = [
        Status::Open,
        Status::Planned,
        Status::InProgress,
        Status::Verified,
        Status::Proposed,
        Status::Merged,
        Status::Deployed,
        Status::Closed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Open => "open",
            Status::Planned => "planned",
            Status::InProgress => "in-progress",
            Status::Verified => "verified",
            Status::Proposed => "proposed",
            Status::Merged => "merged",
            Status::Deployed => "deployed",
            Status::Closed => "closed",
        }
    }

    pub fn parse(text: &str) -> Option<Status> {
        Status::ALL.into_iter().find(|s| s.as_str() == text)
    }

    /// Still work to do: up to the proposal; from the merge on it is done.
    pub fn is_open(self) -> bool {
        self < Status::Merged
    }

    pub fn valid_list() -> String {
        Status::ALL.map(Status::as_str).join(", ")
    }
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// In the order of the task's life: what is wanted, what is done, what is
/// decided along the way and what was checked.
pub const SECTIONS: [(&str, &str); 8] = [
    ("Objective", "One sentence: what is to be achieved and why."),
    ("Scope", "What is in and what stays out."),
    ("Plan", "Only if the task needs it: what changes, the trace, what breaks, alternatives and doubts."),
    ("Steps", ""),
    ("Next step", ""),
    ("Deviations and decisions", "What came out different from the plan and what was decided with the code in front."),
    ("Verification", ""),
    ("Closure", ""),
];

/// Records written before the headings went English: read as their English
/// equivalent and rewritten in English.
fn canonical(title: &str) -> String {
    match title {
        "Objetivo" => "Objective",
        "Alcance" => "Scope",
        "Pasos" => "Steps",
        "Siguiente paso" => "Next step",
        "Desviaciones y decisiones" => "Deviations and decisions",
        "Verificación" | "Verificacion" => "Verification",
        "Cierre" => "Closure",
        other => other,
    }
    .to_string()
}

/// With seconds: the creation date identifies an archived task, and two
/// tasks with the same name can be created in the same minute.
pub fn now() -> String {
    chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string()
}

#[derive(Debug, Clone, PartialEq)]
pub enum Meta {
    Text(String),
    List(Vec<String>),
}

impl Meta {
    pub fn text(&self) -> String {
        match self {
            Meta::Text(t) => t.clone(),
            Meta::List(l) => l.join(","),
        }
    }
    pub fn list(&self) -> Vec<String> {
        match self {
            Meta::List(l) => l.clone(),
            Meta::Text(t) if !t.is_empty() => vec![t.clone()],
            Meta::Text(_) => vec![],
        }
    }
}

#[derive(Debug, Clone)]
pub struct Section {
    pub title: String,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Doc {
    /// In the order they were written: a hand-added key keeps its place.
    pub meta: Vec<(String, Meta)>,
    pub sections: Vec<Section>,
    pub preamble: Vec<String>,
}

impl Doc {
    pub fn get(&self, k: &str) -> Option<&Meta> {
        self.meta.iter().find(|(key, _)| key == k).map(|(_, v)| v)
    }
    pub fn text(&self, k: &str) -> String {
        self.get(k).map(Meta::text).unwrap_or_default()
    }
    /// Only a value written as a list counts as one, as it always has.
    pub fn list(&self, k: &str) -> Vec<String> {
        match self.get(k) {
            Some(Meta::List(l)) => l.clone(),
            _ => vec![],
        }
    }
    pub fn set(&mut self, k: &str, v: Meta) {
        match self.meta.iter_mut().find(|(key, _)| key == k) {
            Some(slot) => slot.1 = v,
            None => self.meta.push((k.to_string(), v)),
        }
    }
    pub fn status(&self) -> Option<Status> {
        Status::parse(&self.text("status"))
    }

    pub fn set_text(&mut self, k: &str, v: &str) {
        self.set(k, Meta::Text(v.to_string()));
    }
    pub fn remove(&mut self, k: &str) {
        self.meta.retain(|(key, _)| key != k);
    }
    pub fn section(&self, title: &str) -> Option<&Section> {
        self.sections.iter().find(|s| s.title == title)
    }
    fn section_mut(&mut self, title: &str) -> &mut Section {
        let name = canonical(title);
        if let Some(i) = self.sections.iter().position(|s| s.title == name) {
            return &mut self.sections[i];
        }
        self.sections.push(Section { title: name, lines: vec![] });
        self.sections.last_mut().unwrap()
    }
}

pub fn parse(text: &str) -> Result<Doc, String> {
    let re = crate::regex!(r"^---\n([\s\S]*?)\n---\n?");
    let m = re.captures(text).ok_or("the record has no header")?;
    let kv = crate::regex!(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$");
    let mut doc = Doc::default();
    for line in m[1].split('\n') {
        let Some(c) = kv.captures(line) else { continue };
        let v = c[2].trim();
        let value = if let Some(inner) = v.strip_prefix('[') {
            let inner = if inner.is_empty() { inner } else { &inner[..inner.len() - 1] };
            Meta::List(inner.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect())
        } else {
            Meta::Text(v.to_string())
        };
        doc.set(&c[1], value);
    }
    let body = &text[m.get(0).unwrap().end()..];
    let heading = crate::regex!(r"^## (.+)$");
    let fence = crate::regex!(r"^\s*(```|~~~)");
    // A `## ` inside a code block is text, not a heading.
    let mut in_code = false;
    for line in body.split('\n') {
        if fence.is_match(line) {
            in_code = !in_code;
        }
        match (in_code, heading.captures(line)) {
            (false, Some(h)) => doc.sections.push(Section { title: canonical(h[1].trim()), lines: vec![] }),
            _ => match doc.sections.last_mut() {
                Some(s) => s.lines.push(line.to_string()),
                None => doc.preamble.push(line.to_string()),
            },
        }
    }
    while doc.preamble.last().is_some_and(|l| l.trim().is_empty()) {
        doc.preamble.pop();
    }
    while doc.preamble.first().is_some_and(|l| l.trim().is_empty()) {
        doc.preamble.remove(0);
    }
    Ok(doc)
}

fn trim_lines(lines: &[String]) -> &[String] {
    let start = lines.iter().position(|l| !l.trim().is_empty()).unwrap_or(lines.len());
    let end = lines.iter().rposition(|l| !l.trim().is_empty()).map(|i| i + 1).unwrap_or(start);
    &lines[start..end.max(start)]
}

pub fn render(doc: &Doc) -> String {
    let order = ["task", "project", "status", "repos", "workspaces", "branches", "created", "updated", "pr"];
    let mut keys: Vec<&str> = order.iter().copied().filter(|k| doc.get(k).is_some()).collect();
    keys.extend(doc.meta.iter().map(|(k, _)| k.as_str()).filter(|k| !order.contains(k)));
    let header = keys
        .iter()
        .map(|k| match doc.get(k).unwrap() {
            Meta::List(l) => format!("{k}: [{}]", l.join(", ")),
            Meta::Text(t) => format!("{k}: {t}"),
        })
        .collect::<Vec<_>>()
        .join("\n");
    let body = doc
        .sections
        .iter()
        .map(|s| {
            let lines = trim_lines(&s.lines);
            format!("## {}\n\n{}{}", s.title, lines.join("\n"), if lines.is_empty() { "" } else { "\n" })
        })
        .collect::<Vec<_>>()
        .join("\n");
    let previous = if doc.preamble.is_empty() { String::new() } else { format!("{}\n\n", doc.preamble.join("\n")) };
    format!("---\n{header}\n---\n\n{previous}{body}")
}

pub fn read(file: &Path) -> Result<Doc, String> {
    if !file.exists() {
        return Err(format!("the record {} does not exist", file.display()));
    }
    parse(&std::fs::read_to_string(file).map_err(|e| e.to_string())?)
}

/// 700 and 600: the record holds the objective, decisions and evidence of
/// tasks for different clients.
pub fn write(file: &Path, doc: &mut Doc, publish: bool) -> Result<(), String> {
    doc.set_text("updated", &now());
    if let Some(d) = file.parent() {
        files::mkdir_private(d).map_err(|e| e.to_string())?;
    }
    files::write_atomic(file, &render(doc), Some(0o600)).map_err(|e| e.to_string())?;
    if publish {
        super::sync::publish_in_background(file);
    }
    Ok(())
}

/// A section with only its help comment is empty.
pub fn content(s: Option<&Section>) -> String {
    let text = s.map(|s| s.lines.join("\n")).unwrap_or_default();
    crate::regex!(r"<!--[\s\S]*?-->").replace_all(&text, "").trim().to_string()
}

pub fn first_line(t: &str) -> String {
    t.split('\n').next().unwrap_or("").to_string()
}

#[derive(Debug, Clone)]
pub struct Step {
    pub id: String,
    pub done: bool,
    pub text: String,
}

pub fn steps(doc: &Doc) -> Vec<Step> {
    let re = crate::regex!(r"^- \[( |x)\] (T\d+) (.*)$");
    doc.section("Steps")
        .map(|s| {
            s.lines
                .iter()
                .filter_map(|l| re.captures(l))
                .map(|c| Step { id: c[2].to_string(), done: &c[1] == "x", text: c[3].to_string() })
                .collect()
        })
        .unwrap_or_default()
}

/// Statuses only advance on their own. Going back is a decision and is asked
/// for with `crux task status`. An unknown status written by hand is behind
/// every known one.
pub fn advance(doc: &mut Doc, status: Status) {
    if doc.status().is_none_or(|current| status > current) {
        doc.set_text("status", status.as_str());
    }
}

// --- Waiting ------------------------------------------------------------------
//
// Waiting on someone is not one more step: a task can be merged and still
// pending an answer, so it has its own fields. See ADR-017.

fn one_line(t: &str) -> String {
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    let t = t.strip_prefix('[').map(|r| format!("({r}")).unwrap_or(t);
    t.strip_suffix(']').map(|r| format!("{r})")).unwrap_or(t)
}

pub fn set_waiting(doc: &mut Doc, on: &str, ask: &str, reference: &str, since: Option<&str>) -> Result<(), String> {
    if one_line(on).is_empty() {
        return Err("missing who is being waited on: --on \"<who>\"".into());
    }
    if one_line(ask).is_empty() {
        return Err("missing what was asked: --ask \"<what>\"".into());
    }
    doc.set_text("waiting_on", &one_line(on));
    doc.set_text("waiting_ask", &one_line(ask));
    let since = since
        .map(String::from)
        .filter(|s| !s.is_empty())
        .or_else(|| Some(doc.text("waiting_since")).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| now()[..10].to_string());
    doc.set_text("waiting_since", &since);
    if one_line(reference).is_empty() {
        doc.remove("waiting_ref");
    } else {
        doc.set_text("waiting_ref", &one_line(reference));
    }
    Ok(())
}

pub fn clear_waiting(doc: &mut Doc) -> bool {
    let had = !doc.text("waiting_on").is_empty();
    for k in ["waiting_on", "waiting_ask", "waiting_since", "waiting_ref"] {
        doc.remove(k);
    }
    had
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Waiting {
    pub on: String,
    pub ask: String,
    pub since: String,
    #[serde(rename = "ref")]
    pub reference: String,
}

pub fn waiting_of(doc: &Doc) -> Option<Waiting> {
    let on = doc.text("waiting_on");
    if on.is_empty() {
        return None;
    }
    Some(Waiting {
        on,
        ask: doc.text("waiting_ask"),
        since: doc.text("waiting_since"),
        reference: doc.text("waiting_ref"),
    })
}

/// A branch deleted when the task goes into waiting is not lost: it is noted
/// as retired so `workspace resume` opens a new one instead of reporting it.
pub fn retire_branch(doc: &mut Doc, repo: &str, branch: &str, workspace: &str) {
    let prefix = format!("{repo}=");
    let mut retired: Vec<String> = doc.get("retired").map(Meta::list).unwrap_or_default();
    retired.retain(|e| !e.starts_with(&prefix));
    retired.push(format!("{repo}={branch}"));
    doc.set("retired", Meta::List(retired));
    let branches = doc
        .get("branches")
        .map(Meta::list)
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !e.starts_with(&prefix))
        .collect();
    doc.set("branches", Meta::List(branches));
    if !workspace.is_empty() {
        let ws =
            doc.get("workspaces").map(Meta::list).unwrap_or_default().into_iter().filter(|w| w != workspace).collect();
        doc.set("workspaces", Meta::List(ws));
    }
}

pub fn reopen_branch(doc: &mut Doc, repo: &str) {
    let prefix = format!("{repo}=");
    let retired: Vec<String> = doc
        .get("retired")
        .map(Meta::list)
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !e.starts_with(&prefix))
        .collect();
    if retired.is_empty() {
        doc.remove("retired");
    } else {
        doc.set("retired", Meta::List(retired));
    }
}

// --- Operations ---------------------------------------------------------------

pub fn create(task: &str, project: &str, repo: &str, workspace: &str) -> Doc {
    let today = now();
    let list = |v: &str| Meta::List(if v.is_empty() { vec![] } else { vec![v.to_string()] });
    Doc {
        meta: vec![
            ("task".into(), Meta::Text(task.into())),
            ("project".into(), Meta::Text(project.into())),
            ("status".into(), Meta::Text(Status::Open.as_str().into())),
            ("repos".into(), list(repo)),
            ("workspaces".into(), list(workspace)),
            ("created".into(), Meta::Text(today.clone())),
            ("updated".into(), Meta::Text(today)),
        ],
        sections: SECTIONS
            .iter()
            .map(|(t, help)| Section {
                title: t.to_string(),
                lines: if help.is_empty() { vec![] } else { vec![format!("<!-- {help} -->")] },
            })
            .collect(),
        preamble: vec![],
    }
}

pub fn join(doc: &mut Doc, repo: &str, workspace: &str) {
    for (key, value) in [("repos", repo), ("workspaces", workspace)] {
        if value.is_empty() {
            continue;
        }
        let mut list = doc.list(key);
        if !list.iter().any(|x| x == value) {
            list.push(value.to_string());
        }
        doc.set(key, Meta::List(list));
    }
}

pub fn set_section(doc: &mut Doc, title: &str, text: &str) {
    doc.section_mut(title).lines = text.split('\n').map(String::from).collect();
}

/// Trailing blank lines in a section are formatting, not content: if they
/// stay, each new item shows up separated from the previous one.
fn truncate(s: &mut Section) {
    while s.lines.last().is_some_and(|l| l.trim().is_empty()) {
        s.lines.pop();
    }
}

pub fn append(doc: &mut Doc, title: &str, text: &str) {
    let comment = crate::regex!(r"^<!--.*-->$");
    let s = doc.section_mut(title);
    truncate(s);
    s.lines.retain(|l| !comment.is_match(l.trim()));
    s.lines.push(format!("- {text}"));
}

/// A decision carries its why, and optionally where it lives and what was
/// learned, on a single line so the record stays a list.
pub fn decision_line(what: &str, why: &str, where_: &str, learned: &str) -> String {
    let mut parts = vec![what.to_string()];
    if !why.is_empty() {
        parts.push(format!("Why: {why}"));
    }
    if !where_.is_empty() {
        parts.push(format!("Where: {where_}"));
    }
    if !learned.is_empty() {
        parts.push(format!("Learned: {learned}"));
    }
    parts.retain(|p| !p.is_empty());
    parts.join(" · ")
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Decision {
    pub what: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    #[serde(rename = "where", skip_serializing_if = "Option::is_none")]
    pub where_: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub learned: Option<String>,
}

/// Notes with a why are decisions: they have to outlast the task.
pub fn decisions(doc: &Doc) -> Vec<Decision> {
    let field = crate::regex!(r"^(Why|Where|Learned): (.*)$");
    content(doc.section("Deviations and decisions"))
        .split('\n')
        .filter(|l| l.starts_with("- ") && l.contains(" · Why: "))
        .map(|l| {
            let mut parts = l[2..].split(" · ");
            let mut d =
                Decision { what: parts.next().unwrap_or("").to_string(), why: None, where_: None, learned: None };
            for c in parts {
                if let Some(m) = field.captures(c) {
                    let v = Some(m[2].to_string());
                    match &m[1] {
                        "Why" => d.why = v,
                        "Where" => d.where_ = v,
                        _ => d.learned = v,
                    }
                }
            }
            d
        })
        .collect()
}

pub fn add_step(doc: &mut Doc, text: &str) -> String {
    let n = steps(doc).iter().filter_map(|p| p.id[1..].parse::<u32>().ok()).max().unwrap_or(0) + 1;
    let s = doc.section_mut("Steps");
    truncate(s);
    s.lines.push(format!("- [ ] T{n} {text}"));
    format!("T{n}")
}

pub fn complete(doc: &mut Doc, id: &str, evidence: &str) -> Result<(), String> {
    let re = Regex::new(&format!(r"^- \[( |x)\] {} ", regex::escape(id))).unwrap();
    let old_evidence = crate::regex!(r" · (?:evidencia|evidence): .*$");
    let s = doc.section_mut("Steps");
    let i = s.lines.iter().position(|l| re.is_match(l)).ok_or_else(|| format!("there is no step {id}"))?;
    let mut line = match s.lines[i].strip_prefix("- [ ]") {
        Some(rest) => format!("- [x]{rest}"),
        None => s.lines[i].clone(),
    };
    if !evidence.is_empty() {
        line = format!("{} · evidence: {evidence}", old_evidence.replace(&line, ""));
    }
    s.lines[i] = line;
    advance(doc, Status::InProgress);
    Ok(())
}

/// The gate receipt is the evidence of what was checked: dumped as is,
/// because summarising is where what was not run sneaks in.
pub fn verify(doc: &mut Doc, receipt: &str, sha: &str) {
    let re = crate::regex!(r"^run (\S+) (\S+) (.*)$");
    let runs: Vec<String> = receipt
        .split('\n')
        .filter_map(|l| re.captures(l))
        .map(|c| {
            format!(
                "- {} · {} ({}s)",
                if &c[1] == "0" { "ok".to_string() } else { format!("exit {}", &c[1]) },
                &c[3],
                &c[2]
            )
        })
        .collect();
    let short: String = sha.chars().take(8).collect();
    let mut lines = vec![format!("On {short}:"), String::new()];
    lines.extend(runs);
    set_section(doc, "Verification", &lines.join("\n"));
    advance(doc, Status::Verified);
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Summary {
    pub task: String,
    pub status: String,
    pub steps: String,
    pub next: String,
    pub objective: String,
    pub waiting: Option<Waiting>,
}

pub fn summary(doc: &Doc) -> Summary {
    let ps = steps(doc);
    let done = ps.iter().filter(|p| p.done).count();
    let next = first_line(&content(doc.section("Next step")));
    let pending = ps.iter().find(|p| !p.done);
    Summary {
        task: doc.text("task"),
        status: doc.text("status"),
        steps: if ps.is_empty() { String::new() } else { format!("{done}/{}", ps.len()) },
        next: if !next.is_empty() { next } else { pending.map(|p| format!("{} {}", p.id, p.text)).unwrap_or_default() },
        objective: first_line(&content(doc.section("Objective"))),
        waiting: waiting_of(doc),
    }
}

/// The proposal description comes from the record but does not quote it: in
/// a client's repo we do not show how we work inside. Without an objective,
/// what changes is told by the commits.
pub fn proposal_body(doc: &Doc, language: &str, commits: &str) -> String {
    let home = crate::env::var("HOME");
    let user_path = crate::regex!(r"/(home|Users)/[A-Za-z0-9._-]+");
    // The machine path is stripped from the whole body: each step's evidence
    // is where absolute paths get pasted most.
    let without_paths = |t: &str| {
        let v = match &home {
            Some(h) => t.split(h.as_str()).collect::<Vec<_>>().join("~"),
            None => t.to_string(),
        };
        user_path.replace_all(&v, "~").into_owned()
    };
    let (changes, scope, done_t, decisions_t, checked_t) = if language == "es" {
        ("Qué cambia", "Alcance", "Hecho", "Decisiones", "Comprobado")
    } else {
        ("What changes", "Scope", "Done", "Decisions", "Checked")
    };
    let block =
        |title: &str, text: String| if text.is_empty() { String::new() } else { format!("## {title}\n\n{text}\n") };
    let sec = |title: &str| content(doc.section(title));
    // The evidence goes in parentheses and without the label: the label is in
    // the record's language, and the description may be in another.
    let evidence = crate::regex!(r" · (?:evidencia|evidence): (.*)$");
    let done = steps(doc)
        .iter()
        .filter(|p| p.done)
        .map(|p| format!("- {}", evidence.replace(&p.text, " ($1)")))
        .collect::<Vec<_>>()
        .join("\n");
    let checked = sec("Verification").split('\n').filter(|l| l.starts_with("- ")).collect::<Vec<_>>().join("\n");
    let objective = sec("Objective");
    let blocks = [
        block(changes, without_paths(if objective.is_empty() { commits } else { &objective })),
        block(scope, without_paths(&sec("Scope"))),
        block(done_t, without_paths(&done)),
        block(decisions_t, without_paths(&sec("Deviations and decisions"))),
        block(checked_t, without_paths(&checked)),
    ];
    blocks.into_iter().filter(|b| !b.is_empty()).collect::<Vec<_>>().join("\n")
}

/// Archiving is closing and setting aside: the record stops showing in lists
/// but is kept, dated, until it expires.
pub fn archive(file: &Path, publish: bool) -> Result<PathBuf, String> {
    let mut doc = read(file)?;
    let today = now()[..10].to_string();
    doc.set_text("status", Status::Closed.as_str());
    set_section(&mut doc, "Closure", &format!("closed {today}"));
    let dir = file.parent().unwrap_or(Path::new("."));
    let name = files::name(file);
    let target = dir.join("done").join(format!("{today}-{name}"));
    if target.exists() {
        return Err(format!("a file with that name already exists: {}", target.display()));
    }
    write(&target, &mut doc, false)?;
    std::fs::remove_file(file).map_err(|e| e.to_string())?;
    // Without noting it, the other machine would upload the task as open
    // again: an absence does not tell "archived here" from "not arrived yet".
    super::sync::record_removal(dir, &name, &render(&doc));
    if publish {
        super::sync::publish_in_background(&target);
    }
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statuses_round_trip_and_only_advance() {
        for s in Status::ALL {
            assert_eq!(Status::parse(s.as_str()), Some(s));
        }
        assert_eq!(Status::parse("waiting"), None);
        assert!(Status::Proposed.is_open() && !Status::Merged.is_open());
        let mut doc = create("t", "p", "app", "t");
        doc.set_text("status", Status::Proposed.as_str());
        advance(&mut doc, Status::Planned);
        assert_eq!(doc.status(), Some(Status::Proposed), "it does not go back");
        advance(&mut doc, Status::Merged);
        assert_eq!(doc.status(), Some(Status::Merged));
    }

    #[test]
    fn a_record_survives_a_round_trip() {
        let mut d = create("t", "p", "app", "t");
        add_step(&mut d, "first");
        append(&mut d, "Deviations and decisions", &decision_line("x", "because", "", ""));
        let text = render(&d);
        let back = parse(&text).unwrap();
        assert_eq!(render(&back), text);
        assert_eq!(decisions(&back)[0].why.as_deref(), Some("because"));
    }

    #[test]
    fn a_heading_inside_code_is_text() {
        let d = parse("---\ntask: t\n---\n\n## Plan\n\n```\n## not a heading\n```\n").unwrap();
        assert_eq!(d.sections.len(), 1);
    }
}
