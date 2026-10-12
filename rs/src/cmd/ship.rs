//! crux ship — the quality gate, with a receipt.
//!
//!   crux ship run -- <command...>   runs the command and records its result
//!   crux ship seal                  closes the receipt with the HEAD sha
//!   crux ship show                  shows the receipt
//!   crux ship clear                 discards it and starts over
//!
//! A sha the agent writes after saying it verified only proves someone wrote
//! a sha. `run` really executes and records the exit code, so the receipt is
//! evidence and not a statement.

use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, files, git, policy, project, task, ui};
use std::io::IsTerminal;
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

mod conventions;
mod scope;

struct Ctx {
    repo: PathBuf,
    receipt: PathBuf,
}

impl Ctx {
    fn text(&self) -> String {
        files::read_or_empty(&self.receipt)
    }
    /// A mark in the old format —a bare sha— does not say what was run: it is
    /// treated as if it were not there.
    fn stale(&self) -> bool {
        self.receipt.is_file() && !self.text().lines().any(|l| l.starts_with("run "))
    }
}

pub fn receipt_commands(text: &str) -> usize {
    text.lines().filter(|l| l.split_whitespace().next() == Some("run")).count()
}

pub fn receipt_failures(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| {
            let mut f = l.splitn(4, ' ');
            (f.next() == Some("run")).then_some(())?;
            let code = f.next()?;
            let _secs = f.next();
            (code != "0").then(|| format!("{} (exit {code})", f.next().unwrap_or("").trim_start()))
        })
        .collect()
}

pub fn receipt_kernel(text: &str) -> Option<String> {
    text.lines()
        .filter_map(|l| l.strip_prefix("kernel "))
        .next_back()
        .map(|v| v.split_whitespace().next().unwrap_or("").to_string())
}

pub fn sealed_sha(text: &str) -> Option<String> {
    text.lines()
        .filter_map(|l| l.strip_prefix("sealed "))
        .next_back()
        .map(|v| v.split_whitespace().next().unwrap_or("").to_string())
}

fn run_cmd(ctx: &Ctx, args: &[String], label: Option<&str>) -> Res {
    let args = if args.first().map(String::as_str) == Some("--") { &args[1..] } else { args };
    if args.is_empty() {
        die!("usage: crux ship run -- <command...>");
    }
    // A receipt already closed belongs to another pass: the next one starts clean.
    if ctx.receipt.is_file() && (ctx.text().lines().any(|l| l.starts_with("sealed ")) || ctx.stale()) {
        let _ = std::fs::remove_file(&ctx.receipt);
    }
    if !ctx.receipt.is_file() {
        let _ = std::fs::write(&ctx.receipt, format!("# quality gate receipt — crux\nrepo {}\n", ctx.repo.display()));
    }
    let start = Instant::now();
    let rc = match Command::new(&args[0]).args(&args[1..]).status() {
        Ok(s) => s.code().unwrap_or(128),
        Err(_) => {
            eprintln!("crux: {}: command not found", args[0]);
            127
        }
    };
    let secs = start.elapsed().as_secs();
    // The receipt records the command as declared, not the wrapper. Running it
    // again replaces its earlier result: the fix of a red run is to run it green.
    let label = label.map(String::from).unwrap_or_else(|| args.join(" "));
    let kept: Vec<String> = ctx
        .text()
        .lines()
        .filter(|l| {
            let mut f = l.splitn(4, ' ');
            !(f.next() == Some("run") && f.nth(2) == Some(label.as_str()))
        })
        .map(String::from)
        .collect();
    let mut out = kept.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(&format!("run {rc} {secs} {label}\n"));
    let _ = std::fs::write(&ctx.receipt, out);
    if rc == 0 {
        ui::ok(format!("{label} — {secs}s"));
        Ok(())
    } else {
        ui::err(format!("{label} — exit {rc}"));
        exit(rc)
    }
}

