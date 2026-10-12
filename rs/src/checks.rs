//! The checks `doctor` runs over a docs repo, each usable on its own: the ADR
//! registry, markdown links, skill descriptions, credentials, stale runbooks
//! and the drift between code and documentation.

use crate::names;
use crate::{files, secrets};
use regex::Regex;
use std::path::{Path, PathBuf};

fn walk(dir: &Path, skip: &dyn Fn(&str) -> bool) -> Vec<PathBuf> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if skip(&name) {
                continue;
            }
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

fn rel(base: &Path, p: &Path) -> String {
    p.strip_prefix(base).map(|r| r.to_string_lossy().into_owned()).unwrap_or_else(|_| p.to_string_lossy().into_owned())
}

// --- ADRs ---------------------------------------------------------------------

struct Adr {
    num: String,
    line: usize,
    status: Option<String>,
}

/// Templates live inside ``` blocks in the ledger itself: an example
/// `- **Status**: Proposed | Accepted` is not a violation.
fn adr_entries(file: &Path) -> Vec<Adr> {
    let head = crate::regex!(r"^### ADR-(\d+)\s*:");
    let status = crate::regex!(r"^-\s+\*\*Status\*\*:\s*(.+?)\s*$");
    let mut out: Vec<Adr> = vec![];
    let (mut fenced, mut commented) = (false, false);
    for (i, line) in files::read_or_empty(file).split('\n').enumerate() {
        if line.starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if line.contains("<!--") {
            commented = true;
        }
        if commented {
            if line.contains("-->") {
                commented = false;
            }
            continue;
        }
        if fenced {
            continue;
        }
        if let Some(h) = head.captures(line) {
            out.push(Adr { num: h[1].to_string(), line: i + 1, status: None });
            continue;
        }
        if let (Some(s), Some(adr)) = (status.captures(line), out.last_mut()) {
            if adr.status.is_none() {
                adr.status = Some(s[1].to_string());
            }
        }
    }
    out
}

