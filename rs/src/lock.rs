//! A lock is a directory: `mkdir` is atomic and exists on every system. Four
//! commands had written their own, each with its own idea of when a lock is
//! dead; they share this one and keep that idea as their policy.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// When a lock nobody releases is taken as left by a process that died.
pub enum Stale {
    /// Older than this: for a lock held only while a file is written.
    Age(Duration),
    /// Its owner, whose pid it holds, no longer exists: for a lock held for as
    /// long as its owner needs, which no age can bound.
    DeadOwner,
}

pub struct Policy {
    pub stale: Stale,
    pub retry: Duration,
    /// How many times it is tried again before giving up; `None` waits for as
    /// long as it takes, `Some(0)` does not wait.
    pub tries: Option<u32>,
}

pub enum Error {
    /// Another process holds it; its pid, when the lock records one.
    Held {
        owner: Option<u32>,
    },
    Io(std::io::Error),
}

/// Released when dropped, on every path out of the command.
pub struct DirLock(PathBuf);

impl Drop for DirLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub fn pid_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM) }
}

fn owner(dir: &Path) -> Option<u32> {
    fs::read_to_string(dir.join("pid")).ok().and_then(|s| s.trim().parse().ok())
}

/// Whether a lock left by a dead process was cleared, so the next try can take it.
fn clear_if_stale(dir: &Path, stale: &Stale) -> bool {
    match stale {
        Stale::Age(limit) => {
            let old = fs::metadata(dir)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > *limit);
            old && fs::remove_dir_all(dir).is_ok()
        }
        Stale::DeadOwner => {
            let Some(pid) = owner(dir).filter(|p| !pid_alive(*p)) else { return false };
            // Moved aside before it is removed, so a removal half done does
            // not leave a lock nobody owns. Two processes clearing the same
            // dead lock at once can still both take it: as with the age, that
            // race needs two of them to find it dead in the same instant.
            let aside = dir.with_extension(format!("lock.{}", std::process::id()));
            if fs::rename(dir, &aside).is_err() {
                return false;
            }
            let _ = fs::remove_dir_all(&aside);
            crate::ui::warn(format!("removed the lock of process {pid}, which no longer exists"));
            true
        }
    }
}

/// Takes the lock at `dir`, calling `waiting` each time it has to wait.
pub fn take(dir: &Path, policy: &Policy, mut waiting: impl FnMut()) -> Result<DirLock, Error> {
    // Created private when missing; an existing folder keeps the permissions
    // it has, which are not the lock's to change.
    if let Some(parent) = dir.parent().filter(|p| !p.exists()) {
        crate::files::mkdir_private(parent).map_err(Error::Io)?;
    }
    let mut waits = 0;
    loop {
        match fs::create_dir(dir) {
            Ok(()) => {
                // Only the policy that reads it writes the pid: an empty lock
                // is what older versions of crux can remove, and one with a
                // file inside kept them retrying forever.
                if matches!(policy.stale, Stale::DeadOwner) {
                    if let Err(e) = fs::write(dir.join("pid"), format!("{}\n", std::process::id())) {
                        let _ = fs::remove_dir_all(dir);
                        return Err(Error::Io(e));
                    }
                }
                return Ok(DirLock(dir.to_path_buf()));
            }
            Err(e) if e.kind() != std::io::ErrorKind::AlreadyExists => return Err(Error::Io(e)),
            Err(_) => {}
        }
        if clear_if_stale(dir, &policy.stale) {
            continue;
        }
        if policy.tries.is_some_and(|t| waits >= t) {
            return Err(Error::Held { owner: owner(dir) });
        }
        waiting();
        std::thread::sleep(policy.retry);
        waits += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(stale: Stale, tries: u32) -> Policy {
        Policy { stale, retry: Duration::from_millis(1), tries: Some(tries) }
    }

    /// A folder of its own per test, removed when the test ends.
    struct Scratch(PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn scratch(name: &str) -> (Scratch, PathBuf) {
        let d = std::env::temp_dir().join(format!("crux-lock-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let lock = d.join("x.lock");
        (Scratch(d), lock)
    }

    #[test]
    fn a_held_lock_is_refused_with_its_owner_and_free_again_once_dropped() {
        let (_s, dir) = scratch("held");
        let first = take(&dir, &policy(Stale::DeadOwner, 0), || {}).ok().unwrap();
        match take(&dir, &policy(Stale::DeadOwner, 2), || {}) {
            Err(Error::Held { owner }) => assert_eq!(owner, Some(std::process::id())),
            _ => panic!("a held lock was taken twice"),
        }
        drop(first);
        assert!(take(&dir, &policy(Stale::DeadOwner, 0), || {}).is_ok());
    }

    #[test]
    fn a_lock_older_than_its_age_is_cleared() {
        let (_s, dir) = scratch("age");
        fs::create_dir_all(&dir).unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert!(take(&dir, &policy(Stale::Age(Duration::from_millis(5)), 0), || {}).is_ok());
    }

    #[test]
    fn a_lock_whose_owner_died_is_cleared_and_one_alive_is_not() {
        let (_s, dir) = scratch("owner");
        fs::create_dir_all(&dir).unwrap();
        // A pid no process can have.
        fs::write(dir.join("pid"), "2147483646\n").unwrap();
        assert!(take(&dir, &policy(Stale::DeadOwner, 0), || {}).is_ok());
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("pid"), format!("{}\n", std::process::id())).unwrap();
        assert!(matches!(take(&dir, &policy(Stale::DeadOwner, 1), || {}), Err(Error::Held { .. })));
    }

    #[test]
    fn it_waits_as_many_times_as_it_is_told() {
        let (_s, dir) = scratch("tries");
        let _held = take(&dir, &policy(Stale::Age(Duration::from_secs(60)), 0), || {}).ok().unwrap();
        let mut waited = 0;
        let _ = take(&dir, &policy(Stale::Age(Duration::from_secs(60)), 3), || waited += 1);
        assert_eq!(waited, 3);
    }

    #[test]
    fn a_lock_by_age_stays_empty_so_older_versions_can_remove_it() {
        let (_s, dir) = scratch("empty");
        let _held = take(&dir, &policy(Stale::Age(Duration::from_secs(60)), 0), || {}).ok().unwrap();
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
    }

    #[test]
    fn no_tries_means_no_wait() {
        let (_s, dir) = scratch("nowait");
        let _held = take(&dir, &policy(Stale::Age(Duration::from_secs(60)), 0), || {}).ok().unwrap();
        let mut waited = false;
        assert!(take(&dir, &policy(Stale::Age(Duration::from_secs(60)), 0), || waited = true).is_err());
        assert!(!waited, "a lock that must not wait waited");
    }
}
