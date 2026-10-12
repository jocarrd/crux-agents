//! Command-line arguments.
//!
//! `Parser` reads them one at a time and the command asks for a value only
//! after an option that takes one, so each command says which options it
//! knows. `Opts` is for the internal commands, whose callers are crux itself:
//! `--key [value]`, where a key followed by another `--key`, or by nothing, is
//! a flag.

/// Reads a command's arguments in order.
///
/// ```
/// # let argv: Vec<String> = vec!["--repo".into(), "api".into(), "--force".into()];
/// let (mut repo, mut force) = (String::new(), false);
/// let mut p = crux::args::Parser::new(&argv);
/// while let Some(arg) = p.next() {
///     match arg {
///         "--repo" => repo = p.value(),
///         "--force" => force = true,
///         _ => {}
///     }
/// }
/// assert_eq!((repo.as_str(), force), ("api", true));
/// ```
pub struct Parser<'a> {
    argv: &'a [String],
    next: usize,
}

impl<'a> Parser<'a> {
    pub fn new(argv: &'a [String]) -> Self {
        Parser { argv, next: 0 }
    }

    /// The value of the option just read: the next argument, consumed.
    pub fn value_opt(&mut self) -> Option<String> {
        let v = self.argv.get(self.next).cloned();
        self.next += 1;
        v
    }

    /// The same, or "" when the option is the last argument.
    pub fn value(&mut self) -> String {
        self.value_opt().unwrap_or_default()
    }
}

impl<'a> Iterator for Parser<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        let a = self.argv.get(self.next)?;
        self.next += 1;
        Some(a.as_str())
    }
}

use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct Opts {
    pub positional: Vec<String>,
    values: HashMap<String, Option<String>>,
}

impl Opts {
    pub fn parse(argv: &[String]) -> Opts {
        let mut o = Opts::default();
        let mut i = 0;
        while i < argv.len() {
            if let Some(key) = argv[i].strip_prefix("--") {
                match argv.get(i + 1) {
                    Some(next) if !next.starts_with("--") => {
                        o.values.insert(key.to_string(), Some(next.clone()));
                        i += 1;
                    }
                    _ => {
                        o.values.insert(key.to_string(), None);
                    }
                }
            } else {
                o.positional.push(argv[i].clone());
            }
            i += 1;
        }
        o
    }
    pub fn has(&self, k: &str) -> bool {
        self.values.contains_key(k)
    }
    /// The value, or "" for a missing key or a bare flag.
    pub fn val(&self, k: &str) -> String {
        self.values.get(k).cloned().flatten().unwrap_or_default()
    }
    pub fn get(&self, k: &str) -> Option<String> {
        self.values.get(k).cloned().flatten()
    }
}
