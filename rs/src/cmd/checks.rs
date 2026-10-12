//! crux checks — waits for a proposal's checks and says why it fails.
//!
//!   crux checks [<number>] [--wait] [--timeout <seconds>] [--lines <n>]
//!
//! Opening the proposal is not finishing it: CI runs afterwards, and if nobody
//! looks at it the red is discovered when someone goes to merge. This waits,
//! and when something fails it brings only the tail of the failed job's log:
//! a CI's whole log is thousands of lines, and reading it costs more than
//! fixing the failure.
//!
//! Exit: 0 all green · 1 something fails · 2 no checks · 3 time ran out with
//! checks still pending.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::{die, env, sh, ui};
use serde_json::Value;
use std::time::{Duration, Instant};

struct Check {
    name: String,
    bucket: &'static str,
    link: String,
}

/// The rollup mixes two shapes —CI jobs and third-party statuses— turned
/// here into one. Read from the rollup and not `gh pr checks --json`, which
/// the gh versions still in circulation do not have.
fn read_checks(num: &str) -> Result<Vec<Check>, ()> {
    let r = sh::capture("gh", &["pr", "view", num, "--json", "statusCheckRollup"]);
    if !r.ok() {
        eprintln!(
            "{}error{} could not read the checks of #{num} (code {})",
            ui::palette().red,
            ui::palette().off,
            r.code
        );
        for l in format!("{}{}", r.stdout, r.stderr).lines().take(5) {
            eprintln!("      {l}");
        }
        return Err(());
    }
    let Some(list) = serde_json::from_str::<Value>(&r.stdout)
        .ok()
        .and_then(|v| v.get("statusCheckRollup").and_then(Value::as_array).cloned())
    else {
        eprintln!(
            "{}error{} gh returned something that is not the rollup of #{num}",
            ui::palette().red,
            ui::palette().off
        );
        return Err(());
    };
    let s = |c: &Value, k: &str| c.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    Ok(list
        .iter()
        .map(|c| {
            let status = s(c, "status").to_uppercase();
            let result = {
                let x = s(c, "conclusion");
                if x.is_empty() {
                    s(c, "state")
                } else {
                    x
                }
            }
            .to_uppercase();
            let bucket = if s(c, "__typename") == "CheckRun" || !s(c, "status").is_empty() {
                if !status.is_empty() && status != "COMPLETED" {
                    "pending"
                } else {
                    match result.as_str() {
                        "SUCCESS" => "pass",
                        "SKIPPED" | "NEUTRAL" => "skipping",
                        "CANCELLED" | "STALE" => "cancel",
                        _ => "fail",
                    }
                }
            } else {
                match result.as_str() {
                    "SUCCESS" => "pass",
                    "PENDING" | "EXPECTED" => "pending",
                    _ => "fail",
                }
            };
            let name =
                [s(c, "name"), s(c, "context")].into_iter().find(|x| !x.is_empty()).unwrap_or_else(|| "?".into());
            let link = [s(c, "detailsUrl"), s(c, "targetUrl")].into_iter().find(|x| !x.is_empty()).unwrap_or_default();
            Check { name, bucket, link }
        })
        .collect())
}

