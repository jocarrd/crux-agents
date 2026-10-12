//! `crux prose`: counts the markers that give away a model-generated text,
//! in Spanish and in English.
//!
//!   crux prose check <file...> | --text "..."   [--lang es|en]
//!   crux prose detail <file...> | --text "..."  [--lang es|en]
//!
//! It locates and does not decide: a rule of three the content calls for
//! stays. Exits 1 when the text reads as generated.

use crate::args::Parser;
use crate::error::{exit, Res};
use fancy_regex::Regex;
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Language {
    Spanish,
    English,
}

struct Marker {
    name: &'static str,
    /// What one case adds to the load; 0 for the advisory ones.
    weight: usize,
    /// Only reported: a pattern cannot tell a punchline from an explanation.
    advisory: bool,
    headings_only: bool,
    /// Cases allowed per 1,000 words before they count: the em dash is
    /// correct Spanish, what gives it away is the density.
    allowed_per_1000: usize,
    spanish: &'static [&'static str],
    english: &'static [&'static str],
}

const MARKERS: &[Marker] = &[
    Marker {
        name: "Negative parallelism (\"no es X, es Y\" / \"it's not X, it's Y\")",
        weight: 3,
        advisory: false,
        headings_only: false,
        allowed_per_1000: 0,
        spanish: &[
            r"(?i)\bno\s+(?:es|son|se\s+trata\s+de|va\s+de|consiste\s+en)\b[^.;!?]{2,60}[:,]\s*(?:es|son|sino)\b",
            // A contrast at the end of the sentence ("el historial del shell,
            // no la memoria") is ordinary Spanish: only "no es X, es Y" counts.
            r"(?i)\bno\s+\w+(?:a|e|o|an|en)\b[^.;!?]{0,40},\s*sino\s+(?:que\s+)?\w",
            r"(?i)\bmás\s+que\s+\w+[^.;!?]{0,40},\s*es\b",
        ],
        english: &[
            r"(?i)\b(?:it|this|that)(?:'s|\s+is|\s+was)\s+not\b[^.;!?]{2,60}[,;:—]\s*(?:it|this|that)(?:'s|\s+is|\s+was)\b",
            r"(?i)\b(?:isn't|is\s+not|aren't|are\s+not)\s+(?:about|just|merely|only)\b[^.;!?]{1,60}[,;:—]\s*(?:it's|they're|but)\b",
            r"(?i)\bnot\s+(?:just|only|merely)\b[^.;!?]{1,60}\bbut\b",
        ],
    },
    Marker {
        name: "Rule of three (three coordinated items)",
        weight: 2,
        advisory: false,
        headings_only: false,
        allowed_per_1000: 0,
        // No comma before: the last three of a longer enumeration are fine.
        spanish: &[
            r"(?i)(?<![,;] )\b[a-záéíóúñü]{4,}, +[a-záéíóúñü]{4,} +y +[a-záéíóúñü]{4,}\b",
            r"(?i)\b\w{4,}, +\w{4,} +o +\w{4,}\b",
        ],
        english: &[r"(?i)(?<![,;] )\b[a-z]{4,}, +[a-z]{4,},? +(?:and|or) +[a-z]{4,}\b"],
    },
    Marker {
        name: "Epigrammatic headline (\"Lo que...\", \"Por qué...\", \"Why...\")",
        weight: 2,
        advisory: false,
        headings_only: true,
        allowed_per_1000: 0,
        spanish: &[r"(?i)^(?:lo\s+que|cómo\s+se|por\s+qué|qué\s+hay|dónde|cuando|así\s+es)\b"],
        english: &[
            r"(?i)^(?:what\s+(?:makes|it\s+takes|matters)|why\s|the\s+(?:art|power|secret|anatomy)\s+of|beyond\s|when\s|where\s)",
        ],
    },
    Marker {
        name: "Em dash (—), above 3 per 1,000 words",
        weight: 0,
        advisory: true,
        headings_only: false,
        allowed_per_1000: 3,
        spanish: &["—"],
        english: &["—"],
    },
    Marker {
        name: "Colon in mid-sentence",
        weight: 0,
        advisory: true,
        headings_only: false,
        allowed_per_1000: 0,
        // Only inside a sentence already started and not opening a list: the
        // tic is closing with a maxim.
        spanish: &[r"[a-záéíóúñü]{3,}[^.\n]{10,}?[a-záéíóúñü]{3,}: +[a-záéíóúñü][^,.\n]{12,}(?=[.\n])"],
        english: &[r"[a-z]{3,}[^.\n]{10,}?[a-z]{3,}: +[a-z][^,.\n]{12,}(?=[.\n])"],
    },
    Marker {
        name: "Recurring vocabulary",
        weight: 1,
        advisory: false,
        headings_only: false,
        allowed_per_1000: 0,
        spanish: &[
            // "clave" only as an adjective: in a technical text a clave is
            // usually an SSH key.
            r"(?i)\b(?:es|son|resulta|resultan) clave\b|\b(?:factor|punto|aspecto|elemento|pieza|paso) clave\b|\bclave para\b",
            r"(?i)\b(?:fundamental|crucial|robusto?a?s?|sólid[oa]s?|potente|riguros[oa]|profundizar|panorama|en última instancia|cabe destacar|es importante señalar|garantizar|optimizar|impulsar)\b",
            r"(?i)\bno solo\b[^.;!?]{0,60}\bsino también\b",
        ],
        english: &[
            r"(?i)\b(?:delve|delves|crucial|pivotal|robust|seamless(?:ly)?|leverag(?:e|es|ing)|tapestry|landscape|realm|testament|underscores?|foster(?:s|ing)?|holistic|paradigm|game-changer|cutting-edge|ever-evolving|unlock(?:s|ing)?|harness(?:es|ing)?|elevate(?:s)?|streamline(?:s|d)?|empower(?:s|ing)?)\b",
            r"(?i)\b(?:it(?:'s| is) (?:worth noting|important to note)|in today's (?:fast-paced|digital) world|navigat(?:e|ing) the complexities)\b",
        ],
    },
    Marker {
        name: "Grandiloquence (\"lo que de verdad importa\", \"what truly matters\")",
        weight: 2,
        advisory: false,
        headings_only: false,
        allowed_per_1000: 0,
        spanish: &[
            // "lo que hace falta" is an ordinary phrase.
            r"(?i)\blo que (?!hace falta)(?:hace|separa|distingue) (?:consistente|grande|especial|único|utilizable|de verdad)\b",
            r"(?i)\b(?:lo que de verdad importa|en el fondo,|al final del día|no es casualidad que)",
        ],
        english: &[
            r"(?i)\b(?:what (?:truly|really) matters|at the end of the day|it's no coincidence|this is what separates|makes all the difference|the real question is)\b",
        ],
    },
];

