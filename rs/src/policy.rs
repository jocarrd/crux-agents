//! Project profiles (`multi-repo`, `client-repo`): verifiable policy in three
//! layers, from the general to the specific — the one the kernel ships, the
//! user's, which survives upgrades, and the project's. They overlap field by
//! field, so a project changes one field without copying the rest.

use crate::{env, files, project};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

pub fn layers(name: &str, docs: Option<&Path>) -> Vec<PathBuf> {
    let mut out = vec![];
    if let Some(h) = env::crux_home() {
        out.push(h.join(format!("profiles/{name}.json")));
    }
    out.push(env::home().join(format!(".crux/profiles/{name}.json")));
    if let Some(d) = docs {
        out.push(d.join("profile.json"));
    }
    out.into_iter().filter(|p| p.is_file()).collect()
}

pub fn exists(name: &str, docs: Option<&Path>) -> bool {
    !layers(name, docs).is_empty()
}

fn merge(a: &mut Map<String, Value>, b: &Map<String, Value>) {
    for (k, v) in b {
        match (a.get_mut(k), v) {
            (Some(Value::Object(x)), Value::Object(y)) => merge(x, y),
            _ => {
                a.insert(k.clone(), v.clone());
            }
        }
    }
}

/// The profile with its layers merged. A layer that does not parse is an
/// error, not an empty layer.
pub fn merged(name: &str, docs: Option<&Path>) -> Result<Value, String> {
    let mut out = Map::new();
    for f in layers(name, docs) {
        let v = files::read_json(&f).map_err(|e| format!("{}: {e}", f.display()))?;
        if let Value::Object(o) = v {
            merge(&mut out, &o);
        }
    }
    Ok(Value::Object(out))
}

pub fn get(name: &str, docs: Option<&Path>, key: &str) -> Option<String> {
    merged(name, docs).ok().and_then(|v| files::get_str(&v, key))
}

/// A yes/no setting of the profile; `default` when it does not say.
pub fn flag(name: &str, docs: Option<&Path>, key: &str, default: bool) -> bool {
    get(name, docs, key).map_or(default, |v| v == "true")
}

/// The language commits and proposals are written in: the contract wins,
/// then the profile, and with nobody saying anything, English.
pub fn commit_language(profile: &str, docs: Option<&Path>) -> String {
    if let Some(d) = docs {
        if let Some(c) = project::contract_lenient(d) {
            if let Some(Value::String(l)) = c.get("commit").and_then(|x| x.get("language")) {
                if !l.is_empty() {
                    return l.clone();
                }
            }
        }
    }
    get(profile, docs, "commit.language").unwrap_or_else(|| "en".into())
}

/// One pattern with its reason. Profiles written before the keys were
/// renamed use "patron" and "motivo": both spellings are read.
pub fn forbidden(name: &str, docs: Option<&Path>) -> Vec<(String, String)> {
    let Ok(v) = merged(name, docs) else { return vec![] };
    let list = v.get("propose").and_then(|p| p.get("forbid")).and_then(Value::as_array).cloned().unwrap_or_default();
    list.iter()
        .filter_map(|e| {
            let pattern = match e {
                Value::String(s) => s.clone(),
                Value::Object(_) => e.get("pattern").or_else(|| e.get("patron")).and_then(Value::as_str)?.to_string(),
                _ => return None,
            };
            if pattern.is_empty() {
                return None;
            }
            let reason = e
                .get("reason")
                .or_else(|| e.get("motivo"))
                .and_then(Value::as_str)
                .unwrap_or("the profile does not allow this in a proposal")
                .to_string();
            Some((pattern, reason))
        })
        .collect()
}
