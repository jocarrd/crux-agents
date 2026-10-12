//! crux mcp — the MCP servers the project declares, placed where the agent
//! reads them.
//!
//!   crux mcp status     what the contract declares, what is written and whether it responds
//!   crux mcp install    writes the .mcp.json files of the repos that apply
//!   crux mcp remove     removes only what the contract declares
//!
//! An MCP is a capability of the project, not of the machine: it is declared
//! in `crux.json` and travels in git, like the context pointers, and not in
//! each laptop's local configuration —which is lost when changing machines.

use crate::error::Res;
use crate::mcp::{self, Action};
use crate::{die, files, policy, project, sh, ui};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

struct Ctx {
    docs: PathBuf,
    root: PathBuf,
    contract: Value,
    profile: String,
}

fn field(ctx: &Ctx, name: &str, f: &str) -> String {
    ctx.contract
        .get("mcp")
        .and_then(|m| m.get(name))
        .and_then(|d| d.get(f))
        .filter(|v| !v.is_null())
        .map(|v| match v {
            Value::Array(a) => a.iter().map(files::value_text).collect::<Vec<_>>().join(" "),
            other => files::value_text(other),
        })
        .unwrap_or_default()
}

/// Where the client profile writes nothing in the client's repos, a
/// .mcp.json is no exception: only the docs repo gets it.
fn targets(ctx: &Ctx, name: &str) -> Vec<PathBuf> {
    let mut out = vec![ctx.docs.clone()];
    let requested = mcp::repos_of(&ctx.contract, name);
    if requested.is_empty() {
        return out;
    }
    if !policy::flag(&ctx.profile, Some(&ctx.docs), "pointers.write", true) {
        eprintln!(
            "{}warn{}  {name}: the '{}' profile does not write in code repos — only in the docs repo",
            ui::palette().yellow,
            ui::palette().off,
            ctx.profile
        );
        return out;
    }
    for repo in requested.into_iter().filter(|r| !r.is_empty()) {
        let d = ctx.root.join(&repo);
        if d.is_dir() {
            out.push(d);
        } else {
            eprintln!(
                "{}warn{}  {name}: declares the repo '{repo}', which is not cloned",
                ui::palette().yellow,
                ui::palette().off
            );
        }
    }
    out
}

/// Each folder with the servers it gets. A code repo that gets none but
/// holds a file is visited too: what crux once wrote there has to be taken
/// back.
fn plan(ctx: &Ctx) -> BTreeMap<PathBuf, Vec<String>> {
    let mut out: BTreeMap<PathBuf, Vec<String>> = BTreeMap::new();
    for n in mcp::declared(&ctx.contract).keys() {
        for dir in targets(ctx, n) {
            out.entry(dir).or_default().push(n.clone());
        }
    }
    if policy::flag(&ctx.profile, Some(&ctx.docs), "pointers.write", true) {
        for r in files::str_list(ctx.contract.get("repos")) {
            let d = ctx.root.join(r);
            if d.join(".mcp.json").is_file() {
                out.entry(d).or_default();
            }
        }
    }
    out
}

fn base(p: &Path) -> String {
    p.file_name().unwrap_or_default().to_string_lossy().into_owned()
}

/// A declared server that does not respond is the broken-hook problem. With
/// stdio the process is not started —side effects are not a status's
/// business—: the binary has to exist, which is where it really fails.
fn try_out(ctx: &Ctx, n: &str) {
    let transport = {
        let t = field(ctx, n, "transport");
        if t.is_empty() {
            "stdio".to_string()
        } else {
            t
        }
    };
    if transport == "stdio" {
        let cmd = field(ctx, n, "command");
        if cmd.is_empty() {
            ui::err(format!("{n} — no 'command'"));
        } else if sh::exists(&cmd) {
            ui::ok(format!("{n} — '{cmd}' is on the PATH"));
        } else {
            ui::err(format!("{n} — '{cmd}' is not on this machine's PATH"));
        }
        return;
    }
    let url = field(ctx, n, "url");
    if url.is_empty() {
        ui::err(format!("{n} — no 'url'"));
        return;
    }
    if !sh::exists("curl") {
        ui::warn(format!("{n} — no curl, cannot check"));
        return;
    }
    let body = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"crux","version":"1"}}}"#;
    let answer = sh::capture(
        "curl",
        &[
            "-s",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "--max-time",
            "8",
            "-X",
            "POST",
            &url,
            "-H",
            "Content-Type: application/json",
            "-H",
            "Accept: application/json, text/event-stream",
            "-d",
            body,
        ],
    )
    .stdout;
    match answer.as_str() {
        a if a.starts_with('2') => ui::ok(format!("{n} — responds ({a})")),
        "401" | "403" => ui::warn(format!("{n} — responds but asks for credentials ({answer})")),
        "000" | "" => ui::err(format!("{n} — does not answer")),
        a => ui::err(format!("{n} — responds {a}")),
    }
}

