//! `crux ship conventions [base]`: checks the diff against the project's
//! written conventions.
//!
//! Having them written down is not enough: they are read after writing the
//! code, when they only serve to reorder. This does not judge whether the diff
//! "follows the style" (such a judgement always says yes); it points at
//! concrete lines and leaves the verdict to whoever looks at them. The
//! universal signals live here; each project's own are declared in its
//! contract, because the kernel does not know how each one writes.

use super::scope::changed_files;
use crate::error::{exit, Res};
use crate::names;
use crate::{files, git};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The docs repo next to where this runs: here, one level up, or a sibling.
fn docs_repo(cwd: &Path) -> Option<PathBuf> {
    let parent = cwd.parent().unwrap_or(cwd);
    let mut siblings: Vec<PathBuf> = std::fs::read_dir(parent)
        .map(|e| e.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
        .unwrap_or_default();
    siblings.sort();
    [cwd.to_path_buf(), parent.to_path_buf()].into_iter().chain(siblings).find(|d| d.join(names::CONTRACT).is_file())
}

/// The lines the diff adds to these files, headers included.
fn added(base: &str, files: &[&str]) -> Vec<String> {
    let cwd = std::env::current_dir().unwrap_or_default();
    let mut out = vec![];
    for cached in [false, true] {
        let mut args = vec!["diff", "--unified=0"];
        if cached {
            args.push("--cached");
        } else {
            args.push(base);
        }
        args.push("--");
        args.extend(files);
        out.extend(git::out(&cwd, &args).unwrap_or_default().lines().filter(|l| l.starts_with('+')).map(String::from));
    }
    out
}

pub(super) fn run(argv: &[String]) -> Res {
    let base = argv.first().map(String::as_str).unwrap_or("HEAD");
    let cwd = std::env::current_dir().unwrap_or_default();
    let docs = docs_repo(&cwd);
    let source = crate::regex!(r"\.(ts|tsx|js|jsx|mjs|rs|go|py|rb|java|kt|swift|php)$");
    let test = crate::regex!(r"\.(test|spec)\.");
    let changed = changed_files(base, Some("--diff-filter=d"));
    let code: Vec<&str> =
        changed.iter().map(String::as_str).filter(|f| source.is_match(f) && !test.is_match(f)).collect();
    if code.is_empty() {
        println!("conventions: not applicable — the diff does not touch code");
        return Ok(());
    }

    println!("== Required reading ==");
    match docs.as_deref().filter(|d| d.join("conventions").is_dir()) {
        Some(d) => {
            let mut general: Vec<PathBuf> = std::fs::read_dir(d.join("conventions"))
                .map(|e| e.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "md")).collect())
                .unwrap_or_default();
            general.sort();
            for f in general {
                println!("  {}", f.display());
            }
            let repos: BTreeSet<&str> = code.iter().map(|f| f.split('/').next().unwrap_or(f)).collect();
            for r in repos {
                let own = d.join("repos").join(r).join("conventions.md");
                if own.is_file() {
                    println!("  {}", own.display());
                }
            }
        }
        None => println!("  (cannot find the documentation repo — look for conventions/ by hand)"),
    }

    println!();
    println!("== Signals ==");
    let mut findings = 0;
    let lines: Vec<String> = added(base, &code).into_iter().filter(|l| !l.starts_with("+++")).collect();

    let literal = crate::regex!(r#"'[A-Za-z][A-Za-z0-9 _-]{2,40}'|"[A-Za-z][A-Za-z0-9 _-]{2,40}""#);
    let directive = crate::regex!(r"use (client|server)");
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for l in &lines {
        for m in literal.find_iter(l).filter(|m| !directive.is_match(m.as_str())) {
            *counts.entry(m.as_str()).or_default() += 1;
        }
    }
    let mut repeated: Vec<(&str, usize)> = counts.into_iter().filter(|(_, n)| *n >= 3).collect();
    repeated.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.cmp(a.0)));
    if !repeated.is_empty() {
        println!("repeated literals — a dictionary?");
        for (text, n) in repeated.into_iter().take(8) {
            println!("  {n}x  {text}");
        }
        findings += 1;
    }

    // The expensive failure: two copies of a constant diverge and nobody
    // notices until a screen shows a value the other does not know.
    let declaration = crate::regex!(r"^\+ *(export )?(const|static|pub const) ([A-Z][A-Z0-9_]{2,}) *[:=]");
    let names: BTreeSet<&str> =
        lines.iter().filter_map(|l| declaration.captures(l).map(|c| c.get(3).map_or("", |m| m.as_str()))).collect();
    for n in names {
        let pattern = format!(r"(export |pub |static )?const {n}\b");
        let others: Vec<String> = git::out(&cwd, &["grep", "-lE", &pattern])
            .unwrap_or_default()
            .lines()
            .filter(|f| !code.contains(f))
            .take(3)
            .map(String::from)
            .collect();
        if !others.is_empty() {
            println!("{n} already exists in the repo — reuse instead of redeclaring?");
            for o in others {
                println!("  {o}");
            }
            findings += 1;
        }
    }

    let comment = crate::regex!(r"^\+\s*(//|#)[^!]");
    let comments = lines.iter().filter(|l| comment.is_match(l)).count();
    if comments > 0 {
        println!("new comments: {comments} — do they explain a why that cannot be read off the code?");
        findings += 1;
    }

    // Declared by the project, {name, files, forbid}: in the files matching
    // the glob, no added line may match the pattern.
    if let Some(contract) = docs.as_deref().map(|d| d.join(names::CONTRACT)).filter(|c| c.is_file()) {
        let Ok(json) = files::read_json(&contract) else {
            println!("cannot read the conventions declared in {} — fix it before going on", contract.display());
            return exit(1);
        };
        let tracked = git::out(&cwd, &["ls-files"]).unwrap_or_default();
        for check in files::get(&json, "conventions.checks").and_then(|v| v.as_array()).into_iter().flatten() {
            let field = |k: &str| files::get(check, k).map(files::value_text).unwrap_or_default();
            let (glob, forbid) = (field("files"), field("forbid"));
            if glob.is_empty() || forbid.is_empty() {
                continue;
            }
            let name = Some(field("name")).filter(|n| !n.is_empty()).unwrap_or_else(|| glob.clone());
            // With not a single such file, the rule is declared but unused here.
            let used = regex::Regex::new(&format!("{}$", glob.replace('*', ".*")))
                .is_ok_and(|r| tracked.lines().any(|l| r.is_match(l)));
            let Ok(forbidden) = regex::Regex::new(&forbid) else { continue };
            if !used {
                continue;
            }
            let culprits: Vec<&str> = code
                .iter()
                .copied()
                .filter(|f| files::glob_match(&glob, f))
                .filter(|f| added(base, &[f]).iter().any(|l| forbidden.is_match(l)))
                .collect();
            if !culprits.is_empty() {
                println!("{name}");
                for f in culprits {
                    println!("  {f}");
                }
                findings += 1;
            }
        }
    }

    println!();
    if findings == 0 {
        println!("no signals — whoever reads the conventions still closes the gate");
    }
    Ok(())
}
