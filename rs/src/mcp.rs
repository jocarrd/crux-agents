//! The MCP servers a project declares in its contract, and the `.mcp.json`
//! files derived from them.
//!
//! The contract says `transport` and the client file says `type`. Translating
//! between the two is what makes the declaration independent of the agent
//! that consumes it, and it lives in one place because `doctor` has to compute
//! exactly the same thing to know whether what was written still matches.

use crate::names;
use crate::{files, secrets};
use serde_json::{json, Map, Value};
use std::path::Path;

pub const TRANSPORTS: [&str; 3] = ["stdio", "http", "sse"];

fn s<'a>(d: &'a Value, k: &str) -> Option<&'a Value> {
    d.get(k).filter(|v| !v.is_null() && v != &&json!(false) && v != &&json!("") && v != &&json!(0))
}

/// `repos` is ours: it says where the file is written, not how to talk to the
/// server, so it does not travel to the client.
pub fn to_client_format(name: &str, d: &Value) -> Result<Value, String> {
    let transport = s(d, "transport").and_then(Value::as_str).unwrap_or("stdio");
    if !TRANSPORTS.contains(&transport) {
        return Err(format!("{name}: transport '{transport}' — only {}", TRANSPORTS.join(", ")));
    }
    let mut out = Map::new();
    out.insert("type".into(), json!(transport));
    if transport == "stdio" {
        let Some(cmd) = s(d, "command") else { return Err(format!("{name}: transport stdio without 'command'")) };
        out.insert("command".into(), cmd.clone());
        for k in ["args", "env"] {
            if let Some(v) = s(d, k) {
                out.insert(k.into(), v.clone());
            }
        }
    } else {
        let Some(url) = s(d, "url") else { return Err(format!("{name}: transport {transport} without 'url'")) };
        out.insert("url".into(), url.clone());
        if let Some(v) = s(d, "headers") {
            out.insert("headers".into(), v.clone());
        }
    }
    if let Some(v) = s(d, "timeout") {
        out.insert("timeout".into(), v.clone());
    }
    Ok(Value::Object(out))
}

/// Every text of a declaration that ends up in the file, with where it came
/// from. A secret can be in any of them, a password inside the url included.
pub fn texts_of(d: &Value) -> Vec<(String, String, Option<String>)> {
    let mut out = vec![];
    for field in ["url", "command"] {
        if let Some(v) = s(d, field) {
            out.push((field.to_string(), files::value_text(v), None));
        }
    }
    for (i, v) in d.get("args").and_then(Value::as_array).into_iter().flatten().enumerate() {
        out.push((format!("args[{i}]"), files::value_text(v), None));
    }
    for field in ["headers", "env"] {
        for (k, v) in d.get(field).and_then(Value::as_object).into_iter().flatten() {
            out.push((format!("{field}.{k}"), files::value_text(v), Some(k.clone())));
        }
    }
    out
}

/// In which code repos a server's file is written. The docs repo always gets
/// it; the profile can trim this, and that is the caller's business.
pub fn repos_of(contract: &Value, name: &str) -> Vec<String> {
    let wants = contract.get("mcp").and_then(|m| m.get(name)).and_then(|d| d.get("repos")).filter(|v| !v.is_null());
    match wants {
        None => vec![],
        Some(Value::String(w)) if w == "docs" => vec![],
        Some(Value::String(w)) if w == "all" => files::str_list(contract.get("repos")),
        Some(Value::Array(a)) => a.iter().map(files::value_text).collect(),
        Some(other) => vec![files::value_text(other)],
    }
}

pub fn declared(contract: &Value) -> Map<String, Value> {
    contract.get("mcp").and_then(Value::as_object).cloned().unwrap_or_default()
}

/// The servers whose place is `repo`'s file; `None` is the docs repo, which
/// holds them all.
pub fn wanted_in(contract: &Value, repo: Option<&str>) -> Vec<String> {
    declared(contract)
        .keys()
        .filter(|n| repo.is_none_or(|r| repos_of(contract, n).iter().any(|x| x == r)))
        .cloned()
        .collect()
}

