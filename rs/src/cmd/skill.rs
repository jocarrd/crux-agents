//! crux skill — test that a skill still does what it has to do.
//!
//!   crux skill test <skill|path> [--against <ref>] [--runs <n>] [--verbose]
//!
//! Runs the scenarios in <skill>/tests/scenarios.md: questions with a known
//! answer and deterministic checks. Counts the words and, if the adapter
//! allows it, the tokens. With --against it compares with the version at that
//! git ref and flags as a regression what used to pass and now does not.
//!
//! Who answers is decided by the adapter, not by this command:
//!   CRUX_SKILL_RUNNER  answers the question on stdin following $CRUX_SKILL_FILE
//!   CRUX_SKILL_TOKENS  prints the tokens of $CRUX_SKILL_FILE (optional)

use crate::args::Parser;
use crate::error::{Exit, Res};
use crate::names;
use crate::{env, git, sh};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn fail<T>(msg: impl AsRef<str>, code: i32) -> Result<T, Exit> {
    eprintln!("error {}", msg.as_ref());
    Err(Exit(code))
}

#[derive(Debug)]
pub struct Scenario {
    pub name: String,
    pub question: String,
    pub must: Vec<String>,
    pub must_not: Vec<String>,
}

/// «## name», «Question:» (may continue over several lines), «Must:» and
/// «Must not:», one regular expression per line. The Spanish keywords of
/// existing scenario files are still accepted.
const SCENARIOS: &str = "tests/scenarios.md";

/// A skill's scenarios; skills written before the name went English have
/// them in tests/escenarios.md.
fn scenarios_of(skill_dir: &Path) -> Option<std::path::PathBuf> {
    [SCENARIOS, "tests/escenarios.md"].into_iter().map(|f| skill_dir.join(f)).find(|f| f.is_file())
}

pub fn read_scenarios(text: &str) -> Result<Vec<Scenario>, Exit> {
    let head = crate::regex!(r"^##\s+(.+)$");
    let field_re = crate::regex!(r"(?i)^(Question|Must not|Must|Pregunta|No debe|Debe):\s*(.*)$");
    let mut out: Vec<Scenario> = vec![];
    let mut field = "";
    for line in text.split('\n') {
        if let Some(h) = head.captures(line) {
            out.push(Scenario { name: h[1].trim().into(), question: String::new(), must: vec![], must_not: vec![] });
            field = "";
            continue;
        }
        let Some(cur) = out.last_mut() else { continue };
        if let Some(m) = field_re.captures(line) {
            field = match m[1].to_lowercase().as_str() {
                "question" | "pregunta" => "question",
                "must" | "debe" => "must",
                _ => "mustNot",
            };
            match field {
                "question" => cur.question = m[2].to_string(),
                "must" => cur.must.push(m[2].to_string()),
                _ => cur.must_not.push(m[2].to_string()),
            }
            continue;
        }
        if field == "question" && !line.trim().is_empty() {
            cur.question.push('\n');
            cur.question.push_str(line);
        }
    }
    for e in &out {
        if e.question.trim().is_empty() {
            return fail(format!("scenario «{}» has no question", e.name), 2);
        }
        if e.must.is_empty() && e.must_not.is_empty() {
            return fail(format!("scenario «{}» checks nothing: it lacks «Must:» or «Must not:»", e.name), 2);
        }
    }
    Ok(out)
}

pub fn check(s: &Scenario, answer: &str) -> Vec<String> {
    let rx = |r: &str| regex::RegexBuilder::new(r).case_insensitive(true).build();
    let mut failures = vec![];
    for r in &s.must {
        if !rx(r).is_ok_and(|x| x.is_match(answer)) {
            failures.push(format!("does not say /{r}/"));
        }
    }
    for r in &s.must_not {
        if rx(r).is_ok_and(|x| x.is_match(answer)) {
            failures.push(format!("says /{r}/"));
        }
    }
    failures
}

fn locate(arg: &str) -> Result<PathBuf, Exit> {
    let home = env::crux_home().unwrap_or_default();
    for c in [PathBuf::from(arg), Path::new(arg).join(names::SKILL), home.join("skills").join(arg).join(names::SKILL)] {
        if c.is_file() && c.file_name().is_some_and(|n| n == names::SKILL) {
            return Ok(crate::project::normalize(&std::env::current_dir().unwrap_or_default().join(c)));
        }
    }
    fail(format!("cannot find skill «{arg}»: pass its name in the kernel or the path of its folder"), 2)
}