fn status(ctx: &Ctx) -> Res {
    let names: Vec<String> = mcp::declared(&ctx.contract).keys().cloned().collect();
    if names.is_empty() {
        ui::info("the contract declares no MCP server");
        return Ok(());
    }
    println!("declared in {}/crux.json", base(&ctx.docs));
    for n in &names {
        let t = {
            let t = field(ctx, n, "transport");
            if t.is_empty() {
                "stdio".to_string()
            } else {
                t
            }
        };
        let w = if t == "stdio" { field(ctx, n, "command") } else { field(ctx, n, "url") };
        ui::info(format!("{n:<18} {t:<6} {}", if w.is_empty() { "?".to_string() } else { w }));
    }
    println!();
    println!("written in the repos");
    for (dir, wanted) in plan(ctx) {
        // A file that cannot be read is exactly the one that cannot vanish
        // from the report: the repo would look healthy by not appearing.
        match mcp::apply(Action::Diff, &ctx.contract, &dir, &wanted) {
            Err(e) => ui::err(format!("{} — {e}", base(&dir))),
            Ok(out) => {
                for line in out.lines() {
                    let b = base(&dir);
                    if let Some(r) = line.strip_prefix("ok ") {
                        ui::ok(format!("{b} — {r}"));
                    } else if let Some(r) = line.strip_prefix("missing ") {
                        ui::warn(format!("{b} — missing {r}; run 'crux mcp install'"));
                    } else if let Some(r) = line.strip_prefix("differs ") {
                        ui::warn(format!("{b} — {r} differs from the contract; 'crux mcp install'"));
                    } else if let Some(r) = line.strip_prefix("stray ") {
                        ui::warn(format!("{b} — {r} is not declared for this repo; 'crux mcp install' takes it back"));
                    } else if let Some(r) = line.strip_prefix("foreign ") {
                        ui::info(format!("{b} — {r} was put there by hand; crux does not touch it"));
                    }
                }
            }
        }
    }
    println!();
    println!("do they respond?");
    for n in &names {
        try_out(ctx, n);
    }
    Ok(())
}

fn install(ctx: &Ctx) -> Res {
    if mcp::declared(&ctx.contract).is_empty() {
        ui::info("the contract declares no MCP server");
        return Ok(());
    }
    // Validated before writing: nobody warns about an invalid .mcp.json, the
    // client simply does not connect.
    let problems: Vec<String> =
        mcp::check(&ctx.docs).into_iter().filter_map(|l| l.strip_prefix("error ").map(String::from)).collect();
    if !problems.is_empty() {
        for p in &problems {
            ui::err(p);
        }
        die!("the contract has errors; nothing is written");
    }
    for (dir, wanted) in plan(ctx) {
        match mcp::apply(Action::Write, &ctx.contract, &dir, &wanted) {
            Ok(out) => ui::ok(format!("{} — {out}", base(&dir))),
            Err(e) => die!("{} — {e}", base(&dir)),
        }
    }
    println!();
    ui::info("the client asks for approval the first time it opens a project with .mcp.json");
    ui::info("and it is turned off per project with /mcp, without touching this configuration");
    Ok(())
}

fn remove(ctx: &Ctx) -> Res {
    for (dir, wanted) in plan(ctx) {
        match mcp::apply(Action::Clear, &ctx.contract, &dir, &wanted) {
            Ok(out) => ui::ok(format!("{} — {out}", base(&dir))),
            Err(e) => ui::err(format!("{} — {e}", base(&dir))),
        }
    }
    ui::info("what the contract did not declare has been left as it was");
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(docs) = project::find_docs_repo(&cwd) else { die!("no docs repo found from here") };
    if !project::contract_file(&docs).is_file() {
        die!("no crux.json in {}", docs.display());
    }
    let contract = match project::read_contract(&docs) {
        Ok(c) => c,
        Err(e) => die!("crux.json cannot be read: {e}"),
    };
    let profile = files::get_str(&contract, "profile").unwrap_or_else(|| "multi-repo".into());
    let root = docs.parent().unwrap().to_path_buf();
    let ctx = Ctx { docs, root, contract, profile };
    match argv.first().map(String::as_str).unwrap_or("status") {
        "status" => status(&ctx),
        "install" => install(&ctx),
        "remove" => remove(&ctx),
        _ => die!("usage: crux mcp status|install|remove"),
    }
}
