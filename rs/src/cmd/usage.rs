//! crux usage — which skills are really used.
//!
//!   crux usage [--days N] [--all]
//!
//! A catalog that only grows ends up getting in the way of discovery. This
//! measures real use against the installed catalog and separates the live
//! from the dead. The source is the agent's local transcripts: an internal
//! format that may change, so if it stops finding invocations it says so
//! instead of reporting zero as if it were data.

use crate::env;
use crate::error::{exit, Res};
use crate::names;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

fn transcripts_dir() -> PathBuf {
    // CLAUDE_SKILLS_DIR is redirected by the suite: if the transcripts came
    // from the real HOME, the machine would be measured, not the sandbox.
    if let Some(t) = env::var("CRUX_TRANSCRIPTS") {
        return PathBuf::from(t);
    }
    match env::var("CLAUDE_SKILLS_DIR") {
        Some(s) => Path::new(&s).parent().unwrap_or(Path::new("/")).join("projects"),
        None => env::home().join(".claude/projects"),
    }
}

fn description_of(dir: &Path) -> String {
    let t = std::fs::read_to_string(dir.join(names::SKILL)).unwrap_or_default();
    let re = crate::regex!(r"(?m)^description:\s*([\s\S]*?)(?:\n[a-z-]+:|\n---)");
    re.captures(&t).map(|c| c[1].to_lowercase()).unwrap_or_default()
}