fn compiled(language: Language) -> &'static Vec<Vec<Regex>> {
    static SPANISH: OnceLock<Vec<Vec<Regex>>> = OnceLock::new();
    static ENGLISH: OnceLock<Vec<Vec<Regex>>> = OnceLock::new();
    let cell = if language == Language::Spanish { &SPANISH } else { &ENGLISH };
    cell.get_or_init(|| {
        MARKERS
            .iter()
            .map(|m| {
                let patterns = if language == Language::Spanish { m.spanish } else { m.english };
                patterns.iter().map(|p| Regex::new(p).expect("a marker's pattern compiles")).collect()
            })
            .collect()
    })
}

pub fn detect(text: &str) -> Language {
    let words: Vec<String> = text.split(|c: char| !c.is_alphabetic()).map(str::to_lowercase).collect();
    let count = |list: &[&str]| words.iter().filter(|w| list.contains(&w.as_str())).count();
    let spanish = count(&["el", "la", "los", "las", "que", "de", "en", "es", "una", "para", "con", "por", "del"]);
    let english = count(&["the", "and", "is", "of", "to", "in", "that", "it", "for", "with", "this", "are", "on"]);
    if spanish > english {
        Language::Spanish
    } else {
        Language::English
    }
}

/// Without quotes and code: a text that teaches what to avoid has it written
/// out.
fn prose_only(md: &str) -> String {
    let front = crate::regex!(r"^---\n[\s\S]*?\n---\n");
    let blocks = crate::regex!(r"```[\s\S]*?```");
    let quotes = crate::regex!(r"(?m)^\s*>.*$");
    let cited = crate::regex!(r#"«[^»]*»|“[^”]*”|"[^"\n]*""#);
    let inline = crate::regex!(r"`[^`]*`");
    let quoted_terms = crate::regex!(r"^\s*[-*·]\s*`");
    let text = front.replace(md, "");
    let text = blocks.replace_all(&text, "");
    let text = quotes.replace_all(&text, "");
    let text = cited.replace_all(&text, "");
    // List items that are quoted terms go before the inline code that marks them.
    let text: String = text.lines().filter(|l| !quoted_terms.is_match(l)).collect::<Vec<_>>().join("\n");
    inline.replace_all(&text, "").into_owned()
}

struct Count<'a> {
    marker: &'a Marker,
    n: usize,
    cases: Vec<String>,
}

fn analyze(prose: &str, headings: &str, words: usize, language: Language) -> Vec<Count<'static>> {
    MARKERS
        .iter()
        .zip(compiled(language))
        .map(|(m, patterns)| {
            let source = if m.headings_only { headings } else { prose };
            let mut cases = vec![];
            for re in patterns {
                for found in re.find_iter(source).flatten() {
                    let case: String = found.as_str().split_whitespace().collect::<Vec<_>>().join(" ");
                    cases.push(case.chars().take(110).collect());
                }
            }
            let allowed = (words as f64 / 1000.0 * m.allowed_per_1000 as f64).round() as usize;
            Count { marker: m, n: cases.len().saturating_sub(allowed), cases }
        })
        .collect()
}

