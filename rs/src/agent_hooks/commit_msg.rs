//! The git commit-msg hook: `crux hook commit-msg <file>`, run by the small
//! script `crux hooks install` puts in each repo.
//!
//! Two scopes, set by the installer from the project's profile:
//!
//!   full       our repo: conventional commits, body width and language
//!   signature  a client's repo: only the tool signature and the language
//!
//! In a client's repo the format of the history is theirs; the language comes
//! from the contract, English unless the project declares another.

use crate::error::{exit, Res};

/// What the hook checks, decided by the project's profile when installing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scope {
    /// Our repo: conventional commits, body width and language.
    Full,
    /// A client's repo: only the tool signature and the language.
    Signature,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Full => "full",
            Scope::Signature => "signature",
        }
    }
    fn parse(text: &str) -> Option<Scope> {
        [Scope::Full, Scope::Signature].into_iter().find(|s| s.as_str() == text)
    }
}

const KINDS: &str = "feat|fix|chore|docs|refactor|test|style|perf|build|ci|revert";

/// Words that only a Spanish message has: function words, and the verbs a
/// Spanish subject starts with.
const SPANISH: [&str; 72] = [
    "que",
    "para",
    "porque",
    "cuando",
    "esto",
    "esta",
    "este",
    "esa",
    "ese",
    "del",
    "las",
    "los",
    "una",
    "unos",
    "unas",
    "pero",
    "aunque",
    "desde",
    "tambien",
    "segun",
    "asi",
    "muy",
    "cada",
    "donde",
    "hasta",
    "mientras",
    "siempre",
    "nunca",
    "antes",
    "despues",
    "ahora",
    "hace",
    "hacer",
    "tiene",
    "tener",
    "puede",
    "debe",
    "deja",
    "pasa",
    "sigue",
    "vuelve",
    "el",
    "la",
    "al",
    "un",
    "es",
    "son",
    "ser",
    "su",
    "sus",
    "ni",
    "se",
    "de",
    "en",
    "por",
    "añade",
    "anade",
    "arregla",
    "corrige",
    "quita",
    "elimina",
    "actualiza",
    "mejora",
    "cambia",
    "mueve",
    "evita",
    "permite",
    "crea",
    "borra",
    "sube",
    "muestra",
    "comprueba",
];

pub(super) fn commit_msg(argv: &[String]) -> Res {
    let Some(file) = argv.first().map(std::path::PathBuf::from).filter(|f| f.is_file()) else { return Ok(()) };
    let scope = crate::env::var("CRUX_COMMIT_MSG_SCOPE").and_then(|s| Scope::parse(&s)).unwrap_or(Scope::Full);
    let language = crate::env::var("CRUX_COMMIT_MSG_LANG").unwrap_or_else(|| "en".into());
    let Ok(mut text) = std::fs::read_to_string(&file) else { return Ok(()) };

    // Deleted instead of rejected: the agent adds it because its own
    // environment asks it to, so blocking only brings it back next commit.
    if let Some(cleaned) = without_signature(&text) {
        if std::fs::write(&file, &cleaned).is_ok() {
            println!("crux: removed the tool signature from the commit message");
        }
        text = cleaned;
    }
    let lines: Vec<&str> = text.lines().filter(|l| !l.starts_with('#')).collect();
    let subject = lines.iter().find(|l| !l.is_empty()).copied().unwrap_or("");
    // git writes these, not a person.
    if ["Merge ", "Revert ", "fixup! ", "squash! ", "amend! "].iter().any(|p| subject.starts_with(p)) {
        return Ok(());
    }
    if scope == Scope::Full {
        let conventional = regex::Regex::new(&format!(r"^({KINDS})(\([^)]+\))?!?: .")).expect("static pattern");
        if !conventional.is_match(subject) {
            return rejection(
                "the subject does not follow conventional commits",
                &format!("{subject}\n\ntypes: {KINDS}"),
            );
        }
        let capital = regex::Regex::new(&format!(r"^({KINDS})(\([^)]+\))?!?: [A-Z]")).expect("static pattern");
        if capital.is_match(subject) {
            return rejection("the subject starts with a capital letter after the prefix", subject);
        }
        // A line without spaces, such as a long URL, cannot be split.
        let long: Vec<String> = lines
            .iter()
            .enumerate()
            .filter(|(_, l)| l.chars().count() > 100 && l.contains(' '))
            .map(|(n, l)| format!("{}: {}…", n + 1, l.chars().take(60).collect::<String>()))
            .collect();
        if !long.is_empty() {
            return rejection("there are lines over 100 characters in the body", &long.join("\n"));
        }
    }
    if language != "en" {
        return Ok(());
    }
    // Two hints and not one: a proper name like "Los Angeles" has one, and a hook
    // that gets it wrong is disabled within a week.
    let hints = spanish_hints(&lines);
    if hints.len() < 2 {
        return Ok(());
    }
    let mut unique = hints.clone();
    unique.sort();
    unique.dedup();
    println!();
    println!("commit message in Spanish — the standard asks for English");
    println!();
    println!("  hints: {}", unique.join(" "));
    println!();
    println!("Documentation goes in the project language; names, branches and");
    println!("commits, in English. Rewrite it, or skip with: git commit --no-verify");
    exit(1)
}

fn rejection(title: &str, detail: &str) -> Res {
    println!();
    println!("{title}");
    println!();
    for l in detail.lines() {
        println!("  {l}");
    }
    println!();
    println!("Rewrite it, or skip with: git commit --no-verify");
    exit(1)
}

/// The message without the lines that sign it, and without the blank lines
/// that leaves at the end; None when there was no signature.
fn without_signature(text: &str) -> Option<String> {
    let signature = crate::regex!(
        r"(?i)^\s*(co-authored-by:\s*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(🤖\s*)?(generated|generado) with)"
    );
    if !text.lines().any(|l| signature.is_match(l)) {
        return None;
    }
    let mut kept: Vec<&str> = text.lines().filter(|l| !signature.is_match(l)).collect();
    while kept.last().is_some_and(|l| l.trim().is_empty()) {
        kept.pop();
    }
    Some(kept.iter().map(|l| format!("{l}\n")).collect())
}

/// Every Spanish word in the message. What is in backticks is code and a
/// token with a slash is an address (/es/ is a route): neither says what
/// language it is written in.
fn spanish_hints(lines: &[&str]) -> Vec<String> {
    let code = crate::regex!(r"`[^`]*`");
    let address = crate::regex!(r"\S*/\S*");
    let mut hints = vec![];
    for line in lines {
        let line = address.replace_all(&code.replace_all(line, ""), "").to_lowercase();
        for word in line.split(|c: char| c.is_whitespace() || c.is_ascii_punctuation()) {
            if SPANISH.contains(&word) {
                hints.push(word.to_string());
            }
        }
    }
    hints
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_place_name_is_one_hint_and_a_spanish_message_many() {
        assert_eq!(spanish_hints(&["fix(tz): correct Los Angeles offset"]).len(), 1);
        assert!(spanish_hints(&["fix: arregla el fallo de la red"]).len() >= 2);
        assert!(spanish_hints(&["docs: see `la clave` in /es/la/ruta"]).is_empty());
    }

    #[test]
    fn the_signature_goes_and_the_message_stays() {
        let m = "feat: x\n\nbody\n\nCo-Authored-By: Claude <a@b>\n";
        assert_eq!(without_signature(m).as_deref(), Some("feat: x\n\nbody\n"));
        assert_eq!(without_signature("feat: x\n"), None);
    }
}