/// Warnings and problems; problems fail the check.
pub fn decisions(docs: &Path) -> (Vec<String>, Vec<String>) {
    let mut ledgers = vec![];
    let index = docs.join("decisions/index.md");
    if index.is_file() {
        ledgers.push(index);
    }
    let mut repos: Vec<PathBuf> = crate::project::subdirs(&docs.join("repos"))
        .into_iter()
        .map(|r| docs.join("repos").join(r).join("decisions.md"))
        .filter(|p| p.is_file())
        .collect();
    repos.sort();
    ledgers.extend(repos);
    let (mut notes, mut problems) = (vec![], vec![]);
    let plain = ["Open", "Proposed", "Accepted", "Inherited", "Deprecated"];
    let with_ref = ["Superseded", "Amended"];
    let toc = crate::regex!(r"(?m)^\|\s*ADR-\d+\s*\|");
    let refs_re = crate::regex!(r"((?:[\w.-]+/)*)ADR-(\d+)");
    let by = crate::regex!(r"^\s*by\b");
    let and = crate::regex!(r"\band\b");
    let separators = crate::regex!(r"[\s,y]+");
    for file in &ledgers {
        let where_ = rel(docs, file);
        let found = adr_entries(file);
        // The warning goes away once the ledger opens with its table: one that
        // stays after being complied with teaches people to ignore warnings.
        if where_ == "decisions/index.md" && found.len() > 30 && !toc.is_match(&files::read_or_empty(file)) {
            notes.push(format!("{where_}: {} ADRs — over 30, open the ledger with a table of contents", found.len()));
        }
        let mut seen: Vec<(String, usize)> = vec![];
        for adr in &found {
            match seen.iter().find(|(n, _)| *n == adr.num) {
                Some((_, first)) => problems.push(format!(
                    "{where_}:{} duplicate ADR: ADR-{} (already on line {first}) — renumber the newest",
                    adr.line, adr.num
                )),
                None => seen.push((adr.num.clone(), adr.line)),
            }
        }
        for adr in &found {
            let Some(status) = &adr.status else {
                problems.push(format!("{where_}:{} ADR-{} has no Status", adr.line, adr.num));
                continue;
            };
            let Some(keyword) = with_ref.iter().find(|k| status.starts_with(*k)) else {
                if !plain.contains(&status.as_str()) {
                    problems.push(format!("{where_}:{} ADR-{} unrecognized Status: \"{status}\"", adr.line, adr.num));
                }
                continue;
            };
            let rest = &status[keyword.len()..];
            let rest = by.replace(rest, "").into_owned();
            let refs: Vec<(String, String)> = refs_re
                .captures_iter(&rest)
                .map(|c| (c[1].trim_end_matches('/').to_string(), c[2].to_string()))
                .collect();
            if refs.is_empty() {
                problems.push(format!(
                    "{where_}:{} ADR-{} \"{keyword}\" without saying which — the chain breaks there",
                    adr.line, adr.num
                ));
                continue;
            }
            // What is left after the references is prose: the why lives in the new ADR.
            let tail = refs_re.replace_all(&rest, "");
            let tail = and.replace_all(&tail, " ");
            let tail = separators.replace_all(&tail, "");
            if !tail.is_empty() {
                problems.push(format!(
                    "{where_}:{} ADR-{} Status carries prose besides the state — move it to Consequences",
                    adr.line, adr.num
                ));
            }
            for (prefix, num) in refs {
                let target = if prefix.is_empty() {
                    Some(file.clone())
                } else {
                    [
                        docs.join(&prefix).join("index.md"),
                        docs.join(&prefix).join("decisions.md"),
                        docs.join(format!("{prefix}.md")),
                    ]
                    .into_iter()
                    .find(|p| p.exists())
                };
                let Some(target) = target else {
                    problems.push(format!(
                        "{where_}:{} ADR-{} points to \"{prefix}/ADR-{num}\" and that ledger does not exist",
                        adr.line, adr.num
                    ));
                    continue;
                };
                if !adr_entries(&target).iter().any(|e| e.num == num) {
                    problems.push(format!(
                        "{where_}:{} ADR-{} points to ADR-{num} in {} and it is not there",
                        adr.line,
                        adr.num,
                        rel(docs, &target)
                    ));
                }
            }
        }
    }
    (notes, problems)
}

// --- Markdown links -------------------------------------------------------------

/// Code blocks and inline code are blanked keeping offsets: the link regex
/// must not match inside syntax examples.
fn strip_code(md: &str) -> String {
    let fence = crate::regex!(r"```[\s\S]*?```");
    let out = fence
        .replace_all(md, |c: &regex::Captures| {
            c[0].chars().map(|ch| if ch == '\n' { '\n' } else { ' ' }).collect::<String>()
        })
        .into_owned();
    let inline = crate::regex!(r"`[^`\n]+`");
    inline.replace_all(&out, |c: &regex::Captures| " ".repeat(c[0].chars().count())).into_owned()
}

