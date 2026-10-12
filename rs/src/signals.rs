//! Interruptions. The handler only records the signal: the command notices it
//! when its child returns, and its guards release what it held (the registry
//! reservation, the lock) on the way out.

use std::process::{Child, Command};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

static RECEIVED: AtomicI32 = AtomicI32::new(0);

extern "C" fn record(sig: libc::c_int) {
    RECEIVED.store(sig, Ordering::SeqCst);
}

pub fn install() {
    // SAFETY: the handler only stores into an atomic, which is
    // async-signal-safe. A handler, unlike SIG_IGN, is reset on exec, so
    // children still die on Ctrl-C.
    unsafe {
        libc::signal(libc::SIGINT, record as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, record as *const () as libc::sighandler_t);
    }
}

/// The signal received, if any.
pub fn received() -> Option<i32> {
    match RECEIVED.load(Ordering::SeqCst) {
        0 => None,
        s => Some(s),
    }
}

/// The exit code a shell gives for a signal: 128 + its number.
pub fn exit_code() -> i32 {
    received().map(|s| 128 + s).unwrap_or(1)
}

/// Runs a command in its own process group, killing the whole group if a
/// signal arrives meanwhile: a setup that runs `sleep` under `bash -c` would
/// otherwise outlive the command that started it.
pub fn run_interruptible(cmd: &mut Command) -> i32 {
    use std::os::unix::process::CommandExt;
    // SAFETY: setpgid is async-signal-safe and runs in the child before exec.
    unsafe {
        cmd.pre_exec(|| {
            libc::setpgid(0, 0);
            Ok(())
        });
    }
    let mut child: Child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return 127,
    };
    loop {
        match child.try_wait() {
            Ok(Some(s)) => return s.code().unwrap_or(128),
            Ok(None) => {}
            Err(_) => return 1,
        }
        if received().is_some() {
            // SAFETY: a negative pid addresses the child's process group.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGTERM);
            }
            let _ = child.wait();
            return exit_code();
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