/// The findings of the contract's `mcp` block and of the files written from
/// it, each with its severity first: `error` if the file would be invalid or
/// a secret is written, `warning` if it merely drifted. No network: doctor has
/// to say the same with wifi and without it.
pub fn check(docs: &Path) -> Vec<String> {
    let Ok(contract) = files::read_json(&docs.join(names::CONTRACT)) else { return vec![] };
    let declared = declared(&contract);
    if declared.is_empty() {
        return vec![];
    }
    let mut findings = vec![];
    let name_re = crate::regex!(r"^[A-Za-z0-9][A-Za-z0-9._-]*$");
    // A literal in an authorization header travels to git.
    let sensible = crate::regex!(r"(?i)(authorization|api[-_]?key|token|secret|password|bearer)");
    for (name, d) in &declared {
        if !name_re.is_match(name) || name.contains("..") {
            findings.push(format!(
                "error '{name}' is not valid as a server name — letters, digits, dot, hyphen and underscore"
            ));
            continue;
        }
        let transport = s(d, "transport").and_then(Value::as_str).unwrap_or("stdio");
        if !TRANSPORTS.contains(&transport) {
            findings.push(format!("error {name}: transport '{transport}' — only {}", TRANSPORTS.join(", ")));
            continue;
        }
        if let Err(e) = to_client_format(name, d) {
            findings.push(format!("error {e}"));
        }
        if transport == "stdio" && s(d, "url").is_some() {
            findings.push(format!("warning {name}: 'url' is not used with transport stdio"));
        }
        if transport != "stdio" && (s(d, "command").is_some() || s(d, "args").is_some()) {
            findings.push(format!("warning {name}: 'command'/'args' are not used with transport {transport}"));
        }
        for (where_, text, key) in texts_of(d) {
            for f in secrets::fingerprints_in(&text) {
                findings.push(format!("error {name}: {f} written in {where_}"));
            }
            if key.is_some_and(|k| sensible.is_match(&k)) && !text.contains("${") {
                findings.push(format!(
                    "error {name}: {where_} carries a literal value — use ${{VARIABLE}}, the file is committed"
                ));
            }
        }
    }
    // Drift both ways: a missing file (a freshly cloned machine) and a value
    // changed by hand, which doctor once signed off as conforming.
    let root = docs.parent().unwrap_or(Path::new("/"));
    let mut expected = vec![docs.to_path_buf()];
    for n in declared.keys() {
        for r in repos_of(&contract, n) {
            if root.join(&r).exists() {
                expected.push(root.join(&r));
            }
        }
    }
    let mut dirs = vec![docs.to_path_buf()];
    dirs.extend(files::str_list(contract.get("repos")).into_iter().map(|r| root.join(r)));
    for dir in dirs {
        let file = dir.join(".mcp.json");
        let label = dir.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let wanted = wanted_in(&contract, if dir == docs { None } else { Some(&label) });
        if !file.exists() {
            if expected.contains(&dir) {
                findings.push(format!("warning {label} has no .mcp.json — run 'crux mcp install'"));
            }
            continue;
        }
        let rank = match files::read_json(&file) {
            Ok(v) => v,
            Err(e) => {
                findings.push(format!("error {label}/.mcp.json unreadable: {e}"));
                continue;
            }
        };
        let servers = rank.get("mcpServers").and_then(Value::as_object).cloned().unwrap_or_default();
        for n in servers.keys() {
            if !declared.contains_key(n) {
                findings.push(format!("warning {label}/.mcp.json has '{n}', which the contract does not declare"));
            }
        }
        for (n, d) in &declared {
            let Some(current) = servers.get(n) else { continue };
            if !wanted.contains(n) {
                findings.push(format!(
                    "warning {label}/.mcp.json has '{n}', which is not declared for this repo — 'crux mcp install'"
                ));
                continue;
            }
            let Ok(want) = to_client_format(n, d) else { continue };
            if *current != want {
                findings.push(format!(
                    "warning {label}/.mcp.json has '{n}' different from what is declared — 'crux mcp install'"
                ));
            }
        }
    }
    findings
}