/// The report and the number of broken links.
pub fn doc_paths(target: &Path) -> (String, usize) {
    let files: Vec<PathBuf> = if target.is_dir() {
        walk(target, &|n| n.starts_with('.') || n == "node_modules")
            .into_iter()
            .filter(|p| p.extension().is_some_and(|x| x == "md"))
            .collect()
    } else {
        vec![target.to_path_buf()]
    };
    let base = if target.is_dir() { target.to_path_buf() } else { target.parent().unwrap().to_path_buf() };
    let link = crate::regex!(r"\[([^\]]+)\]\(([^)\s]+)\)");
    let mut out = String::new();
    let mut total = 0;
    for f in &files {
        let md = strip_code(&files::read_or_empty(f));
        let mut misses = vec![];
        for c in link.captures_iter(&md) {
            let url = &c[2];
            if url.starts_with("http://")
                || url.starts_with("https://")
                || url.starts_with('#')
                || url.starts_with("mailto:")
            {
                continue;
            }
            let clean = url.split('#').next().unwrap_or("");
            if clean.is_empty() {
                continue;
            }
            let line = md[..c.get(0).unwrap().start()].matches('\n').count() + 1;
            let t = crate::project::normalize(&f.parent().unwrap().join(clean));
            if !t.exists() {
                misses.push((clean.to_string(), line, t));
            }
        }
        if misses.is_empty() {
            continue;
        }
        out.push_str(&format!("\n{}:\n", rel(&base, f)));
        for (url, line, t) in misses {
            out.push_str(&format!("  L{line}: {url}\n         → {} (does not exist)\n", relative(&base, &t)));
            total += 1;
        }
    }
    out.push_str(&format!(
        "\n{} {total} {} in {} files.\n",
        if total == 0 { "✔" } else { "✘" },
        if total == 1 { "broken link" } else { "broken links" },
        files.len()
    ));
    (out, total)
}

/// A path relative to another, with `..` where it leaves it.
fn relative(base: &Path, p: &Path) -> String {
    let b: Vec<_> = base.components().collect();
    let t: Vec<_> = p.components().collect();
    let common = b.iter().zip(t.iter()).take_while(|(x, y)| x == y).count();
    let mut parts: Vec<String> = vec!["..".into(); b.len() - common];
    parts.extend(t[common..].iter().map(|c| c.as_os_str().to_string_lossy().into_owned()));
    parts.join("/")
}

// --- Skill descriptions ------------------------------------------------------------

/// Only the frontmatter: reading more lets the body contaminate the check.
fn description_of(text: &str) -> Option<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    if lines.first().map(|l| l.trim()) != Some("---") {
        return None;
    }
    let key = crate::regex!(r"^[a-z_-]+:");
    let mut out = vec![];
    let mut inside = false;
    for l in &lines[1..] {
        if l.trim() == "---" {
            break;
        }
        if let Some(d) = l.strip_prefix("description:") {
            inside = true;
            out.push(d.trim_start().to_string());
            continue;
        }
        if inside && key.is_match(l) {
            break;
        }
        if inside {
            out.push(l.to_string());
        }
    }
    Some(out.join(" ").split_whitespace().collect::<Vec<_>>().join(" "))
}

/// A skill is loaded whole every time it is used: above this, what is in
/// excess is almost always the why of each rule, which belongs in references/.
pub const MAX_WORDS: usize = 1000;

