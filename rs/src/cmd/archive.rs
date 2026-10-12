//! crux archive — mark a code repo of the project as archived, or bring it back.
//!
//!   crux archive <repo> --reason "<why>" [--no-remote]
//!   crux unarchive <repo> [--no-remote]
//!
//! An archived repo is out of production but kept. The contract is what says
//! so —`archived` in crux.json, with since and reason— whatever the git
//! provider allows: on GitHub the remote is archived too and becomes read
//! only; elsewhere crux still treats it as archived. Without this, a retired
//! service keeps its deploy workflow and a merge in its repo deploys it
//! again.
//!
//! From then on it is no longer in `repos`: clone, sync, link and doctor treat
//! it as gone; workspace new and merge refuse to work in it, and its local
//! clone refuses to push.

use crate::args::Parser;
use crate::error::Res;
use crate::names;
use crate::{die, files, git, project, sh, ui};
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

struct Ctx {
    repo: String,
    remote: bool,
    contract: Value,
}

/// GitHub is the one the kernel knows how to archive; for any other the
/// contract is enough, and the person is told to do it there by hand.
fn provider(ctx: &Ctx, action: &str) {
    if !ctx.remote {
        ui::info("remote left as it is (--no-remote)");
        return;
    }
    let url = project::remote_url(&ctx.contract, &ctx.repo).unwrap_or_default();
    let re = crate::regex!(r"github\.com[:/]([^/]+)/([^/]+)$");
    let Some(c) = re.captures(&url) else {
        ui::warn(format!(
            "the remote of {} is not on GitHub: crux treats it as {action}d, {action} it in your provider by hand",
            ctx.repo
        ));
        return;
    };
    let slug = format!("{}/{}", &c[1], c[2].strip_suffix(".git").unwrap_or(&c[2]));
    if !sh::exists("gh") {
        ui::warn(format!("without gh I cannot {action} {slug} on GitHub: do it by hand"));
    } else if sh::capture("gh", &["repo", action, &slug, "--yes"]).ok() {
        ui::ok(format!("{slug} {action}d on GitHub"));
    } else {
        ui::warn(format!("GitHub did not {action} {slug} — check permissions and do it by hand"));
    }
}

fn banner_start(lang: &str) -> &'static str {
    if lang == "es" {
        "> **Archivado el"
    } else {
        "> **Archived on"
    }
}

fn hooks_dir(repo_dir: &Path) -> Option<std::path::PathBuf> {
    git::out(repo_dir, &["rev-parse", "--path-format=absolute", "--git-path", "hooks"]).map(Into::into)
}