fn dirs(d: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(d)
        .map(|e| {
            e.flatten().filter(|x| x.path().is_dir()).map(|x| x.file_name().to_string_lossy().into_owned()).collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// Name → origin, and the descriptions, in a stable order.
fn catalog(home: &Path, root: &Path) -> (Vec<(String, String)>, HashMap<String, String>) {
    let (mut out, mut desc) = (vec![], HashMap::new());
    let mut set = |n: String, origin: String, dir: PathBuf, out: &mut Vec<(String, String)>| {
        desc.insert(n.clone(), description_of(&dir));
        match out.iter_mut().find(|(x, _)| *x == n) {
            Some(e) => e.1 = origin,
            None => out.push((n, origin)),
        }
    };
    for n in dirs(&home.join("skills")) {
        set(n.clone(), "kernel".into(), home.join("skills").join(&n), &mut out);
    }
    for p in dirs(root) {
        for sub in dirs(&root.join(&p)).into_iter().filter(|s| s.ends_with("-docs")) {
            let skills = root.join(&p).join(&sub).join(".claude/skills/project");
            for n in dirs(&skills) {
                set(n.clone(), sub.replacen("-docs", "", 1), skills.join(&n), &mut out);
            }
        }
    }
    (out, desc)
}

/// A skill's scripts are the other face of its use: whoever follows the
/// procedure by hand runs them without calling the skill by name.
fn catalog_scripts(home: &Path) -> Vec<(String, String)> {
    let mut out = vec![];
    for skill in dirs(&home.join("skills")) {
        let dir = home.join("skills").join(&skill).join("scripts");
        let mut names: Vec<String> = std::fs::read_dir(&dir)
            .map(|e| e.flatten().map(|x| x.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        names.sort();
        for s in names {
            out.push((s, skill.clone()));
        }
    }
    out
}

/// What a session delegates hangs under <session>/subagents/ and counts as
/// that session.
fn sessions_of(project: &Path) -> BTreeMap<String, Vec<PathBuf>> {
    let mut groups: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
    fn visit(dir: &Path, root: Option<&str>, groups: &mut BTreeMap<String, Vec<PathBuf>>) {
        let mut entries: Vec<_> = std::fs::read_dir(dir).map(|e| e.flatten().collect()).unwrap_or_default();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let name = e.file_name().to_string_lossy().into_owned();
            let full = e.path();
            if full.is_dir() {
                visit(&full, Some(root.unwrap_or(&name)), groups);
                continue;
            }
            let Some(stem) = name.strip_suffix(".jsonl") else { continue };
            let id = root.unwrap_or(stem).to_string();
            groups.entry(id).or_default().push(full);
        }
    }
    visit(project, None, &mut groups);
    groups
}

const EMPTY: &str = "esto esta este eso ese aqui alli para porque cuando donde
  como cual cuanto todo toda todos todas otro otra mucho mucha muy mas menos
  pero aunque desde hasta sobre entre segun tambien ahora antes despues siempre
  nunca hacer haces hace tiene tener puede poder debe deja pasa sigue vuelve
  quiero quieres vamos vale bien mal cosa cosas parte partes vez veces
  the this that with from have has been they there their what when where which
  would could should about into your just like make made only over such than
  them then were will your";

/// Only the message that opens the session: it is the one the person writes.
/// Taking more let in pasted code and test output.
fn user_words(text: &str) -> Vec<String> {
    let empty: HashSet<&str> = EMPTY.split_whitespace().collect();
    let re = crate::regex!(r#""type"\s*:\s*"user"[^\n]*?"content"\s*:\s*"((?:[^"\\]|\\.)*)""#);
    let mut words = vec![];
    for m in re.captures_iter(text) {
        let said = &m[1];
        if said.chars().count() > 400 || said.matches("\\n").count() > 2 {
            continue;
        }
        let plain: String = said.to_lowercase().nfd().filter(|c| !('\u{300}'..='\u{36f}').contains(c)).collect();
        for w in plain.split(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit())) {
            if w.len() > 4 && w.len() < 20 && !w.chars().any(|c| c.is_ascii_digit()) && !empty.contains(w) {
                words.push(w.to_string());
            }
        }
        break;
    }
    words
}

struct Usage {
    calls: HashMap<String, usize>,
    by_script: HashMap<String, usize>,
    order: Vec<String>,
    said: HashMap<String, Vec<(String, usize)>>,
    sessions: usize,
}

fn invocations(home: &Path, since: std::time::SystemTime) -> Usage {
    let mut u =
        Usage { calls: HashMap::new(), by_script: HashMap::new(), order: vec![], said: HashMap::new(), sessions: 0 };
    let scripts = catalog_scripts(home);
    let skill_re = crate::regex!(r#""name"\s*:\s*"Skill"\s*,\s*"input"\s*:\s*\{\s*"skill"\s*:\s*"([^"]+)""#);
    let bash_re =
        crate::regex!(r#""name"\s*:\s*"Bash"\s*,\s*"input"\s*:\s*\{[^}]*?"command"\s*:\s*"((?:[^"\\]|\\.)*)""#);
    // A script name appears in many commands that do not run it: reading,
    // copying, searching inside. Discarded when a reading verb precedes it.
    let read_verb = crate::regex!(
        r"\b(cat|sed|awk|grep|head|tail|less|ls|wc|chmod|cp|mv|rm|find|diff|git|shellcheck|vim|nano)\s+(-\S+\s+)*\S*$"
    );
    // Writing a skill is not using it.
    let edits = crate::regex!(r#"<<\s*['"]?\w*(PY|EOF|SH)\b|chmod\s|cat\s*>|>>\s*\S|sed -i|\.replace\("#);
    let dir = transcripts_dir();
    let mut said_counts: HashMap<String, HashMap<String, usize>> = HashMap::new();
    let mut said_order: HashMap<String, Vec<String>> = HashMap::new();
    for project in dirs(&dir) {
        for parts in sessions_of(&dir.join(&project)).into_values() {
            let recent =
                parts.iter().any(|f| std::fs::metadata(f).and_then(|m| m.modified()).is_ok_and(|t| t >= since));
            if !recent {
                continue;
            }
            u.sessions += 1;
            let text =
                parts.iter().map(|f| std::fs::read_to_string(f).unwrap_or_default()).collect::<Vec<_>>().join("\n");
            let mut here: Vec<String> = vec![];
            for c in skill_re.captures_iter(&text) {
                if !here.contains(&c[1].to_string()) {
                    here.push(c[1].to_string());
                }
            }
            for s in &here {
                *u.calls.entry(s.clone()).or_default() += 1;
                if !u.order.contains(s) {
                    u.order.push(s.clone());
                }
            }
            if scripts.is_empty() {
                continue;
            }
            let mut scripts_here: Vec<String> = vec![];
            for c in bash_re.captures_iter(&text) {
                let cmd = &c[1];
                if edits.is_match(cmd) {
                    continue;
                }
                for (script, skill) in &scripts {
                    for (i, _) in cmd.match_indices(script.as_str()) {
                        if read_verb.is_match(&cmd[..i]) {
                            continue;
                        }
                        if !scripts_here.contains(skill) {
                            scripts_here.push(skill.clone());
                        }
                    }
                }
            }
            let words = if scripts_here.is_empty() { vec![] } else { user_words(&text) };
            for skill in scripts_here {
                *u.by_script.entry(skill.clone()).or_default() += 1;
                if !u.order.contains(&skill) {
                    u.order.push(skill.clone());
                }
                if here.contains(&skill) {
                    continue;
                }
                let counts = said_counts.entry(skill.clone()).or_default();
                let order = said_order.entry(skill.clone()).or_default();
                for w in &words {
                    if !counts.contains_key(w) {
                        order.push(w.clone());
                    }
                    *counts.entry(w.clone()).or_default() += 1;
                }
            }
        }
    }
    for (skill, order) in said_order {
        let counts = &said_counts[&skill];
        u.said.insert(skill, order.into_iter().map(|w| (w.clone(), counts[&w])).collect());
    }
    u
}

pub fn run(argv: &[String]) -> Res {
    let show_all = argv.iter().any(|a| a == "--all");
    // A value that is not a number is reported, not replaced by the default.
    let days: f64 = match argv.iter().position(|a| a == "--days" || a.starts_with("--days=")) {
        None => 90.0,
        Some(i) => {
            let raw = if argv[i].contains('=') {
                Some(argv[i]["--days=".len()..].to_string())
            } else {
                argv.get(i + 1).cloned()
            };
            match raw.as_deref().and_then(|r| r.parse::<f64>().ok()).filter(|n| n.is_finite() && *n > 0.0) {
                Some(n) => n,
                None => {
                    eprintln!("--days: '{}' is not a number of days", raw.unwrap_or_default());
                    return exit(1);
                }
            }
        }
    };
    let home = env::crux_home().unwrap_or_else(|| env::projects_root().join("crux"));
    let since = std::time::SystemTime::now() - std::time::Duration::from_secs_f64(days * 86400.0);
    let (cat, desc) = catalog(&home, &env::projects_root());
    let u = invocations(&home, since);
    let days_s = if days.fract() == 0.0 { format!("{}", days as i64) } else { days.to_string() };
    println!("skill usage — last {days_s} days · {} sessions reviewed\n", u.sessions);
    if u.sessions == 0 {
        println!("No transcripts in the period. No data, not no usage.\n");
        return Ok(());
    }
    if u.calls.is_empty() && u.by_script.is_empty() {
        println!("No invocation found. The transcript format may have");
        println!("changed: check before concluding that no skill is");
        println!("used.\n");
        return Ok(());
    }
    let origin = |n: &str| cat.iter().find(|(x, _)| x == n).map(|(_, o)| o.clone());
    let mut used: Vec<(String, usize, usize)> = u
        .order
        .iter()
        .map(|n| (n.clone(), u.calls.get(n).copied().unwrap_or(0), u.by_script.get(n).copied().unwrap_or(0)))
        .collect();
    used.sort_by_key(|u| std::cmp::Reverse(u.1 + u.2));
    println!("Used:\n");
    println!("     call  script  origin           skill");
    for (name, n, s) in &used {
        let o = origin(name).unwrap_or_else(|| "(other source)".into());
        let s = if *s == 0 { String::new() } else { s.to_string() };
        println!("  {n:>7}  {s:>6}  {o:<16} {name}");
    }
    // The procedure is followed and the skill is not invoked: its description
    // does not activate when the problem shows up.
    let silent: Vec<&(String, usize, usize)> =
        used.iter().filter(|(n, c, s)| *c == 0 && *s > 0 && origin(n).is_some()).collect();
    if !silent.is_empty() {
        println!("\nFollowed by hand, and nobody called them by name:\n");
        for (name, _, scripts) in silent {
            println!("  {name} — {scripts} {}", if *scripts == 1 { "session" } else { "sessions" });
            let d = desc.get(name).cloned().unwrap_or_default();
            let mut missing: Vec<(String, usize)> = u
                .said
                .get(name)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|(w, _)| !d.contains(w.as_str()))
                .collect();
            missing.sort_by_key(|m| std::cmp::Reverse(m.1));
            let missing: Vec<String> = missing.into_iter().take(8).map(|(w, _)| w).collect();
            // With one or two loose words there is no signal.
            if missing.len() >= 3 {
                println!("      asked for like this: {}", missing.join(", "));
            }
        }
        println!("\n  The work got done, so the skill is not surplus: what fails is its");
        println!("  description, which lacks the words the problem shows up with.");
    }
    println!("\n  Both columns count SESSIONS, not executions: a loop that calls the");
    println!("  script eighteen times is still one occasion on which it was used.");
    println!("\n  \"call\" is the skill invoked by name. \"script\" is the trace of its");
    println!("  scripts in commands: the procedure followed by hand. They do not add");
    println!("  up: one session may appear in both. Sessions in which the skill itself");
    println!("  was written do not count as use.");
    let orphans: Vec<&String> = used.iter().map(|(n, _, _)| n).filter(|n| origin(n).is_none()).collect();
    if !orphans.is_empty() {
        println!("\nInvoked and absent from this catalog:\n");
        for n in orphans {
            println!("  {n}");
        }
        println!("\n  They probably come from the agent itself or a plugin, and then there");
        println!("  is nothing to fix: crux only knows its two catalogs. If instead it is");
        println!("  a name of yours that was renamed, fix the reference.");
    }
    let never: Vec<&(String, String)> =
        cat.iter().filter(|(n, _)| !u.calls.contains_key(n) && !u.by_script.contains_key(n)).collect();
    if !never.is_empty() {
        println!("\nUnused in the period ({} of {}):\n", never.len(), cat.len());
        let mut by_origin: Vec<(String, Vec<String>)> = vec![];
        for (n, o) in never {
            match by_origin.iter_mut().find(|(x, _)| x == o) {
                Some(e) => e.1.push(n.clone()),
                None => by_origin.push((o.clone(), vec![n.clone()])),
            }
        }
        for (o, list) in by_origin {
            let shown = if show_all || list.len() <= 8 {
                list.join(", ")
            } else {
                format!("{}, +{}", list[..8].join(", "), list.len() - 8)
            };
            println!("  {o}: {shown}");
        }
        println!("\n  This is not a deletion list. An incident skill that has not been");
        println!("  used is good news; a newly created one has not had an occasion yet.");
        println!("  What to look at is the one that has existed for months, covers");
        println!("  something frequent and still nobody invokes: it is almost always");
        println!("  that its description does not activate when it should.");
    }
    println!();
    Ok(())
}
