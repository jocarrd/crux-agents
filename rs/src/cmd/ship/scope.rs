//! `crux ship scope [base]`: classifies the diff and decides which gates of
//! the ship skill it needs.
//!
//! A gate that costs the same for a typo as for a schema change stops being
//! run within two weeks. This splits the cost: what cannot be wrong does not
//! pay for the correctness review, and what is not visible from outside does
//! not pay for bringing up the environment.

use crate::error::Res;
use crate::files::glob_match;
use crate::names;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const TESTS: &[&str] = &["*_test.*", "*.test.*", "*.spec.*", "*/tests/*", "*/test/*", "*/__tests__/*"];
const DEPS: &[&str] = &[
    "package.json",
    "*/package.json",
    "*lock.json",
    "*lock.yaml",
    "*.lock",
    "go.mod",
    "Cargo.toml",
    "requirements*.txt",
    "pyproject.toml",
];
const DOCS: &[&str] = &["*.md", "*.mdx", "*.txt", "LICENSE", ".gitignore"];
const DATA: &[&str] = &["*/migrations/*", "*schema.prisma", "*.sql"];
const UI: &[&str] = &[
    "*.tsx",
    "*.jsx",
    "*.vue",
    "*.svelte",
    "*.css",
    "*.scss",
    "*.html",
    "*/components/*",
    "*/pages/*",
    "*/app/*",
    "*/styles/*",
    "*/public/*",
];
const API: &[&str] = &[
    "*/api/*",
    "*/routes/*",
    "*/controllers/*",
    "*/handlers/*",
    "*.controller.*",
    "*/server/*",
    "*/endpoints/*",
    "*/infrastructure/http/*",
];
/// Layered architecture: the domain and the use cases are pure logic and tests
/// cover them; what talks to the world lives in infrastructure.
const LOGIC: &[&str] = &["*/domain/*", "*/application/*", "*/use-cases/*", "*/entities/*"];
const INTEGRATION: &[&str] =
    &["*/infrastructure/*", "*.adapter.*", "*.repository.*", "*/adapters/*", "*/repositories/*"];

fn any(patterns: &[&str], f: &str) -> bool {
    patterns.iter().any(|p| glob_match(p, f))
}

/// Where each changed file falls, in the order the report lists them.
#[derive(Default)]
struct Scope {
    ui: usize,
    api: usize,
    data: usize,
    tests: usize,
    docs: usize,
    deps: usize,
    logic: usize,
    integration: usize,
    other: usize,
}

/// Staged and unstaged changes against `base`, sorted and without repeats.
pub(super) fn changed_files(base: &str, diff_filter: Option<&str>) -> Vec<String> {
    let cwd = std::env::current_dir().unwrap_or_default();
    let mut args = vec!["diff", "--name-only"];
    if let Some(f) = diff_filter {
        args.push(f);
    }
    let mut cached = args.clone();
    args.push(base);
    cached.push("--cached");
    let mut files = BTreeSet::new();
    for a in [args, cached] {
        for l in crate::git::out(&cwd, &a).unwrap_or_default().lines().filter(|l| !l.is_empty()) {
            files.insert(l.to_string());
        }
    }
    files.into_iter().collect()
}

/// The contract that rules here: the first crux.json walking up, in the
/// directory itself or in a sibling docs repo.
fn contract_from(start: &Path) -> Option<PathBuf> {
    start.ancestors().find_map(|d| {
        let own = d.join(names::CONTRACT);
        if own.is_file() {
            return Some(own);
        }
        let mut docs: Vec<PathBuf> = std::fs::read_dir(d)
            .ok()?
            .flatten()
            .map(|e| e.path().join(names::CONTRACT))
            .filter(|c| c.parent().is_some_and(|p| p.to_string_lossy().ends_with("-docs")) && c.is_file())
            .collect();
        docs.sort();
        docs.into_iter().next()
    })
}