pub fn run(argv: &[String]) -> Res {
    let mut args = argv;
    let mut mode = "archive";
    if args.first().map(String::as_str) == Some("--undo") {
        mode = "unarchive";
        args = &args[1..];
    }
    let (mut repo, mut reason, mut remote) = (String::new(), String::new(), true);
    let mut p = Parser::new(args);
    while let Some(arg) = p.next() {
        match arg {
            "--reason" => reason = p.value(),
            "--no-remote" => remote = false,
            a if a.starts_with('-') => die!("unknown option: {a}"),
            a => repo = a.to_string(),
        }
    }
    if repo.is_empty() {
        die!("usage: crux {mode} <repo>{}", if mode == "archive" { " --reason \"<why>\"" } else { "" });
    }
    if !project::valid_name(&repo) {
        die!("not a valid repo name: {repo}");
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(docs) = project::find_docs_repo(&cwd) else {
        die!("run it from the project's docs repo, or one of its repos")
    };
    let docs_name = files::name(&docs);
    let root = docs.parent().unwrap().to_path_buf();
    let contract = match project::read_contract(&docs) {
        Ok(c) => c,
        Err(e) => die!("crux.json cannot be read: {e}"),
    };
    let lang = files::get_str(&contract, "language").unwrap_or_else(|| "en".into());
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let mut ctx = Ctx { repo: repo.clone(), remote, contract };
    let readme = docs.join("repos").join(&repo).join(names::README);
    let repo_dir = root.join(&repo);

    if mode == "archive" {
        if reason.is_empty() {
            die!("say why: --reason \"<why>\" (it is what stops someone from bringing it back blindly)");
        }
        let c = ctx.contract.as_object_mut().unwrap();
        let active = files::str_list(c.get("repos")).contains(&repo);
        if !active {
            eprintln!("{repo} is not an active repo of the project");
            die!("{repo} is not an active repo of {docs_name}");
        }
        if let Some(Value::Array(a)) = c.get_mut("repos") {
            a.retain(|r| r.as_str() != Some(&repo));
        }
        let archived = c.entry("archived").or_insert_with(|| json!({}));
        if !archived.is_object() {
            *archived = json!({});
        }
        archived.as_object_mut().unwrap().insert(repo.clone(), json!({"since": today, "reason": reason}));
        if let Err(e) = project::write_contract(&docs, &ctx.contract) {
            die!("cannot write crux.json: {e}");
        }
        ui::ok(format!("{repo} archived in crux.json (since {today})"));

        if let Some(text) = crate::files::read_optional(&readme) {
            if !text.contains(banner_start(&lang)) {
                let line = if lang == "es" {
                    format!("> **Archivado el {today}.** {reason} — `crux unarchive {repo}` lo devuelve.")
                } else {
                    format!("> **Archived on {today}.** {reason} — `crux unarchive {repo}` brings it back.")
                };
                let mut out = vec![];
                for (n, l) in text.lines().enumerate() {
                    out.push(l.to_string());
                    if n == 0 && l.starts_with("# ") {
                        out.push(String::new());
                        out.push(line.clone());
                    }
                }
                if let Err(e) = crate::files::write(&readme, &(out.join("\n") + "\n")) {
                    die!("{e}");
                }
                ui::ok(format!("notice at the top of repos/{repo}/README.md"));
            }
        }

        // The local clone stops pushing: a merge or a push there is exactly
        // what brought the retired service back.
        if repo_dir.join(".git").is_dir() {
            if let Some(hooks) = hooks_dir(&repo_dir) {
                let _ = fs::create_dir_all(&hooks);
                let block = format!("#!/usr/bin/env bash\n# Installed by crux archive.\necho\necho \"{repo} is archived since {today}: push blocked\"\necho \"  if it is coming back to life: crux unarchive {repo}, from its docs repo\"\nexit 1\n");
                if let Err(e) = super::hooks::put_hook(&hooks, "pre-push", &block) {
                    die!("{e}");
                }
                ui::ok("the local clone refuses to push");
            }
        }
        provider(&ctx, "archive");
        ui::info(format!("suggested commit in {docs_name}: chore(repos): archive {repo}"));
        return Ok(());
    }

    let c = ctx.contract.as_object_mut().unwrap();
    let is_archived = c.get("archived").and_then(|a| a.get(&repo)).is_some_and(|v| !v.is_null() && v != &json!(false));
    if !is_archived {
        die!("{repo} is not archived in {docs_name}");
    }
    let archived = c.get_mut("archived").unwrap().as_object_mut().unwrap();
    archived.shift_remove(&repo);
    if archived.is_empty() {
        c.shift_remove("archived");
    }
    let repos = c.entry("repos").or_insert_with(|| json!([]));
    if let Some(a) = repos.as_array_mut() {
        a.push(json!(repo));
    }
    if let Err(e) = project::write_contract(&docs, &ctx.contract) {
        die!("cannot write crux.json: {e}");
    }
    ui::ok(format!("{repo} is an active repo again in crux.json"));

    if let Some(text) = crate::files::read_optional(&readme) {
        let start = banner_start(&lang);
        if text.contains(start) {
            let mut out = vec![];
            let mut skip = false;
            for l in text.lines() {
                if l.starts_with(start) {
                    skip = true;
                    continue;
                }
                if skip && l.is_empty() {
                    skip = false;
                    continue;
                }
                skip = false;
                out.push(l);
            }
            if let Err(e) = crate::files::write(&readme, &(out.join("\n") + "\n")) {
                die!("{e}");
            }
            ui::ok(format!("notice removed from repos/{repo}/README.md"));
        }
    }
    if repo_dir.join(".git").is_dir() {
        if let Some(hooks) = hooks_dir(&repo_dir) {
            let archived = |f: &Path| crate::files::read_or_empty(f).contains("Installed by crux archive");
            if archived(&hooks.join("pre-push")) || archived(&hooks.join("pre-push.crux")) {
                super::hooks::take_hook(&hooks, "pre-push");
            }
        }
        ui::info("its usual hooks come back with 'crux hooks install' from the docs repo");
    }
    provider(&ctx, "unarchive");
    ui::info(format!("suggested commit in {docs_name}: chore(repos): unarchive {repo}"));
    Ok(())
}
