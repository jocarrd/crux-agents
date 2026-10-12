//! Reading and writing files the way the kernel needs: JSON that reports why
//! it does not parse, and writes that never leave a half-written file.

use serde_json::Value;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

/// The last component of a path as text; empty for `/` or `..`, which no
/// caller treats as a name.
pub fn name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

pub fn read_json(path: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

/// To a temporary file and rename: a kill halfway must not leave the registry
/// truncated, because a truncated registry opens the deletion guard.
pub fn write_atomic(path: &Path, content: &str, mode: Option<u32>) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_file_name(format!(
        "{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        if let Some(m) = mode {
            opts.mode(m);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(content.as_bytes())?;
    }
    if let Some(m) = mode {
        fs::set_permissions(&tmp, fs::Permissions::from_mode(m))?;
    }
    fs::rename(&tmp, path)
}

/// Two-space JSON plus the newline, byte for byte what the earlier kernels
/// wrote: other machines may run one, and they read and diff these files.
pub fn json_pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_else(|_| "{}".into()) + "\n"
}

pub fn mkdir_private(dir: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

/// Key path like "remote.visibility" over a JSON value.
pub fn get<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(v, |acc, k| acc.get(k)).filter(|x| !x.is_null())
}

pub fn get_str(v: &Value, path: &str) -> Option<String> {
    get(v, path).map(value_text)
}

/// How a value reads as text: strings without quotes, arrays one per line.
pub fn value_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().map(value_text).collect::<Vec<_>>().join("\n"),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

pub fn str_list(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(a)) => a.iter().map(value_text).collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => vec![],
    }
}

pub fn read_or_empty(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// A shell pattern: `*` (slashes included, as in `case`), `?` and `[...]`.
pub fn glob_match(pattern: &str, text: &str) -> bool {
    let mut rx = String::from("^");
    let mut chars = pattern.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '*' => rx.push_str(".*"),
            '?' => rx.push('.'),
            '[' => {
                rx.push('[');
                for d in chars.by_ref() {
                    rx.push(d);
                    if d == ']' {
                        break;
                    }
                }
            }
            other => rx.push_str(&regex::escape(&other.to_string())),
        }
    }
    rx.push('$');
    regex::Regex::new(&rx).is_ok_and(|r| r.is_match(text))
}
