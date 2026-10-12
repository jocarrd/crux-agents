//! The workspace registry, `~/.crux/workspaces.json`: which isolated spaces
//! exist on this machine, their slot, ports and task.
//!
//! Writers take a lock; readers do not, since every write is a rename. The
//! lock is a directory with the owner's pid inside: it is the only primitive
//! every system has (BusyBox's flock has no -w, macOS has no flock at all),
//! and a process that dies leaves a pid that can be checked.

use crate::{env, files, ui};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub fn path() -> PathBuf {
    env::registry_file()
}

fn lock_dir() -> PathBuf {
    path().parent().unwrap_or(Path::new("/")).join(".workspaces.lock")
}

/// 077: the registry holds the paths, branches and tasks of all projects at
/// once, including those of different clients.
pub fn init() -> std::io::Result<()> {
    let p = path();
    if let Some(d) = p.parent() {
        fs::create_dir_all(d)?;
        let _ = fs::set_permissions(d, std::os::unix::fs::PermissionsExt::from_mode(0o700));
    }
    if !p.exists() {
        // Linked into place, which fails if it is already there: checking and
        // then writing lets a second process wipe an entry just reserved.
        let tmp = p.with_extension(format!("new.{}", std::process::id()));
        files::write_atomic(&tmp, "{\"workspaces\":{}}\n", Some(0o600))?;
        let linked = fs::hard_link(&tmp, &p);
        let _ = fs::remove_file(&tmp);
        match linked {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    let _ = fs::set_permissions(&p, std::os::unix::fs::PermissionsExt::from_mode(0o600));
    Ok(())
}

pub struct Lock {
    dir: PathBuf,
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn pid_alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM) }
}

/// Takes the lock, waiting up to `tries` × 0.1 s. A lock whose owner died is
/// removed; one whose owner lives is reported with its pid.
pub fn lock(tries: u32) -> Result<Lock, String> {
    let dir = lock_dir();
    if let Some(d) = dir.parent() {
        let _ = fs::create_dir_all(d);
    }
    let seconds = tries.div_ceil(10);
    let mut attempts = 0;
    loop {
        match fs::create_dir(&dir) {
            Ok(()) => {
                let _ = fs::write(dir.join("pid"), format!("{}\n", std::process::id()));
                return Ok(Lock { dir });
            }
            Err(_) => {
                let owner = fs::read_to_string(dir.join("pid")).ok().and_then(|s| s.trim().parse::<i32>().ok());
                if let Some(pid) = owner {
                    if !pid_alive(pid) {
                        let aside = dir.with_extension(format!("lock.{}", std::process::id()));
                        if fs::rename(&dir, &aside).is_ok() {
                            let _ = fs::remove_dir_all(&aside);
                            ui::warn(format!("removed the lock of process {pid}, which no longer exists"));
                        }
                        continue;
                    }
                }
                attempts += 1;
                if attempts > tries {
                    return Err(match owner {
                        Some(pid) => {
                            format!("the registry has been held for {seconds}s by process {pid}, which is still alive")
                        }
                        None => format!("lock with no owner at {}: remove it if no crux is running", dir.display()),
                    });
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct Workspace {
    pub name: String,
    pub slot: i64,
    pub repo: String,
    pub path: String,
    pub branch: String,
    pub ports: (i64, i64),
    pub task: String,
    pub project: String,
    /// Fields this version does not know, kept as they were.
    pub extra: Map<String, Value>,
}

/// The field a workspace carries while `workspace new` is creating it: the pid
/// of the process doing it.
pub const CREATING: &str = "creating";

impl Workspace {
    /// Reserved and not yet on disk, by a process that is still alive: its
    /// folder and branch do not exist yet, and that is not an abandoned entry.
    pub fn being_created(&self) -> bool {
        self.extra.get(CREATING).and_then(Value::as_i64).is_some_and(|pid| pid_alive(pid as i32))
    }
}

impl Workspace {
    fn from_json(name: &str, v: &Value) -> Workspace {
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let ports = v.get("ports").and_then(Value::as_array);
        let port = |i: usize| ports.and_then(|p| p.get(i)).and_then(Value::as_i64).unwrap_or(0);
        let mut extra = v.as_object().cloned().unwrap_or_default();
        for k in ["slot", "repo", "path", "branch", "ports", "task", "project"] {
            extra.remove(k);
        }
        Workspace {
            name: name.to_string(),
            slot: v.get("slot").and_then(Value::as_i64).unwrap_or(0),
            repo: s("repo"),
            path: s("path"),
            branch: s("branch"),
            ports: (port(0), port(1)),
            task: s("task"),
            project: s("project"),
            extra,
        }
    }

    fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("slot".into(), json!(self.slot));
        m.insert("repo".into(), json!(self.repo));
        m.insert("path".into(), json!(self.path));
        m.insert("branch".into(), json!(self.branch));
        m.insert("ports".into(), json!([self.ports.0, self.ports.1]));
        m.insert("task".into(), json!(self.task));
        m.insert("project".into(), json!(self.project));
        for (k, v) in &self.extra {
            m.insert(k.clone(), v.clone());
        }
        Value::Object(m)
    }
}

/// An unreadable registry is not an empty one: read as empty, it would open
/// the deletion guard and make status list zero workspaces without a word.
pub fn read() -> Result<Vec<Workspace>, String> {
    let p = path();
    if !p.exists() {
        return Ok(vec![]);
    }
    let v = files::read_json(&p).map_err(|e| format!("unreadable registry: {e}"))?;
    Ok(v.get("workspaces")
        .and_then(Value::as_object)
        .map(|m| m.iter().map(|(n, w)| Workspace::from_json(n, w)).collect())
        .unwrap_or_default())
}

fn write_all(list: &[Workspace], root: &Value) -> std::io::Result<()> {
    let mut r = root.as_object().cloned().unwrap_or_default();
    let mut ws = Map::new();
    for w in list {
        ws.insert(w.name.clone(), w.to_json());
    }
    r.insert("workspaces".into(), Value::Object(ws));
    files::write_atomic(&path(), &files::json_pretty(&Value::Object(r)), Some(0o600))
}

/// Applies a change under the caller's lock.
pub fn update(f: impl FnOnce(&mut Vec<Workspace>)) -> Result<(), String> {
    let p = path();
    let root = if p.exists() {
        files::read_json(&p).map_err(|e| format!("unreadable registry: {e}"))?
    } else {
        json!({"workspaces": {}})
    };
    let mut list = read()?;
    f(&mut list);
    write_all(&list, &root).map_err(|e| e.to_string())
}

pub fn find_by_path(p: &str) -> Option<Workspace> {
    read().ok()?.into_iter().find(|w| w.path == p)
}

pub fn find(name: &str) -> Option<Workspace> {
    read().ok()?.into_iter().find(|w| w.name == name)
}