/// The description decides whether a skill activates. Errors if the skill
/// cannot be loaded, warnings if it loads but will not activate when it should.
pub fn skill_descriptions(root: &Path, language: &str) -> Vec<String> {
    if !root.exists() {
        return vec![];
    }
    let mut skills = vec![];
    fn visit(d: &Path, depth: usize, out: &mut Vec<PathBuf>) {
        if depth > 3 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(d) else { return };
        for e in entries.flatten() {
            let p = e.path();
            // A broken link is reported by `doctor --machine`.
            let Ok(meta) = std::fs::metadata(&p) else { continue };
            if meta.is_dir() {
                visit(&p, depth + 1, out);
            } else if e.file_name() == names::SKILL {
                out.push(p);
            }
        }
    }
    visit(root, 0, &mut skills);
    skills.sort();
    // Those that already exceeded the cap when the rule came in, with their
    // size then. The list only shrinks.
    let inherited: Vec<(String, usize)> = files::read_or_empty(&root.join(".oversized"))
        .lines()
        .filter_map(|l| {
            let l = l.split('#').next().unwrap_or("").trim();
            let mut f = l.split_whitespace();
            let (n, w) = (f.next()?, f.next()?);
            f.next().is_none().then(|| (n.to_string(), w.parse().ok())).and_then(|(n, w)| w.map(|w| (n, w)))
        })
        .collect();
    // A usage verb is what turns a description into a trigger.
    let triggers = crate::regex!(r"(?i)(?:^|[^\p{L}])(usa|use|[uú]sala|usar|invoca)(?:$|[^\p{L}])");
    let en = crate::regex!(r"(?i)\b(the|when|this|with|your|after|before|that|from|which)\b");
    let es = crate::regex!(r"(?i)\b(cuando|para|que|con|desde|antes|después|del|las|los|una)\b");
    let mut findings = vec![];
    for f in skills {
        let name = files::name(f.parent().unwrap());
        let text = files::read_or_empty(&f);
        if text.split('\n').next().map(str::trim) != Some("---") {
            findings.push(format!("error skill without frontmatter: {name}"));
            continue;
        }
        // Without the closing line the frontmatter is not valid YAML.
        if text.split('\n').filter(|l| *l == "---").count() < 2 {
            findings.push(format!("error skill with unclosed frontmatter: {name}"));
            continue;
        }
        if !text.lines().any(|l| l.starts_with("name:")) {
            findings.push(format!("error skill without 'name' in the frontmatter: {name}"));
        }
        if !text.lines().any(|l| l.starts_with("description:")) {
            findings.push(format!("error skill without 'description' in the frontmatter: {name}"));
            continue;
        }
        let name_re = Regex::new(&format!("(?m)^name: *{}$", regex::escape(&name))).unwrap();
        if !name_re.is_match(&text) {
            findings.push(format!("warning skill '{name}': the frontmatter 'name' does not match the directory"));
        }
        let n = text.split_whitespace().count();
        match inherited.iter().find(|(x, _)| *x == name) {
            Some((_, before)) if n > *before => findings.push(format!("warning skill '{name}': has grown to {n} words (it had {before} and already exceeded {MAX_WORDS}); move the why to references/")),
            Some(_) if n <= MAX_WORDS => findings.push(format!("warning skill '{name}': now fits in {MAX_WORDS} words ({n}); remove it from .oversized")),
            Some(_) => {}
            None if n > MAX_WORDS => findings.push(format!("warning skill '{name}': {n} words, the maximum is {MAX_WORDS}; leave the steps in SKILL.md and move the why to references/ (see /skill-creator)")),
            None => {}
        }
        let desc = description_of(&text).unwrap_or_default();
        if !triggers.is_match(&desc) {
            findings.push(format!(
                "warning skill '{name}': the description does not say when to use it — it will not activate on its own"
            ));
        }
        // The description has to be in the language the work is requested in.
        if language == "es" && en.find_iter(&desc).count() > es.find_iter(&desc).count() {
            findings.push(format!(
                "warning skill '{name}': the description seems to be in English and the catalog declares Spanish"
            ));
        }
    }
    findings
}

// --- Credentials -------------------------------------------------------------------

/// The value of an assignment: no odd signs, a mix of upper case, lower case
/// and digits, and long enough not to be a word.
fn looks_like_value(v: &str) -> bool {
    let n = v.chars().count();
    if !(12..=128).contains(&n) || v.contains([':', '/', '@', '\\']) {
        return false;
    }
    if !v.chars().any(|c| c.is_ascii_lowercase())
        || !v.chars().any(|c| c.is_ascii_uppercase())
        || !v.chars().any(|c| c.is_ascii_digit())
    {
        return false;
    }
    !crate::regex!(r"(?i)^(changeme|example|placeholder|password|secret|tu-|your-|xxx)").is_match(v)
}