fn line_of(original: &str, case: &str) -> String {
    let needle: String = case.chars().take(32).collect();
    match original.find(needle.trim()) {
        Some(i) => (original[..i].matches('\n').count() + 1).to_string(),
        None => "?".into(),
    }
}

pub fn run(argv: &[String]) -> Res {
    let usage = || {
        println!("usage: crux prose check <file...> | --text \"...\"  [--lang es|en]");
        println!("       crux prose detail <file...> | --text \"...\" [--lang es|en]");
        exit(1)
    };
    let detail = match argv.first().map(String::as_str) {
        Some("check") => false,
        Some("detail") => true,
        _ => return usage(),
    };
    let (mut files, mut text, mut lang) = (vec![], None::<String>, None::<Language>);
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--text" => text = Some(p.value()),
            "--lang" => {
                lang = match p.value().as_str() {
                    "es" => Some(Language::Spanish),
                    "en" => Some(Language::English),
                    other => crate::die!("unknown language: '{other}' — es or en"),
                }
            }
            f => files.push(f.to_string()),
        }
    }
    let (raw, label) = match text {
        Some(t) => (t, "(loose text)".to_string()),
        None if files.is_empty() => return usage(),
        None => {
            let mut all = String::new();
            for f in &files {
                match std::fs::read_to_string(f) {
                    Ok(t) => {
                        all.push_str(&t);
                        all.push('\n');
                    }
                    Err(e) => crate::die!("cannot read {f}: {e}"),
                }
            }
            (all, files.join(", "))
        }
    };
    let prose = prose_only(&raw);
    let language = lang.unwrap_or_else(|| detect(&prose));
    let heading = crate::regex!(r"^#{1,6}\s+");
    let headings: Vec<String> = raw
        .lines()
        .map(str::trim)
        .filter(|l| heading.is_match(l))
        .map(|l| heading.replace(l, "").into_owned())
        .collect();
    let words = prose.split_whitespace().count();
    let counts = analyze(&prose, &headings.join("\n"), words, language);
    let load: usize = counts.iter().map(|c| c.n * c.marker.weight).sum();
    let per_1000 = if words == 0 { 0.0 } else { load as f64 / words as f64 * 1000.0 };

    let name = if language == Language::Spanish { "Spanish" } else { "English" };
    println!("\n{label} · {words} words · {} headlines · {name}\n", headings.len());
    for c in &counts {
        let mark = match (c.n, c.marker.advisory, c.marker.weight) {
            (0, _, _) => "  ",
            (_, true, _) => "··",
            (_, _, w) if w >= 2 => "🔴",
            _ => "🟡",
        };
        let tail = if c.marker.advisory { "  (advisory, not scored)" } else { "" };
        println!("{mark} {:>3}  {}{tail}", c.n, c.marker.name);
        if detail && c.n > 0 {
            for case in c.cases.iter().take(12) {
                println!("         L{}  {case}", line_of(&raw, case));
            }
            if c.cases.len() > 12 {
                println!("         ... and {} more", c.cases.len() - 12);
            }
        }
    }
    let verdict = if per_1000 < 4.0 {
        "sounds human"
    } else if per_1000 < 9.0 {
        "worth a review"
    } else {
        "sounds like a machine"
    };
    println!("\nload {load} · {per_1000:.1} per 1,000 words — {verdict}");
    println!("\nOnly the five reliable markers are scored. The em dash and the colons are");
    println!("reported because a pattern cannot tell a closing line from an explanation.\n");
    if per_1000 >= 9.0 {
        exit(1)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(text: &str, language: Language) -> usize {
        let p = prose_only(text);
        analyze(&p, "", p.split_whitespace().count(), language).iter().map(|c| c.n * c.marker.weight).sum()
    }

    #[test]
    fn each_language_catches_its_own_tics() {
        assert!(load("No es una herramienta, es un sistema de trabajo.", Language::Spanish) >= 3);
        assert!(load("It's not a tool, it's a way of working.", Language::English) >= 3);
        assert!(load("We leverage a robust and seamless platform.", Language::English) >= 3);
        assert_eq!(load("The build takes four minutes on a laptop.", Language::English), 0);
    }

    #[test]
    fn quoted_examples_are_not_the_authors_prose() {
        assert_eq!(load("Evita «no es X, es Y» en los títulos.", Language::Spanish), 0);
        assert_eq!(load("Avoid `it's not X, it's Y` in titles.", Language::English), 0);
    }

    #[test]
    fn the_language_is_the_one_most_of_the_text_is_in() {
        assert_eq!(detect("El commit de la rama que se queda en el repo"), Language::Spanish);
        assert_eq!(detect("The commit of the branch that stays in the repo"), Language::English);
    }
}