fn version(skill: &Path, r: &str) -> Result<String, Exit> {
    let Some(top) = git::toplevel(skill.parent().unwrap()) else {
        return fail("--against needs the skill to be in a git repo", 2);
    };
    let rel = skill.strip_prefix(&top).unwrap_or(skill).to_string_lossy().into_owned();
    match git::out(&top, &["show", &format!("{r}:{rel}")]) {
        Some(t) => Ok(t + "\n"),
        None => fail(format!("{rel} does not exist in {r}"), 2),
    }
}

fn adapter(var: &str, script: &str) -> Option<String> {
    if let Some(v) = env::var(var) {
        return Some(v);
    }
    let p = env::crux_home().unwrap_or_default().join("adapters/claude").join(script);
    (sh::exists("claude") && p.is_file()).then(|| format!("bash \"{}\"", p.display()))
}

fn run_adapter(cmd: &str, file: &Path, input: &str) -> Result<String, String> {
    let child = Command::new("bash")
        .args(["-c", cmd])
        .env("CRUX_SKILL_FILE", file)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = child.map_err(|e| e.to_string())?;
    let mut stdin = child.stdin.take().unwrap();
    let data = input.to_string();
    std::thread::spawn(move || {
        let _ = stdin.write_all(data.as_bytes());
    });
    let o = child.wait_with_output().map_err(|e| e.to_string())?;
    let out = String::from_utf8_lossy(&o.stdout).trim().to_string();
    if !o.status.success() {
        let err = String::from_utf8_lossy(&o.stderr).trim().to_string();
        let text = if !err.is_empty() {
            err
        } else if !out.is_empty() {
            out
        } else {
            format!("exit {}", o.status.code().unwrap_or(1))
        };
        let lines: Vec<&str> = text.lines().collect();
        return Err(lines[lines.len().saturating_sub(3)..].join(" "));
    }
    Ok(out)
}

struct Attempt {
    answer: String,
    failures: Vec<String>,
}

struct Tried {
    words: usize,
    tokens: Option<f64>,
    results: Vec<(String, Vec<Attempt>, bool)>,
}

