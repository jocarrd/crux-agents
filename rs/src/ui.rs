//! What the commands print. The format is the one every crux version has
//! printed: agents, the plugin and the tests read it, so it does not change.

use std::io::IsTerminal;
use std::sync::OnceLock;

pub struct Palette {
    pub red: &'static str,
    pub green: &'static str,
    pub yellow: &'static str,
    pub cyan: &'static str,
    pub bold: &'static str,
    pub dim: &'static str,
    pub off: &'static str,
}

/// No colour when the output is not a terminal, or when NO_COLOR asks for it
/// (no-color.org).
pub fn palette() -> &'static Palette {
    static P: OnceLock<Palette> = OnceLock::new();
    P.get_or_init(|| {
        if std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()) {
            Palette {
                red: "\x1b[31m",
                green: "\x1b[32m",
                yellow: "\x1b[33m",
                cyan: "\x1b[36m",
                bold: "\x1b[1m",
                dim: "\x1b[2m",
                off: "\x1b[0m",
            }
        } else {
            Palette { red: "", green: "", yellow: "", cyan: "", bold: "", dim: "", off: "" }
        }
    })
}

pub fn ok(msg: impl AsRef<str>) {
    let p = palette();
    println!("{}ok{}    {}", p.green, p.off, msg.as_ref());
}

pub fn warn(msg: impl AsRef<str>) {
    let p = palette();
    println!("{}warn{}  {}", p.yellow, p.off, msg.as_ref());
}

/// To stdout, not stderr: it has always gone there, and callers capture both
/// streams together to show the reason next to the result.
pub fn err(msg: impl AsRef<str>) {
    let p = palette();
    println!("{}error{} {}", p.red, p.off, msg.as_ref());
}

pub fn info(msg: impl AsRef<str>) {
    let p = palette();
    println!("{}      {}{}", p.dim, msg.as_ref(), p.off);
}

/// "1 commit", "2 commits".
pub fn count(n: usize, singular: &str, plural: &str) -> String {
    if n == 1 {
        format!("1 {singular}")
    } else {
        format!("{n} {plural}")
    }
}
