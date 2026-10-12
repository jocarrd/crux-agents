//! `crux review scope [base]`: a proposal's risk, the specialist reviewers it
//! deserves and who merges it.
//!
//! One reviewer per specialty costs tens of thousands of tokens each. Launched
//! on every proposal, reviewing stops by the third week; never launched, the
//! general review misses what only someone who knows where to look sees. The
//! specialists come from the diff, not from whim.

use crate::files::glob_match;
use crate::git;
use crate::names;
use std::path::{Path, PathBuf};

/// How much ceremony the project asks for, declared in its contract.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Rigor {
    Light,
    Normal,
    Strict,
}

impl Rigor {
    fn parse(text: &str) -> Option<Rigor> {
        match text {
            "light" => Some(Rigor::Light),
            "normal" => Some(Rigor::Normal),
            "strict" => Some(Rigor::Strict),
            _ => None,
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            Rigor::Light => "light",
            Rigor::Normal => "normal",
            Rigor::Strict => "strict",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Risk {
    Low,
    Medium,
    High,
}

impl Risk {
    fn as_str(self) -> &'static str {
        match self {
            Risk::Low => "low",
            Risk::Medium => "medium",
            Risk::High => "high",
        }
    }
}

/// The specialties, in the order they are offered; each keeps the first
/// reason found, which is the one shown.
#[derive(Default)]
struct Reasons {
    security: Option<String>,
    data: Option<String>,
    performance: Option<String>,
    interface: Option<String>,
}

fn note(slot: &mut Option<String>, why: impl Into<String>) {
    slot.get_or_insert_with(|| why.into());
}

const DEPENDENCIES: &[&str] = &[
    "package.json",
    "*/package.json",
    "*lock.json",
    "*lock.yaml",
    "*.lock",
    "go.mod",
    "Cargo.toml",
    "requirements*.txt",
    "*/requirements*.txt",
    "pyproject.toml",
    "*/pyproject.toml",
    "Gemfile",
];
const TEXT: &[&str] = &["*.md", "*.mdx", "*.txt", "LICENSE", ".gitignore"];
const TESTS: &[&str] =
    &["*_test.*", "*.test.*", "*.spec.*", "*/tests/*", "*/test/*", "*/__tests__/*", "tests/*", "test/*"];
const LOCKFILES: &[&str] = &["*lock.json", "*lock.yaml", "*.lock"];
/// Compared in lower case.
const SENSITIVE: &[&str] = &[
    "*auth*",
    "*login*",
    "*session*",
    "*token*",
    "*jwt*",
    "*password*",
    "*permission*",
    "*role*",
    "*acl*",
    "*crypto*",
    "*secret*",
    "*middleware*",
    "*cors*",
    "*csrf*",
    "*webhook*",
    "*upload*",
    ".env*",
    "*/.env*",
];
const SCHEMA: &[&str] = &["*/migrations/*", "*schema.prisma", "*.sql", "*.entity.*", "*/models/*", "*/entities/*"];
const SERVER: &[&str] = &[
    "*/api/*",
    "*/routes/*",
    "*/server/*",
    "*/handlers/*",
    "*/workers/*",
    "*/jobs/*",
    "*/cron/*",
    "*/queue*",
    "*.repository.*",
    "*/repositories/*",
    "next.config.*",
    "vite.config.*",
    "webpack.config.*",
];
const INTERFACE: &[&str] =
    &["*.tsx", "*.jsx", "*.vue", "*.svelte", "*.css", "*.scss", "*.html", "*/components/*", "*/pages/*", "*/styles/*"];

fn any(patterns: &[&str], f: &str) -> bool {
    patterns.iter().any(|p| glob_match(p, f))
}

/// Lines added plus removed, in the numstat of `git diff`; binary files ("-")
/// count as nothing.
fn numstat_lines(line: &str) -> usize {
    line.split('\t').take(2).map(|n| n.parse::<usize>().unwrap_or(0)).sum()
}

fn default_base(repo: &Path) -> Option<String> {
    if let Some(r) = git::out(repo, &["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]) {
        return Some(r.trim_start_matches("refs/remotes/").to_string());
    }
    ["origin/main", "origin/master", "main", "master"]
        .into_iter()
        .find(|c| git::ok(repo, &["rev-parse", "--verify", "--quiet", c]))
        .map(String::from)
}

/// The contract that rules where this runs: the first crux.json walking up, in
/// the directory itself or in a sibling docs repo.
fn contract_from(start: &Path) -> Option<PathBuf> {
    start.ancestors().filter(|d| d.parent().is_some()).find_map(|d| {
        let own = d.join(names::CONTRACT);
        if own.is_file() {
            return Some(own);
        }
        let mut docs: Vec<PathBuf> = std::fs::read_dir(d)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.to_string_lossy().ends_with("-docs") && p.join(names::CONTRACT).is_file())
            .map(|p| p.join(names::CONTRACT))
            .collect();
        docs.sort();
        docs.into_iter().next()
    })
}

/// The report for the diff between `base` and HEAD in `repo`, read with the
/// contract found from `start`. Err is what stops it: no base, or a rigor the
/// standard does not know.
pub fn report(repo: &Path, start: &Path, base: Option<&str>) -> Result<String, String> {
    let base = match base.filter(|b| !b.is_empty()).map(String::from).or_else(|| default_base(repo)) {
        Some(b) if git::ok(repo, &["rev-parse", "--verify", "--quiet", &b]) => b,
        b => {
            return Err(format!(
                "cannot find the base branch '{}' — pass it as an argument",
                b.as_deref().unwrap_or("?")
            ))
        }
    };
    let range = format!("{base}...HEAD");
    let files: Vec<String> = git::out(repo, &["diff", "--name-only", &range])
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();
    if files.is_empty() {
        return Ok(format!("risk: none — no changes against {base}\nspecialists: none\n"));
    }

    let (mut code, mut code_lines, mut not_text) = (0, 0, 0);
    let mut why = Reasons::default();
    for f in &files {
        // Dependencies go before text: `requirements.txt` ends in .txt, and as
        // documentation a new dependency would merge without asking.
        if any(DEPENDENCIES, f) {
            note(
                &mut why.security,
                format!("dependencies change ({f}): where they come from and what they run on install"),
            );
        } else if any(TEXT, f) {
            continue;
        } else if any(TESTS, f) {
            // A test calls for no specialist, but it is code the CI runs with
            // its secrets at hand: it is not text when deciding who merges.
            not_text += 1;
            continue;
        }
        not_text += 1;
        code += 1;
        if !any(LOCKFILES, f) {
            code_lines += git::out(repo, &["diff", "--numstat", &range, "--", f])
                .unwrap_or_default()
                .lines()
                .map(numstat_lines)
                .sum::<usize>();
        }
        if any(SENSITIVE, &f.to_lowercase()) {
            note(&mut why.security, format!("touches a sensitive path: {f}"));
        }
        if any(SCHEMA, f) {
            note(&mut why.data, format!("touches the schema or the models: {f}"));
        }
        if any(SERVER, f) {
            note(&mut why.performance, format!("touches server or build code: {f}"));
        }
        if any(INTERFACE, f) {
            note(&mut why.interface, format!("touches the interface: {f}"));
        }
    }

    // What the added content says, not just the path: a query built from a
    // string gets in just the same in a file called utils.ts. Tests are left
    // out: a test that checks a DROP TABLE is detected contains one.
    let not_content = crate::regex!(r"\.(md|mdx|txt)$|_test\.|\.test\.|\.spec\.|(^|/)(tests?|__tests__)/");
    let content: Vec<&str> = files.iter().map(String::as_str).filter(|f| !not_content.is_match(f)).collect();
    let added: Vec<String> = if content.is_empty() {
        vec![]
    } else {
        let mut args = vec!["diff", range.as_str(), "--"];
        args.extend(&content);
        git::out(repo, &args)
            .unwrap_or_default()
            .lines()
            .filter(|l| l.starts_with('+') && !l.starts_with("+++"))
            .map(String::from)
            .collect()
    };
    let adds = |rx: &regex::Regex| added.iter().any(|l| rx.is_match(l));
    if adds(crate::regex!(
        r"eval\(|new Function\(|dangerouslySetInnerHTML|innerHTML *=|child_process|execSync|shell *= *True|Set-Cookie|Authorization"
    )) {
        note(&mut why.security, "the diff adds a sensitive construct (execution, raw HTML, session headers)");
    }
    if adds(crate::regex!(r"(?i)alter table|drop table|drop column|create table|deleteMany|truncate")) {
        note(&mut why.data, "the diff adds operations that change or delete data");
    }
    // Not readFileSync: in scripts and terminal tools reading a file
    // synchronously is normal; server code is recognised by its path.
    if adds(crate::regex!(r"findMany\(|SELECT .* FROM|\.map\(async|Promise\.all\(|setInterval\(")) {
        note(&mut why.performance, "the diff adds queries or async loops");
    }

    // Lockfiles are regenerated whole: counted, any dependency update would
    // be a "big change".
    let lockfile = crate::regex!(r"(lock\.json|lock\.yaml|\.lock)$");
    let total_lines: usize = git::out(repo, &["diff", "--numstat", &range])
        .unwrap_or_default()
        .lines()
        .filter(|l| !lockfile.is_match(l))
        .map(numstat_lines)
        .sum();

    // The project declares its rigor. What has no contract is not registered,
    // and what is not registered is not treated as critical.
    let contract = contract_from(start);
    let read = contract.as_deref().map(|c| crate::files::read_json(c).ok());
    let (profile, rigor_text, origin, unreadable) = match (&contract, read) {
        (Some(c), Some(Some(json))) => {
            let field = |k: &str| crate::files::get(&json, k).map(crate::files::value_text).unwrap_or_default();
            let rigor = field("rigor");
            if rigor.is_empty() {
                (field("profile"), "normal".to_string(), "default: the project does not declare it".to_string(), false)
            } else {
                (field("profile"), rigor, format!("declared in {}", c.display()), false)
            }
        }
        (Some(_), _) => (String::new(), "normal".into(), "crux.json cannot be read".into(), true),
        (None, _) => {
            let root = git::toplevel(repo);
            // The kernel has no crux.json because it is not a project, but
            // every project consumes it.
            if root.as_deref().is_some_and(|r| r.join(names::STANDARD).is_file() && r.join("bin/crux").is_file()) {
                (String::new(), "normal".into(), "the kernel itself, which every project consumes".into(), false)
            } else {
                (String::new(), "light".into(), "no crux.json: project not registered".into(), false)
            }
        }
    };
    let Some(rigor) = Rigor::parse(&rigor_text) else {
        return Err(format!("unknown rigor '{rigor_text}' ({origin}) — valid values are light, normal or strict"));
    };

    // High if what can go wrong does not show in a screenshot: security and
    // data break silently. Low if there is no code, or the change is so small
    // the general review covers it; in strict there is no size shortcut.
    let risk = if code == 0 {
        Risk::Low
    } else if why.security.is_some() || why.data.is_some() || total_lines > 500 {
        Risk::High
    } else if code_lines <= 30 && rigor != Rigor::Strict {
        Risk::Low
    } else {
        Risk::Medium
    };

    let mut out = format!(
        "base: {base}\nchange: {} files, {total_lines} lines ({code_lines} of code)\nrisk: {}\nrigor: {} — {origin}\n",
        files.len(),
        risk.as_str(),
        rigor.as_str()
    );
    // In light, specialists are reserved for what breaks silently.
    let wanted = risk == Risk::High || (risk == Risk::Medium && rigor != Rigor::Light);
    let list: Vec<(&str, String)> = if wanted {
        [("security", why.security), ("data", why.data), ("performance", why.performance), ("interface", why.interface)]
            .into_iter()
            .filter_map(|(name, reason)| reason.map(|r| (name, r)))
            .collect()
    } else {
        vec![]
    };
    // Three at most: beyond that they overlap and the cost grows without findings.
    if list.is_empty() {
        if risk == Risk::Medium && rigor == Rigor::Light {
            out.push_str("specialists: none — rigor light, the general review is enough\n");
        } else {
            out.push_str("specialists: none — the general review is enough\n");
        }
    } else {
        let shown = &list[..list.len().min(3)];
        out.push_str(&format!("specialists: {}\n", shown.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", ")));
        for (name, reason) in shown {
            out.push_str(&format!("  - {name}: {reason}\n"));
        }
        if list.len() > 3 {
            let left: Vec<&str> = list[3..].iter().map(|(n, _)| *n).collect();
            out.push_str(&format!("  - (left out: {}), covered by the general review\n", left.join(",")));
        }
    }

    // In a client repo a person always decides: the cost of being wrong is not
    // paid by whoever merges. Elsewhere the rigor moves the threshold.
    let merge = if unreadable {
        "a person decides — the project's crux.json cannot be read".to_string()
    } else if profile == "client-repo" || rigor == Rigor::Strict {
        "a person decides".to_string()
    } else if not_text == 0 {
        "can be merged without asking — text only".to_string()
    } else if rigor == Rigor::Light && risk != Risk::High {
        format!("can be merged without asking — rigor light and risk {}", risk.as_str())
    } else {
        "a person decides".to_string()
    };
    out.push_str(&format!("merge: {merge}\n"));
    Ok(out)
}
