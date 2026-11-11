//! What the gate ran, told so a person can read it. The receipt keeps the
//! exact commands ("ok · sh -c npx tsc --noEmit && npx jest (16s)") for the
//! record; the proposal only says "Types: no errors" and "Tests: the whole
//! suite passes", with no trace of how the gate was run.

struct Kind {
    subject: (&'static str, &'static str),
    ok: (&'static str, &'static str),
}

const TYPES: Kind = Kind { subject: ("Types", "Tipos"), ok: ("no errors", "sin errores") };
const SUITE: Kind = Kind { subject: ("Tests", "Tests"), ok: ("the whole suite passes", "toda la suite en verde") };
const AFFECTED: Kind = Kind { subject: ("Tests", "Tests"), ok: ("the affected ones pass", "los afectados en verde") };
const LINT: Kind = Kind { subject: ("Lint", "Lint"), ok: ("clean", "limpio") };
const FORMAT: Kind = Kind { subject: ("Format", "Formato"), ok: ("clean", "limpio") };
const BUILD: Kind = Kind { subject: ("Build", "Compilación"), ok: ("succeeds", "correcta") };
const SHELL: Kind = Kind { subject: ("Shell syntax", "Sintaxis del script"), ok: ("valid", "válida") };

const TEST_RUNNERS: &[&str] = &["jest", "vitest", "pytest", "mocha", "ava"];
// A whole test folder is the suite, not a part of it
const WHOLE_SUITE_ARGS: &[&str] = &["tests", "test", "."];
const WRAPPERS: &[&str] = &["nice", "npx", "pnpm", "npm", "yarn", "bunx", "exec", "run", "env", "timeout"];

fn pick(pair: (&'static str, &'static str), es: bool) -> &'static str {
    if es {
        pair.1
    } else {
        pair.0
    }
}

/// The tool and its arguments, without the wrapper that launched it:
/// variables, `nice -n 10`, `npx`, `pnpm exec`, `timeout 45m`, `python -m`.
fn tool_and_args(command: &str) -> Option<(String, Vec<String>)> {
    let assignment = crate::regex!(r"^[A-Z_][A-Z0-9_]*=");
    let amount = crate::regex!(r"^\d+[a-z]*$");
    let mut words = command.split_whitespace().map(|w| w.trim_matches(|c| c == '"' || c == '\'')).peekable();
    while let Some(&word) = words.peek() {
        let base = word.rsplit('/').next().unwrap_or(word);
        let skip = assignment.is_match(word)
            || WRAPPERS.contains(&base)
            || amount.is_match(word)
            || word.starts_with('-')
            || base.starts_with("python");
        if !skip {
            break;
        }
        words.next();
    }
    let first = words.next()?;
    let tool = first.rsplit('/').next().unwrap_or(first).to_string();
    Some((tool, words.map(str::to_string).collect()))
}

fn kind_of(command: &str) -> Option<&'static Kind> {
    let (tool, args) = tool_and_args(command)?;
    let has = |flag: &str| args.iter().any(|a| a == flag);
    let sub = args.first().map(String::as_str).unwrap_or("");
    let kind = match tool.as_str() {
        "tsc" | "vue-tsc" | "mypy" | "pyright" => &TYPES,
        t if TEST_RUNNERS.contains(&t) => {
            let targets = args.iter().filter(|a| !a.starts_with('-') && !WHOLE_SUITE_ARGS.contains(&a.as_str()));
            if targets.count() > 0 {
                &AFFECTED
            } else {
                &SUITE
            }
        }
        "eslint" | "clippy" | "golangci-lint" => &LINT,
        "ruff" if sub == "format" => &FORMAT,
        "ruff" => &LINT,
        "prettier" | "black" if has("--check") => &FORMAT,
        "bash" | "sh" if has("-n") => &SHELL,
        "cargo" => match sub {
            "test" => &SUITE,
            "clippy" => &LINT,
            "fmt" => &FORMAT,
            "build" => &BUILD,
            _ => return None,
        },
        "go" if sub == "test" => &SUITE,
        "next" | "vite" | "docker" if sub == "build" => &BUILD,
        t if t == "build" || t.starts_with("build:") => &BUILD,
        t if t == "typecheck" || t.starts_with("typecheck:") => &TYPES,
        "lint" => &LINT,
        "test" => &SUITE,
        _ => return None,
    };
    Some(kind)
}