/// The client file: what `wanted` names is rewritten, a declared server that
/// belongs elsewhere is taken back, what someone put by hand is respected.
pub enum Action {
    Write,
    Clear,
    Diff,
}

pub fn apply(action: Action, contract: &Value, target: &Path, wanted: &[String]) -> Result<String, String> {
    let file = target.join(".mcp.json");
    let declared = declared(contract);
    // A corrupt file is someone's configuration: not overwritten silently.
    let mut current = if file.exists() {
        match files::read_json(&file) {
            Ok(v) => v,
            Err(e) => return Err(format!(".mcp.json unreadable ({e}) — left untouched")),
        }
    } else {
        json!({"mcpServers": {}})
    };
    if !current.get("mcpServers").is_some_and(Value::is_object) {
        current.as_object_mut().ok_or("not an object")?.insert("mcpServers".into(), json!({}));
    }
    let names: Vec<String> = declared.keys().cloned().collect();
    let servers = current.get("mcpServers").and_then(Value::as_object).cloned().unwrap_or_default();
    let foreign: Vec<String> = servers.keys().filter(|n| !names.contains(n)).cloned().collect();
    let stray: Vec<String> = servers.keys().filter(|n| names.contains(n) && !wanted.contains(n)).cloned().collect();
    match action {
        Action::Diff => {
            let mut out = vec![];
            for n in wanted {
                let want = to_client_format(n, &declared[n])?;
                match servers.get(n) {
                    None => out.push(format!("missing {n}")),
                    Some(c) if *c != want => out.push(format!("differs {n}")),
                    Some(_) => out.push(format!("ok {n}")),
                }
            }
            out.extend(stray.iter().map(|n| format!("stray {n}")));
            out.extend(foreign.iter().map(|n| format!("foreign {n}")));
            Ok(out.join("\n"))
        }
        Action::Clear => {
            let obj = current.as_object_mut().unwrap();
            let srv = obj.get_mut("mcpServers").unwrap().as_object_mut().unwrap();
            let removed = names.iter().filter(|n| srv.shift_remove(*n).is_some()).count();
            // A file that only held what is ours goes away entirely: an orphan
            // `{"mcpServers":{}}` is noise in the git status of whoever clones.
            if srv.is_empty() && obj.len() == 1 {
                if file.exists() {
                    std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                }
                Ok("removed the file".into())
            } else {
                std::fs::write(&file, files::json_pretty(&current)).map_err(|e| e.to_string())?;
                Ok(format!("removed {removed}"))
            }
        }
        Action::Write => {
            if wanted.is_empty() && stray.is_empty() {
                return Ok("nothing for this repo".into());
            }
            let mut converted = vec![];
            for n in wanted {
                converted.push((n.clone(), to_client_format(n, &declared[n])?));
            }
            let srv = current.get_mut("mcpServers").unwrap().as_object_mut().unwrap();
            for (n, v) in converted {
                srv.insert(n, v);
            }
            for n in &stray {
                srv.shift_remove(n);
            }
            if srv.is_empty() && current.as_object().is_some_and(|o| o.len() == 1) {
                std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                return Ok("removed the file: nothing left for this repo".into());
            }
            std::fs::write(&file, files::json_pretty(&current)).map_err(|e| e.to_string())?;
            let left =
                if foreign.is_empty() { String::new() } else { format!(" ({} foreign left intact)", foreign.len()) };
            let taken = if stray.is_empty() {
                String::new()
            } else {
                format!(" ({} taken back: not for this repo)", stray.len())
            };
            Ok(format!("written {}{taken}{left}", wanted.len()))
        }
    }
}