fn seal(ctx: &Ctx) -> Res {
    if !ctx.receipt.is_file() || ctx.stale() {
        die!("no receipt: pass the gate with 'crux ship run -- <command>'");
    }
    let text = ctx.text();
    let total = receipt_commands(&text);
    let failed = receipt_failures(&text);
    if total == 0 {
        die!("the receipt has not a single command run");
    }
    if !failed.is_empty() {
        ui::err(format!("{} of {total} commands failed: the gate does not close", failed.len()));
        for f in &failed {
            println!("      {f}");
        }
        return exit(1);
    }
    // The gate's behaviour belongs to the kernel that runs it: without the
    // version, a sealed receipt does not say which rules it was won under.
    let kernel = env::crux_version();
    let pinned = project::pinned_version(&ctx.repo);
    let head = git::head_sha(&ctx.repo).unwrap_or_default();
    let mut lines: Vec<String> =
        text.lines().filter(|l| !l.starts_with("sealed ") && !l.starts_with("kernel ")).map(String::from).collect();
    lines.push(format!("kernel {kernel}"));
    lines.push(format!("sealed {head} {}", chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")));
    let _ = std::fs::write(&ctx.receipt, lines.join("\n") + "\n");
    let short = git::out(&ctx.repo, &["rev-parse", "--short", "HEAD"]).unwrap_or_default();
    ui::ok(format!("gate closed on {short} with {} (crux {kernel})", ui::count(total, "check", "checks")));
    if let Some(p) = pinned.filter(|p| !p.is_empty() && *p != kernel) {
        ui::warn(format!("the project pins crux {p} and the gate was passed with {kernel}"));
        ui::info("align it with: crux upgrade");
    }
    // What was checked goes into the task as evidence: it is what the proposal
    // says afterwards, so it is not rewritten from memory.
    if let Some(f) = task::file_for_workspace(&ctx.repo.to_string_lossy()).filter(|f| f.is_file()) {
        let ok = task::record::read(&f).ok().is_some_and(|mut d| {
            task::record::verify(&mut d, &ctx.text(), &head);
            task::record::write(&f, &mut d, true).is_ok()
        });
        if ok {
            ui::info(format!("task verified: {}", f.display()));
        } else {
            ui::warn(format!("could not record the verification in {}", f.display()));
        }
    }
    Ok(())
}

fn show(ctx: &Ctx) -> Res {
    if !ctx.receipt.is_file() {
        die!("no receipt in {}", ctx.repo.display());
    }
    let text = ctx.text();
    if ctx.stale() {
        ui::warn("receipt in the old format (a bare sha): it does not say what was run");
        for l in text.lines() {
            println!("      {l}");
        }
        return Ok(());
    }
    let head = git::head_sha(&ctx.repo).unwrap_or_default();
    let sealed = sealed_sha(&text).unwrap_or_default();
    for l in text.lines() {
        println!("  {l}");
    }
    println!();
    let kernel = receipt_kernel(&text);
    let version = env::crux_version();
    match &kernel {
        None if !sealed.is_empty() => {
            ui::warn("sealed without a crux version: the receipt does not say which rules it was passed under")
        }
        Some(k) if *k != version => ui::warn(format!("sealed with crux {k}, and now {version} is running")),
        _ => {}
    }
    let short = |s: &str| s.chars().take(8).collect::<String>();
    if sealed.is_empty() {
        ui::info("not closed: 'crux ship seal'");
    } else if sealed != head {
        ui::warn(format!("closed on {}, and HEAD is {}: it has to be passed again", short(&sealed), short(&head)));
    } else {
        ui::ok(format!("current on {}", short(&head)));
    }
    Ok(())
}

fn numbered(text: &str, re: &regex::Regex) -> Vec<String> {
    text.lines().enumerate().filter(|(_, l)| re.is_match(l)).map(|(i, l)| format!("{}:{l}", i + 1)).collect()
}

/// A proposal's body is the one artifact of the flow that gets published, so
/// it goes through the same filter as the commits: no tool signature.
fn body(ctx: &Ctx, args: &[String]) -> Res {
    let Some(file) = args.first().map(PathBuf::from).filter(|f| f.is_file()) else {
        die!("usage: crux ship body <file with the body>")
    };
    let text = files::read_or_empty(&file);
    let mut failures = 0;
    let mut report = |title: String, lines: Vec<String>| {
        ui::err(title);
        for l in lines {
            println!("      {l}");
        }
        failures += 1;
    };
    let signature = crate::regex!(
        r"(?i)co-authored-by:\s*(claude|ona|copilot|cursor|devin|gemini)|claude-session:|(generated|generado) with|🤖"
    );
    let found = numbered(&text, signature);
    if !found.is_empty() {
        report("the tool's signature does not belong in a proposal".into(), found);
    }
    // The same fingerprints as the documentation and the .mcp.json files.
    let creds = crate::secrets::fingerprints_in(&text);
    if !creds.is_empty() {
        report("something that looks like a credential".into(), creds.iter().map(|s| s.to_string()).collect());
    }
    // The machine's path tells the reader nothing, and says too much about how
    // we work and for whom.
    let home = regex::escape(&env::home().to_string_lossy());
    let paths =
        regex::Regex::new(&format!(r"(^|[^A-Za-z0-9_])({home}|/home/[a-z_][a-z0-9_-]*|/Users/[A-Za-z0-9_-]+)/"))
            .unwrap();
    let found = numbered(&text, &paths);
    if !found.is_empty() {
        report("machine paths in the body".into(), found);
    }
    // The rest is declared by the profile. Those rules protect the client's
    // code repos; the docs repo is ours, and what it documents is precisely
    // our tooling.
    let docs = project::find_docs_repo(&ctx.repo);
    let profile = docs.as_deref().and_then(|d| project::contract_field(d, "profile")).unwrap_or_default();
    let in_docs = docs
        .as_deref()
        .is_some_and(|d| git::common_dir(&ctx.repo).is_some() && git::common_dir(&ctx.repo) == git::common_dir(d));
    if in_docs {
    } else if !profile.is_empty() {
        for (pattern, reason) in policy::forbidden(&profile, docs.as_deref()) {
            let Ok(re) = regex::RegexBuilder::new(&pattern).case_insensitive(true).build() else { continue };
            let found = numbered(&text, &re);
            if !found.is_empty() {
                report(format!("profile {profile}: {reason}"), found);
            }
        }
        // The docs repo name is per project, so it does not fit in a fixed
        // pattern: a path to it shows where we keep the client's notes.
        if policy::flag(&profile, docs.as_deref(), "propose.hideDocsRepo", false) {
            let name = docs.as_ref().unwrap().file_name().unwrap().to_string_lossy().to_lowercase();
            let found: Vec<String> = text
                .lines()
                .enumerate()
                .filter(|(_, l)| l.to_lowercase().contains(&name))
                .map(|(i, l)| format!("{}:{l}", i + 1))
                .collect();
            if !found.is_empty() {
                report(format!("profile {profile}: names our documentation repo"), found);
            }
        }
    } else {
        // Without a profile, what it forbids is not checked, and a client's
        // repo cloned outside the convention needs it most: this is the worst
        // place to fail open.
        ui::warn("no contract in sight: what the profile forbids was not checked");
        ui::info("if it is a client's repo, review the body by hand");
    }
    if failures > 0 {
        println!();
        ui::info("the body says what changes, what is added and why; see STANDARD.md §8");
        return exit(1);
    }
    ui::ok("the proposal body shows nothing it should not");
    Ok(())
}

/// POSIX `cksum`: the fingerprints remembered by earlier versions stay valid.
pub fn cksum(data: &[u8]) -> String {
    let mut crc: u32 = 0;
    let step = |crc: u32, byte: u8| {
        let mut c = crc ^ ((byte as u32) << 24);
        for _ in 0..8 {
            c = if c & 0x8000_0000 != 0 { (c << 1) ^ 0x04C1_1DB7 } else { c << 1 };
        }
        c
    };
    for &b in data {
        crc = step(crc, b);
    }
    let mut len = data.len();
    while len > 0 {
        crc = step(crc, (len & 0xff) as u8);
        len >>= 8;
    }
    format!("{}{}", !crc, data.len())
}

/// The kernel does not know the checks: the project declares them in
/// `quality.gate`, with a per-repo override.
fn gate(ctx: &Ctx) -> Res {
    let Some(docs) = project::find_docs_repo(&ctx.repo).filter(|d| d.join(names::CONTRACT).is_file()) else {
        die!("cannot find the project's crux.json: declare quality.gate there")
    };
    let base = files::name(&ctx.repo);
    // In a worktree the name carries the workspace suffix; the contract talks
    // about the repo.
    let repo_name = base.split("-ws-").next().unwrap_or(&base).to_string();
    let contract = project::contract_lenient(&docs).unwrap_or_default();
    let quality = contract.get("quality").cloned().unwrap_or_default();
    let own = quality.get("repos").and_then(|r| r.get(&repo_name)).and_then(|r| r.get("gate")).filter(|g| !g.is_null());
    let commands = files::str_list(own.or_else(|| quality.get("gate")));
    let commands: Vec<String> = commands.into_iter().filter(|c| !c.is_empty()).collect();
    if commands.is_empty() {
        ui::err(format!("the contract does not declare what to check in {repo_name}"));
        ui::info(format!("declare it in {}/crux.json:", docs.display()));
        ui::info("  \"quality\": { \"gate\": [\"<command>\", \"<command>\"] }");
        ui::info(format!("or per repo:  \"quality\": {{ \"repos\": {{ \"{repo_name}\": {{ \"gate\": [...] }} }} }}"));
        return exit(1);
    }
    // These commands come from a versioned file, so they change with the
    // branch checked out. Their fingerprint is remembered: when it changes,
    // what is about to run is shown before running it. A contract that arrives
    // in a proposal does not execute silently.
    let state = env::home().join(".crux/state");
    let _ = files::mkdir_private(&state);
    let key = cksum(format!("{}/{repo_name}", docs.display()).as_bytes());
    let key: String = key.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    let fingerprint_file = state.join(format!("gate-{key}"));
    let joined = commands.join("\n");
    let now = cksum(joined.as_bytes());
    let before = files::read_or_empty(&fingerprint_file);
    if now != before {
        if before.is_empty() {
            ui::info(format!("the quality gate of {repo_name}, declared in the contract:"));
        } else {
            ui::warn(format!("the quality gate of {repo_name} has changed since last time"));
        }
        for c in &commands {
            println!("      {c}");
        }
        if env::var("CRUX_GATE_ASSUME_YES").as_deref() != Some("1") && std::io::stdin().is_terminal() {
            print!("      Run them? [y/N] ");
            let _ = std::io::Write::flush(&mut std::io::stdout());
            let mut answer = String::new();
            let _ = std::io::stdin().read_line(&mut answer);
            if !matches!(answer.trim(), "s" | "S" | "y" | "Y") {
                die!("gate cancelled");
            }
        }
        let _ = std::fs::write(&fingerprint_file, &now);
    }
    let _ = std::fs::remove_file(&ctx.receipt);
    let mut failures = 0;
    for c in &commands {
        if run_cmd(ctx, &["bash".into(), "-c".into(), c.clone()], Some(c)).is_err() {
            failures += 1;
        }
    }
    if failures > 0 {
        ui::err(format!("{} failing: the gate does not close", ui::count(failures, "check", "checks")));
        return exit(1);
    }
    ui::info("commit and close with: crux ship seal");
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    match argv.first().map(String::as_str) {
        Some("scope") => return scope::run(rest),
        Some("conventions") => return conventions::run(rest),
        _ => {}
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(repo) = git::toplevel(&cwd) else { die!("this is not a git repository") };
    let ctx = Ctx { receipt: repo.join(names::GATE_RECEIPT), repo };
    match argv.first().map(String::as_str).unwrap_or("") {
        "run" => run_cmd(&ctx, rest, env::var("LABEL").as_deref()),
        "gate" => gate(&ctx),
        "seal" => seal(&ctx),
        "show" => show(&ctx),
        "clear" => {
            let _ = std::fs::remove_file(&ctx.receipt);
            ui::ok("receipt discarded");
            Ok(())
        }
        "body" => body(&ctx, rest),
        _ => {
            for l in crate::help::text("ship").unwrap_or_default().lines().take(15) {
                println!("{l}");
            }
            exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn cksum_matches_posix() {
        // `printf 'abc' | cksum` → 1219131554 3
        assert_eq!(super::cksum(b"abc"), "12191315543");
    }
}