/// The commands chained in one receipt line, without the shell that ran them.
fn commands(line: &str) -> Vec<String> {
    let shell = crate::regex!(r#"^(?:sh|bash) -c\s+["']?(.*?)["']?$"#);
    let inner = shell.captures(line).map(|c| c[1].to_string()).unwrap_or_else(|| line.to_string());
    inner.split("&&").flat_map(|part| part.split(';')).map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect()
}

/// "- ok · npx tsc --noEmit (16s)" → (true, "npx tsc --noEmit"); a line a
/// person wrote ("- ok · the app boots with the same routes") keeps its text.
fn parse(line: &str) -> Option<(Option<String>, String)> {
    let re = crate::regex!(r"^- (ok|exit \d+) · (.*?)(?: \(\d+s\))?$");
    let c = re.captures(line)?;
    let failed = (&c[1] != "ok").then(|| c[1].to_string());
    Some((failed, c[2].to_string()))
}

/// The bullets of what was checked, in the order they were run.
pub fn describe(lines: &[&str], language: &str) -> Vec<String> {
    let es = language == "es";
    let mut said: Vec<String> = Vec::new();
    let mut add = |text: String| {
        if !said.contains(&text) {
            said.push(text);
        }
    };
    for line in lines {
        let Some((failed, text)) = parse(line) else {
            add(line.trim_start_matches("- ").to_string());
            continue;
        };
        let parts = commands(&text);
        let known: Vec<Option<&Kind>> = parts.iter().map(|p| kind_of(p)).collect();
        // A sentence nobody recognises as a command was written by a person
        let runs_a_tool = text.split_whitespace().next().is_some_and(|first| WRAPPERS.contains(&first));
        if known.iter().all(Option::is_none)
            && parts.len() == 1
            && text.contains(' ')
            && !text.contains('/')
            && !runs_a_tool
        {
            add(match &failed {
                Some(code) => format!("{text} ({code})"),
                None => text,
            });
            continue;
        }
        for (part, kind) in parts.iter().zip(known) {
            let outcome = |ok: &str| match &failed {
                Some(code) => format!("{} ({code})", if es { "falla" } else { "fails" }),
                None => ok.to_string(),
            };
            add(match kind {
                Some(k) => format!("{}: {}", pick(k.subject, es), outcome(pick(k.ok, es))),
                None => format!("`{part}` {}", outcome(if es { "pasa" } else { "passes" })),
            });
        }
    }
    said
}

/// The section as it goes in the proposal; empty when nothing was checked.
pub fn section(lines: &[&str], language: &str) -> String {
    describe(lines, language).iter().map(|s| format!("- {s}")).collect::<Vec<_>>().join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn said(lines: &[&str]) -> Vec<String> {
        describe(lines, "en")
    }

    #[test]
    fn a_chained_gate_becomes_one_line_per_check() {
        assert_eq!(
            said(&["- ok · sh -c npx tsc --noEmit -p . && npx jest --silent --maxWorkers=4 (16s)"]),
            vec!["Types: no errors", "Tests: the whole suite passes"]
        );
    }

    #[test]
    fn package_scripts_read_as_checks() {
        assert_eq!(
            said(&["- ok · pnpm run check (97s)", "- ok · pnpm run build:web (7s)", "- ok · npm run typecheck (4s)"]),
            vec!["`pnpm run check` passes", "Build: succeeds", "Types: no errors"]
        );
    }

    #[test]
    fn tests_on_some_paths_are_the_affected_ones() {
        assert_eq!(said(&["- ok · npx jest core/maps components/maps (3s)"]), vec!["Tests: the affected ones pass"]);
        assert_eq!(
            said(&["- ok · PYTHONPATH=src ../app/.venv/bin/python -m pytest -q tests (80s)"]),
            vec!["Tests: the whole suite passes"]
        );
    }

    #[test]
    fn lint_format_shell_and_build_are_named() {
        assert_eq!(
            said(&[
                "- ok · ruff check src && ruff format --check src (1s)",
                "- ok · bash -n ops/ingest.sh (0s)",
                "- ok · cargo build --release (40s)",
            ]),
            vec!["Lint: clean", "Format: clean", "Shell syntax: valid", "Build: succeeds"]
        );
    }

    #[test]
    fn a_failure_says_so_with_its_code() {
        assert_eq!(said(&["- exit 1 · npx jest (9s)"]), vec!["Tests: fails (exit 1)"]);
    }

    #[test]
    fn an_unknown_command_is_quoted_and_a_sentence_is_kept() {
        assert_eq!(
            said(&["- ok · test/run.sh (40s)", "- ok · the app boots with the same 401 routes"]),
            vec!["`test/run.sh` passes", "the app boots with the same 401 routes"]
        );
    }

    #[test]
    fn the_section_speaks_the_language_and_leaves_no_command_or_timing() {
        let out = section(&["- ok · sh -c npx tsc --noEmit && npx jest (16s)"], "es");
        assert_eq!(out, "- Tipos: sin errores\n- Tests: toda la suite en verde");
    }

    #[test]
    fn repeated_checks_are_said_once() {
        assert_eq!(said(&["- ok · npx tsc (1s)", "- ok · npx tsc (1s)"]), vec!["Types: no errors"]);
    }
}