pub(super) fn run(argv: &[String]) -> Res {
    let base = argv.first().map(String::as_str).unwrap_or("HEAD");
    let files = changed_files(base, None);
    if files.is_empty() {
        println!("scope: empty");
        println!("runtime: no");
        println!("gates: none — nothing to review");
        return Ok(());
    }
    let mut s = Scope::default();
    let (mut touched_tests, mut touched_code) = (vec![], vec![]);
    for f in &files {
        if any(TESTS, f) {
            s.tests += 1;
            touched_tests.push(f.as_str());
            continue;
        }
        if any(DEPS, f) {
            s.deps += 1;
            continue;
        }
        if any(DOCS, f) {
            s.docs += 1;
            continue;
        }
        if any(DATA, f) {
            s.data += 1;
            continue;
        }
        touched_code.push(f.as_str());
        let bucket = if any(UI, f) {
            &mut s.ui
        } else if any(API, f) {
            &mut s.api
        } else if any(LOGIC, f) {
            &mut s.logic
        } else if any(INTEGRATION, f) {
            &mut s.integration
        } else {
            &mut s.other
        };
        *bucket += 1;
    }

    println!("files: {}", files.len());
    let parts: String = [
        ("ui", s.ui),
        ("api", s.api),
        ("data", s.data),
        ("tests", s.tests),
        ("docs", s.docs),
        ("deps", s.deps),
        ("logic", s.logic),
        ("integration", s.integration),
        ("other", s.other),
    ]
    .iter()
    .filter(|(_, n)| *n > 0)
    .map(|(k, n)| format!(" {k}:{n}"))
    .collect();
    println!("scope:{parts}");

    // The runtime is needed when the change can be seen from outside, or when
    // dependencies or the schema change: what breaks there is the startup.
    let observable = s.ui + s.api + s.data + s.deps + s.integration > 0;
    if observable {
        println!("runtime: yes");
        for (n, why) in [
            (s.ui, "touches the interface: visual review"),
            (s.api, "touches the API: test the affected endpoints"),
            (s.data, "touches data: verify the migration applies and reverts"),
            (s.deps, "dependencies change: check it starts from scratch"),
            (s.integration, "touches an integration: test against the real service, not only with doubles"),
        ] {
            if n > 0 {
                println!("  - {why}");
            }
        }
    } else {
        println!("runtime: no");
    }

    // Computed here and not left to whoever passes the gate: by eye everything
    // looks small, and that is how the gate that was needed gets skipped.
    let code = s.ui + s.api + s.data + s.logic + s.integration + s.other + s.tests;
    if code == 0 {
        println!("gates: 2,8,9");
        println!("  - text only: no code that can be wrong and no tests that can regress");
    } else if observable {
        println!("gates: all");
        println!("  - the change is visible from outside: gate 7 is not optional here");
    } else {
        println!("gates: 1,2,3,4,5,6,8,9");
        println!("  - nothing observable from outside: gate 7 is skipped");
    }

    // Gate 1 only asks whether the red was already there, and the affected
    // tests answer that; the whole suite is gate 5.
    let filter = if !touched_tests.is_empty() {
        touched_tests.iter().take(5).copied().collect::<Vec<_>>().join(" ")
    } else {
        let stems: BTreeSet<String> = touched_code
            .iter()
            .take(3)
            .map(|f| {
                let name = f.rsplit('/').next().unwrap_or(f);
                name.rsplit_once('.').map(|(a, _)| a).unwrap_or(name).to_string()
            })
            .collect();
        stems.into_iter().collect::<Vec<_>>().join(" ")
    };

    // The concrete command is the project's: the kernel does not know whether
    // pnpm, pytest or go test runs here.
    let contract = contract_from(&std::env::current_dir().unwrap_or_default());
    let field = |key: &str| -> String {
        contract
            .as_deref()
            .and_then(|c| crate::files::read_json(c).ok())
            .and_then(|j| crate::files::get(&j, key).map(crate::files::value_text))
            .unwrap_or_default()
    };
    let filtered = field("quality.testsFiltered");
    let command = if !filter.is_empty() && !filtered.is_empty() {
        filtered.replacen("{filtro}", &filter, 1).replacen("{filter}", &filter, 1)
    } else {
        field("quality.tests")
    };
    if code == 0 {
        println!("tests: none — the diff does not touch code");
    } else if !command.is_empty() {
        println!("tests: {command}");
    } else if !filter.is_empty() {
        println!("tests: filter by → {filter}");
        println!("  - declare 'quality.tests' and 'quality.testsFiltered' in crux.json for the exact command");
    } else {
        println!("tests: the project suite");
    }

    if s.docs == 0 && s.ui + s.api + s.data + s.logic > 0 {
        println!("doc: the change touches surface and no documentation is touched — check whether any has drifted");
    }

    // What sneaks in with a `git add -A`: screenshots a tool wrote into the
    // working directory, dumps, one-off files. No test or linter reports them.
    let loose = crate::regex!(r"^[^/]*\.(png|jpe?g|gif|webp|pdf|zip|tar|gz|mp4|log|tmp|bak|html)$");
    let suspects: Vec<&String> = files.iter().filter(|f| loose.is_match(f)).collect();
    if !suspects.is_empty() {
        println!("artifacts: loose files at the root that probably do not belong in the repo —");
        for f in suspects {
            println!("  - {f}");
        }
    }
    Ok(())
}
