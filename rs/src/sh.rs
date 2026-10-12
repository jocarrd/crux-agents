//! Running other programs: git, gh, and whatever a project's contract
//! declares. Arguments always go as a list, never through a shell, except
//! for the commands a contract writes as shell lines on purpose.

use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

pub struct Run {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Run {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
    /// stdout without the trailing newline, as `$(...)` gives it.
    pub fn out(&self) -> String {
        self.stdout.trim_end_matches('\n').to_string()
    }
}

fn finish(out: std::io::Result<Output>) -> Run {
    match out {
        Ok(o) => Run {
            code: o.status.code().unwrap_or(128),
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
        },
        // Not found: 127, the code a shell gives, which callers check for.
        Err(e) => Run { code: 127, stdout: String::new(), stderr: e.to_string() },
    }
}

pub fn capture(program: &str, args: &[&str]) -> Run {
    finish(Command::new(program).args(args).stdin(Stdio::null()).output())
}

pub fn capture_in(dir: &Path, program: &str, args: &[&str]) -> Run {
    finish(Command::new(program).args(args).current_dir(dir).stdin(Stdio::null()).output())
}

pub fn capture_cmd(cmd: &mut Command) -> Run {
    finish(cmd.stdin(Stdio::null()).output())
}

/// Runs with the terminal attached: the person sees git's or the tool's own
/// output as it happens.
pub fn status(cmd: &mut Command) -> i32 {
    cmd.status().map(|s| s.code().unwrap_or(128)).unwrap_or(127)
}

pub fn exists(program: &str) -> bool {
    if program.contains('/') {
        return Path::new(program).is_file();
    }
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|d| {
            let p = d.join(program);
            p.is_file() && is_executable(&p)
        })
    })
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

/// Like `timeout`: 124 when time runs out, the command's own code otherwise.
/// macOS has no `timeout`, so it is done with the process API.
pub fn with_timeout(cmd: &mut Command, seconds: u64) -> Run {
    let child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return Run { code: 127, stdout: String::new(), stderr: e.to_string() },
    };
    // The pipes are drained on threads: a command that writes more than the
    // pipe holds would block forever waiting for a reader.
    let mut out = child.stdout.take().unwrap();
    let mut err = child.stderr.take().unwrap();
    let t_out = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = std::io::Read::read_to_end(&mut out, &mut s);
        s
    });
    let t_err = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = std::io::Read::read_to_end(&mut err, &mut s);
        s
    });
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let code = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(128),
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break 124;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => break 125,
        }
    };
    Run {
        code,
        stdout: String::from_utf8_lossy(&t_out.join().unwrap_or_default()).into_owned(),
        stderr: String::from_utf8_lossy(&t_err.join().unwrap_or_default()).into_owned(),
    }
}

/// A shell line, as the contract writes it (quality gates, setup steps).
pub fn shell(line: &str) -> Command {
    let mut c = Command::new("bash");
    c.arg("-c").arg(line);
    c
}