/// KEY=value is the number one way of pasting a secret into a document;
/// checked outside and inside code blocks, since a pasted .env rarely carries
/// fences.
fn assignment_with_secret(line: &str) -> bool {
    let re = crate::regex!(r#"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*["']?([^"'\s]+)["']?$"#);
    let Some(m) = re.captures(line.trim()) else { return false };
    crate::regex!(r"(?i)(PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|AUTH|API)").is_match(&m[1])
        && looks_like_value(&m[2])
}

/// A loose password in a code block has no format to recognize: its shape is
/// examined. Hashes and identifiers are of a single class, and example ones
/// name themselves.
fn looks_like_password(line: &str) -> bool {
    let s = line.trim();
    let n = s.chars().count();
    if !(12..=64).contains(&n) || s.chars().any(char::is_whitespace) {
        return false;
    }
    let example = crate::regex!(
        r"(?i)(changeme|example|ejemplo|demo|dev|test|password|contrasena|contraseña|secret|xxxx|placeholder|your|tu-)"
    );
    if example.is_match(s) || s.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    if s.chars().any(|c| "\"'`:=,{}()[]<>;|/.@\\".contains(c)) {
        return false;
    }
    [
        s.chars().any(|c| c.is_ascii_lowercase()),
        s.chars().any(|c| c.is_ascii_uppercase()),
        s.chars().any(|c| c.is_ascii_digit()),
    ]
    .iter()
    .filter(|x| **x)
    .count()
        >= 3
}

/// The documentation and the .mcp.json files: generated, committed and read by
/// nobody, the combination by which a token reaches the history unnoticed.
pub fn secrets_in(docs: &Path) -> Vec<String> {
    let files: Vec<PathBuf> = walk(docs, &|n| n == ".git")
        .into_iter()
        .filter(|p| p.extension().is_some_and(|x| x == "md") || p.file_name().is_some_and(|n| n == ".mcp.json"))
        .collect();
    let mut findings = vec![];
    for f in files {
        let r = rel(docs, &f);
        let mut in_block = false;
        for (i, line) in files::read_or_empty(&f).split('\n').enumerate() {
            if line.trim_start().starts_with("```") {
                in_block = !in_block;
                continue;
            }
            for fp in secrets::fingerprints() {
                if fp.is_in(line) {
                    findings.push(format!("{r}:{} {}", i + 1, fp.name));
                }
            }
            if in_block && looks_like_password(line) {
                findings.push(format!("{r}:{} possible loose password", i + 1));
            } else if assignment_with_secret(line) {
                findings.push(format!("{r}:{} possible credential in an assignment", i + 1));
            }
        }
    }
    findings
}

// --- Stale runbooks ---------------------------------------------------------------

/// Only operations/: in architecture/ staleness shows when reading; in
/// operations/ it shows when the command fails with the system down.
pub fn staleness(docs: &Path, months: i64) -> Vec<String> {
    let dir = docs.join("operations");
    let files: Vec<PathBuf> =
        walk(&dir, &|_| false).into_iter().filter(|p| p.extension().is_some_and(|x| x == "md")).collect();
    let marker = crate::regex!(r"(?m)^>\s*(?:Última verificación|Last verified):\s*(\d{4}-\d{2}-\d{2})\s*$");
    let now = chrono::Utc::now();
    let limit = now - chrono::Duration::milliseconds(months * 30 * 24 * 3600 * 1000);
    let mut out = vec![];
    for f in files {
        let text = files::read_or_empty(&f);
        let Some(m) = marker.captures(&text) else { continue };
        let r = rel(docs, &f);
        let Ok(date) = chrono::NaiveDate::parse_from_str(&m[1], "%Y-%m-%d") else {
            out.push(format!("{r} has a verification date that cannot be understood: {}", &m[1]));
            continue;
        };
        let date = date.and_hms_opt(0, 0, 0).unwrap().and_utc();
        if date < limit {
            let days = ((now - date).num_milliseconds() as f64 / 86_400_000.0).round() as i64;
            out.push(format!("{r} unverified for {days} days"));
        }
    }
    out
}

// --- Drift between code and documentation ---------------------------------------
//
// It does not claim to know what is missing from the docs —git cannot say—,
// but whether the code has been moving without the docs moving.

fn last_commit(dir: &Path) -> i64 {
    crate::git::out(dir, &["log", "-1", "--format=%ct"]).and_then(|s| s.parse().ok()).unwrap_or(0)
}

/// In the code repo, untracked files are usually build noise; in the docs
/// repo a new untracked .md is freshly written documentation.
fn dirty(dir: &Path, include_new: bool) -> usize {
    crate::git::out(dir, &["status", "--porcelain"])
        .unwrap_or_default()
        .split('\n')
        .filter(|l| !l.trim().is_empty() && (!l.starts_with("??") || (include_new && l.trim().ends_with(".md"))))
        .count()
}

pub fn drift(docs: &Path) -> Vec<String> {
    let root = docs.parent().unwrap_or(Path::new("/"));
    let repos =
        files::read_json(&docs.join(names::CONTRACT)).ok().map(|c| files::str_list(c.get("repos"))).unwrap_or_default();
    let docs_last = last_commit(docs);
    let dirty_docs = dirty(docs, true);
    let mut out = vec![];
    for repo in repos {
        let dir = root.join(&repo);
        if !dir.join(".git").exists() {
            continue;
        }
        let last = last_commit(&dir);
        if last == 0 {
            continue;
        }
        // Strictly later: a code commit in the same second as the docs one is
        // the good case.
        let n: usize = if docs_last == 0 {
            0
        } else {
            crate::git::out(&dir, &["rev-list", "--count", &format!("--since=@{}", docs_last + 1), "HEAD"])
                .and_then(|s| s.parse().ok())
                .unwrap_or(0)
        };
        let pending = dirty(&dir, false);
        if n == 0 && pending == 0 {
            continue;
        }
        let mut parts = vec![];
        if n > 0 {
            parts.push(format!("{n} commit{} since the last docs one", if n == 1 { "" } else { "s" }));
        }
        if pending > 0 {
            parts.push(format!("{pending} file{} uncommitted", if pending == 1 { "" } else { "s" }));
        }
        let day =
            chrono::DateTime::from_timestamp(last, 0).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default();
        out.push(format!("{repo}: {} (last: {day})", parts.join(", ")));
    }
    if dirty_docs > 0 {
        out.push(format!(
            "{}: {dirty_docs} documentation file{} uncommitted",
            files::name(docs),
            if dirty_docs == 1 { "" } else { "s" }
        ));
    }
    out
}

/// `crux __check <name> <args>`: each check on its own, for the suite and for
/// the hooks that use one.
pub fn internal(argv: &[String]) -> crate::error::Res {
    let arg = |i: usize| PathBuf::from(argv.get(i).cloned().unwrap_or_default());
    match argv.first().map(String::as_str).unwrap_or("") {
        "decisions" => {
            let (notes, problems) = decisions(&arg(1));
            for n in &notes {
                println!("warning: {n}");
            }
            for p in &problems {
                println!("{p}");
            }
            if problems.is_empty() {
                Ok(())
            } else {
                crate::error::exit(1)
            }
        }
        "doc-paths" => {
            let (report, total) = doc_paths(&arg(1));
            print!("{report}");
            if total == 0 {
                Ok(())
            } else {
                crate::error::exit(1)
            }
        }
        "skill-description" => {
            for f in skill_descriptions(&arg(1), argv.get(2).map(String::as_str).unwrap_or("es")) {
                println!("{f}");
            }
            Ok(())
        }
        "secrets" => {
            for f in secrets_in(&arg(1)) {
                println!("{f}");
            }
            Ok(())
        }
        "staleness" => {
            let months = argv.get(2).and_then(|m| m.parse().ok()).unwrap_or(6);
            for f in staleness(&arg(1), months) {
                println!("{f}");
            }
            Ok(())
        }
        "drift" => {
            for f in drift(&arg(1)) {
                println!("{f}");
            }
            Ok(())
        }
        other => {
            eprintln!("unknown check: {other}");
            crate::error::exit(2)
        }
    }
}