fn try_out(
    text: &str,
    scenarios: &[Scenario],
    runner: &str,
    tokens_cmd: Option<&str>,
    runs: usize,
) -> Result<Tried, Exit> {
    let dir = std::env::temp_dir().join(format!(
        "crux-skill-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    let _ = std::fs::create_dir_all(&dir);
    let file = dir.join(names::SKILL);
    if let Err(e) = crate::files::write(&file, text) {
        return fail(e, 1);
    }
    let tokens = tokens_cmd
        .and_then(|c| run_adapter(c, &file, "").ok())
        .and_then(|t| t.parse::<f64>().ok())
        .filter(|n| *n != 0.0);
    let mut results = vec![];
    for e in scenarios {
        let mut attempts = vec![];
        for _ in 0..runs {
            match run_adapter(runner, &file, &e.question) {
                Ok(answer) => attempts.push(Attempt { failures: check(e, &answer), answer }),
                Err(err) => return fail(format!("the adapter failed on «{}»: {err}", e.name), 1),
            }
        }
        let passes = attempts.iter().all(|a| a.failures.is_empty());
        results.push((e.name.clone(), attempts, passes));
    }
    Ok(Tried { words: text.split_whitespace().count(), tokens, results })
}

pub fn run(argv: &[String]) -> Res {
    if argv.first().map(String::as_str) != Some("test") {
        return fail("usage: crux skill test <skill|path> [--against <ref>] [--runs <n>] [--verbose]", 2);
    }
    let (mut goal, mut against, mut runs, mut verbose) = (None, None::<String>, 1usize, false);
    let rest = &argv[1..];
    let mut p = Parser::new(rest);
    while let Some(arg) = p.next() {
        match arg {
            "--against" => against = p.value_opt(),
            "--runs" => {
                runs = p.value_opt().and_then(|r| r.parse::<f64>().ok()).map(|n| n.max(1.0) as usize).unwrap_or(1)
            }
            "--verbose" => verbose = true,
            a if a.starts_with("--") => return fail(format!("unknown option: {a}"), 2),
            a => goal = Some(a.to_string()),
        }
    }
    let Some(goal) = goal else { return fail("missing skill: crux skill test <skill|path>", 2) };
    let skill = locate(&goal)?;
    let Some(scenarios_file) = scenarios_of(skill.parent().unwrap_or(Path::new("/"))) else {
        let scenarios_file = skill.parent().unwrap_or(Path::new("/")).join(SCENARIOS);
        let cwd = std::env::current_dir().unwrap_or_default();
        let shown = scenarios_file.strip_prefix(&cwd).map(Path::to_path_buf).unwrap_or(scenarios_file.clone());
        return fail(format!("the skill has no scenarios: create {} (see /skill-creator)", shown.display()), 2);
    };
    let text = match std::fs::read_to_string(&scenarios_file) {
        Ok(t) => t,
        Err(e) => return fail(format!("cannot read {}: {e}", scenarios_file.display()), 2),
    };
    let scenarios = read_scenarios(&text)?;
    if scenarios.is_empty() {
        return fail(format!("{} has no scenario («## name»)", scenarios_file.display()), 2);
    }
    let Some(runner) = adapter("CRUX_SKILL_RUNNER", "skill-runner.sh") else {
        return fail("nobody to answer: set CRUX_SKILL_RUNNER or install the default adapter's agent", 2);
    };
    let tokens_cmd = adapter("CRUX_SKILL_TOKENS", "skill-tokens.sh");
    let name = crate::files::name(skill.parent().unwrap());
    let skill_text = match std::fs::read_to_string(&skill) {
        Ok(t) => t,
        Err(e) => return fail(format!("cannot read {}: {e}", skill.display()), 2),
    };
    let current = try_out(&skill_text, &scenarios, &runner, tokens_cmd.as_deref(), runs)?;
    let preview = match &against {
        Some(r) => Some(try_out(&version(&skill, r)?, &scenarios, &runner, tokens_cmd.as_deref(), runs)?),
        None => None,
    };
    let size =
        |t: &Tried| format!("{} words{}", t.words, t.tokens.map(|n| format!(" · {n} tokens")).unwrap_or_default());
    println!(
        "skill {name}: {} scenarios{}",
        scenarios.len(),
        if runs > 1 { format!(" × {runs}") } else { String::new() }
    );
    println!("  current: {}", size(&current));
    if let (Some(p), Some(r)) = (&preview, &against) {
        let delta = match (current.tokens, p.tokens) {
            (Some(c), Some(b)) => format!(" ({} % of tokens)", ((c - b) * 100.0 / b).round()),
            _ => String::new(),
        };
        println!("  {r}: {}{delta}", size(p));
    }
    println!();
    let (mut failing, mut regressions) = (0, 0);
    for (i, (rname, attempts, passes)) in current.results.iter().enumerate() {
        let before = preview.as_ref().map(|p| p.results[i].2);
        let marker = if *passes {
            "ok  "
        } else if before == Some(true) {
            "REGR"
        } else {
            "FAIL"
        };
        if !passes {
            failing += 1;
            if before == Some(true) {
                regressions += 1;
            }
        }
        let extra = match (before, &against) {
            (Some(b), Some(r)) => format!("   ({r}: {})", if b { "ok" } else { "fails" }),
            _ => String::new(),
        };
        println!("{marker}  {rname}{extra}");
        if !passes || verbose {
            for (k, a) in attempts.iter().enumerate() {
                if !a.failures.is_empty() {
                    println!(
                        "      {}{}",
                        if runs > 1 { format!("attempt {}: ", k + 1) } else { String::new() },
                        a.failures.join(" · ")
                    );
                }
                if verbose || !a.failures.is_empty() {
                    let one: String =
                        a.answer.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(300).collect();
                    println!("      › {one}");
                }
            }
        }
    }
    println!();
    if regressions > 0 {
        println!("{regressions} regression(s): the current version fails where {} passed", against.unwrap_or_default());
    }
    if failing > 0 {
        println!("{failing} of {} scenarios fail", scenarios.len());
        return Err(Exit(1));
    }
    println!("all scenarios pass");
    Ok(())
}

/// `crux __skill-scenarios <skills dir>`: how many scenarios the kernel has
/// and which expressions do not compile, for the suite.
pub fn scenarios_report(argv: &[String]) -> Res {
    let dir = PathBuf::from(argv.first().cloned().unwrap_or_default());
    let (mut n, mut bad) = (0, vec![]);
    let mut skills: Vec<String> = std::fs::read_dir(&dir)
        .map(|e| e.flatten().map(|x| x.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    skills.sort();
    for s in skills {
        let Some(file) = scenarios_of(&dir.join(&s)) else { continue };
        let Some(text) = crate::files::read_optional(&file) else { continue };
        for e in read_scenarios(&text)? {
            n += 1;
            for r in e.must.iter().chain(e.must_not.iter()) {
                if regex::RegexBuilder::new(r).case_insensitive(true).build().is_err() {
                    bad.push(format!("{s}: {r}"));
                }
            }
        }
    }
    println!("{n} {}", bad.join(","));
    Ok(())
}