/// `gh run view --log-failed` comes out empty in gh versions still in
/// distributions, so the job's log comes from the API and is trimmed here:
/// what precedes the last error, without the cleanup at the end.
fn failure_log(job: &str, n: usize) -> String {
    let repo = sh::capture("gh", &["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
    if !repo.ok() {
        return "(could not determine the repository to request the log)".into();
    }
    let log = sh::capture("gh", &["api", &format!("repos/{}/actions/jobs/{job}/logs", repo.out())]);
    if !log.ok() {
        return "(the log is no longer available)".into();
    }
    let stamp = crate::regex!(r"^\S+Z ");
    let lines: Vec<String> = log.stdout.split('\n').map(|l| stamp.replace(l, "").into_owned()).collect();
    let last = match lines.iter().rposition(|l| l.contains("##[error]")) {
        Some(i) => i as i64,
        None => {
            let cleanup = lines.iter().position(|l| l.starts_with("Post job cleanup"));
            (match cleanup {
                Some(c) if c > 0 => c,
                _ => lines.len(),
            }) as i64
                - 1
        }
    };
    // Stack traces eat the trim and the message ends up outside: two lines of
    // each stack are kept and the rest is counted.
    let at = crate::regex!(r"^\s*at ");
    let mut compact = vec![];
    let mut stack = 0;
    let mut i = last;
    while i >= 0 && compact.len() < n {
        let l = &lines[i as usize];
        i -= 1;
        if at.is_match(l) {
            stack += 1;
            if stack == 3 {
                compact.push("    … (stack trace trimmed)".to_string());
            }
            if stack > 2 {
                continue;
            }
        } else {
            stack = 0;
        }
        // A minified line can have thousands of characters.
        compact.push(if l.chars().count() > 300 {
            format!("{} …", l.chars().take(300).collect::<String>())
        } else {
            l.clone()
        });
    }
    compact.reverse();
    compact.join("\n")
}

pub fn run(argv: &[String]) -> Res {
    let (mut num, mut wait, mut timeout, mut lines) = (String::new(), false, "900".to_string(), "60".to_string());
    let interval: u64 = env::var("CRUX_CHECKS_INTERVAL").and_then(|v| v.parse().ok()).unwrap_or(15);
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--wait" => wait = true,
            "--timeout" => timeout = p.value(),
            "--lines" => lines = p.value(),
            a if a.starts_with('-') => die!("unknown option: {a}"),
            a => num = a.to_string(),
        }
    }
    let digits = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit());
    if !digits(&timeout) {
        die!("--timeout is whole seconds, not '{timeout}'");
    }
    if !digits(&lines) {
        die!("--lines is an integer, not '{lines}'");
    }
    if !num.is_empty() && !digits(&num) {
        die!("the proposal number is an integer, not '{num}'");
    }
    if !sh::exists("gh") {
        die!("gh is needed to read the checks");
    }
    if !sh::capture("gh", &["auth", "status"]).ok() {
        die!("gh is not authenticated");
    }
    if num.is_empty() {
        num = sh::capture("gh", &["pr", "view", "--json", "number", "-q", ".number"]).out();
        if num.is_empty() {
            die!("no open proposal for this branch — pass the number");
        }
    }
    let timeout: u64 = timeout.parse().unwrap_or(900);
    let lines: usize = lines.parse().unwrap_or(60);
    let start = Instant::now();
    let mut empty_rounds = 0;
    let data = loop {
        let Ok(data) = read_checks(&num) else { return exit(1) };
        let failing = data.iter().filter(|c| c.bucket == "fail" || c.bucket == "cancel").count();
        let pending = data.iter().filter(|c| c.bucket == "pending").count();
        if data.is_empty() {
            // Just opened or just pushed, a proposal takes a while to show the
            // CI even if it is already queued.
            if wait && empty_rounds < 12 {
                empty_rounds += 1;
                std::thread::sleep(Duration::from_secs(interval));
                continue;
            }
            ui::warn(format!("#{num} has no automatic checks"));
            ui::info("nothing blocking it is not the same as verified");
            return exit(2);
        }
        if !(wait && pending > 0 && failing == 0) || start.elapsed().as_secs() >= timeout {
            break data;
        }
        std::thread::sleep(Duration::from_secs(interval));
    };
    let failing = data.iter().filter(|c| c.bucket == "fail" || c.bucket == "cancel").count();
    let pending = data.iter().filter(|c| c.bucket == "pending").count();

    println!("checks of #{num}");
    let order = |b: &str| match b {
        "fail" => 0,
        "cancel" => 1,
        "pending" => 2,
        "pass" => 3,
        "skipping" => 4,
        _ => 5,
    };
    let mut sorted: Vec<&Check> = data.iter().collect();
    sorted.sort_by_key(|c| order(c.bucket));
    // What is green does not need to be read one by one.
    let green = sorted.iter().filter(|c| c.bucket == "pass" || c.bucket == "skipping").count();
    for c in sorted.iter().filter(|c| c.bucket != "pass" && c.bucket != "skipping") {
        println!("      {:<9} {}", c.bucket, c.name);
    }
    if green > 0 {
        println!("      {green} green or skipped");
    }
    if failing > 0 {
        println!();
        // Only GitHub Actions jobs give their log through gh; for the rest the
        // link is given, which is where the reason is.
        let job_re = crate::regex!(r"/actions/runs/([0-9]+)/job/([0-9]+)");
        let mut shown = 0;
        for c in data.iter().filter(|c| c.bucket == "fail" || c.bucket == "cancel") {
            match job_re.captures(&c.link) {
                Some(m) if shown < 2 => {
                    shown += 1;
                    let p = ui::palette();
                    println!("{}── {}: last {lines} lines of the log {}", p.dim, c.name, p.off);
                    for l in failure_log(&m[2], lines).lines() {
                        println!("      {l}");
                    }
                }
                _ => {
                    ui::err(&c.name);
                    if !c.link.is_empty() {
                        ui::info(&c.link);
                    }
                }
            }
        }
        return exit(1);
    }
    if pending > 0 {
        ui::warn(ui::count(pending, "check is still pending", "checks are still pending"));
        if wait {
            ui::info(format!("the {timeout}s wait ran out"));
        }
        return exit(3);
    }
    ui::ok("all green");
    Ok(())
}
