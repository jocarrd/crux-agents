//! crux init — creates the docs repo of a new project from the templates.
//!
//!   crux init <project> [--description "..."] [--repos a,b,c] [--branch <branch>]
//!                       [--profile multi-repo] [--visibility private]
//!                       [--language es] [--remote <template>] [--no-remote]
//!
//! The remote is not assumed: it is declared. `--remote` accepts a template
//! with {repo} —valid for any provider— and it is written into the contract,
//! where `crux clone` and `crux doctor` read it later.
//!
//! Deterministic: the result comes from templates/, not from an agent
//! reproducing files by hand. Two runs give the same tree.

use crate::args::Parser;
use crate::error::{exit, Res};
use crate::names;
use crate::{die, env, git, policy, project, sh, template, ui};
use std::path::PathBuf;
use std::process::Command;

pub fn run(argv: &[String]) -> Res {
    let Some(project_name) = argv.first().filter(|p| !p.is_empty()).cloned() else {
        die!("usage: crux init <project> [options]")
    };
    let mut description = format!("Cross-cutting documentation for {project_name}.");
    let (mut repos_arg, mut branch, mut profile, mut visibility, mut language) =
        (String::new(), "main".to_string(), "multi-repo".to_string(), "private".to_string(), "es".to_string());
    let (mut remote_tmpl, mut remote) = (String::new(), true);
    let mut parent = env::projects_root();
    let mut p = Parser::new(&argv[1..]);
    while let Some(arg) = p.next() {
        match arg {
            "--description" => description = p.value(),
            "--repos" => repos_arg = p.value(),
            "--branch" => branch = p.value(),
            "--profile" => profile = p.value(),
            "--visibility" => visibility = p.value(),
            "--language" => language = p.value(),
            "--remote" => remote_tmpl = p.value(),
            "--parent" => parent = PathBuf::from(p.value()),
            "--no-remote" => remote = false,
            other => die!("unknown option: {other}"),
        }
    }
    if !policy::exists(&profile, None) {
        die!("unknown profile: {profile}");
    }
    if !crate::regex!(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$").is_match(&project_name) {
        die!("the name must be lowercase kebab-case: {project_name}");
    }
    let root = parent.join(&project_name);
    let docs = root.join(format!("{project_name}-docs"));
    if docs.exists() {
        die!("{} already exists", docs.display());
    }
    // Where the remote comes from, in order: what is passed, the machine's
    // default, and with none it says so instead of guessing.
    if remote_tmpl.is_empty() {
        remote_tmpl = env::config_value_in(&env::config_file(), "CRUX_REMOTE").unwrap_or_default();
    }
    if remote && remote_tmpl.is_empty() {
        ui::err(format!("I do not know where to push {project_name}-docs"));
        ui::info("say it with --remote 'git@your-remote:org/{repo}.git'");
        ui::info("or set the usual one in ~/.crux/config:  CRUX_REMOTE=\"git@github.com:your-user/{repo}.git\"");
        ui::info("or create the project locally only with --no-remote");
        return exit(1);
    }
    let url_docs = remote_tmpl.replace("{repo}", &format!("{project_name}-docs"));
    // Creating the remote repo does depend on the provider. GitHub is covered
    // because there is an official CLI; for the rest the repo is left ready
    // and it says what to do.
    let create_remote =
        remote && url_docs.contains("github.com") && sh::exists("gh") && sh::capture("gh", &["auth", "status"]).ok();
    println!("creating {project_name}-docs · profile {profile}");
    if remote {
        println!("remote: {url_docs}");
    }
    println!();

    let _ = std::fs::create_dir_all(&root);
    let mut pending_create = false;
    if create_remote {
        // The owner comes from the template: otherwise gh creates under the
        // authenticated account even if the contract declares an organization.
        let owner = project::owner_from_template(&url_docs);
        let slug =
            if owner.is_empty() { format!("{project_name}-docs") } else { format!("{owner}/{project_name}-docs") };
        let code = sh::status(
            Command::new("gh")
                .args(["repo", "create", &slug, &format!("--{visibility}"), "--description", &description, "--clone"])
                .current_dir(&root)
                .stdout(std::process::Stdio::null()),
        );
        if code != 0 {
            ui::err(format!("gh could not create {slug} on the remote"));
            return exit(code);
        }
        ui::ok(format!(
            "repo created on the remote and cloned ({visibility}{})",
            if owner.is_empty() { String::new() } else { format!(" · {owner}") }
        ));
        // Normalized to the declared branch: hooks, worktrees and review read
        // it from the contract, and if they diverge the guard watches a branch
        // nobody uses.
        if let Some(created) = git::current_branch(&docs) {
            if created != branch {
                git::run(&docs, &["branch", "-M", &branch]);
                ui::ok(format!("branch normalized to {branch} (the remote created it as {created})"));
            }
        }
    } else {
        let _ = std::fs::create_dir_all(&docs);
        // Without this the repo is born on the machine's default branch, and
        // the hook protecting the main branch looks at another one.
        if !git::ok(&docs, &["init", "-q", "-b", &branch]) {
            git::run(&docs, &["init", "-q"]);
            git::run(&docs, &["symbolic-ref", "HEAD", &format!("refs/heads/{branch}")]);
        }
        if remote {
            git::run(&docs, &["remote", "add", "origin", &url_docs]);
            ui::ok(format!("local repo with origin pointing at {url_docs}"));
            pending_create = true;
        } else {
            ui::ok("local repo created (no remote)");
        }
    }

    let home = env::crux_home().unwrap_or_default();
    let templates = home.join("templates/docs-repo");
    for src in project::files_under(&templates) {
        let rel = src.strip_prefix(&templates).unwrap().to_string_lossy().into_owned();
        let dst = match rel.as_str() {
            "gitignore" => docs.join(".gitignore"),
            "gitattributes" => docs.join(".gitattributes"),
            _ => docs.join(&rel),
        };
        if let Err(e) = template::render_to(&src, &dst, &[("PROJECT", &project_name), ("DESCRIPTION", &description)]) {
            die!("cannot write {}: {e}", dst.display());
        }
    }
    let _ = std::fs::remove_file(docs.join(names::CLAUDE));
    let _ = std::os::unix::fs::symlink(names::AGENTS, docs.join(names::CLAUDE));
    let _ = std::fs::create_dir_all(docs.join(".claude/skills/project"));
    ui::ok("minimal structure materialized");

    let mut repos = vec![];
    for r in repos_arg.split(',') {
        let r: String = r.chars().filter(|c| !c.is_whitespace()).collect();
        if r.is_empty() {
            continue;
        }
        if !project::valid_name(&r) {
            die!("invalid repo name: {r}");
        }
        repos.push(r);
    }
    let index = docs.join("repos/README.md");
    let empty_row = crate::regex!(r"^\|\s*\|\s*\|\s*\|\s*$");
    for repo in &repos {
        let readme = docs.join("repos").join(repo).join(names::README);
        if let Err(e) = template::render_to(
            &home.join("templates/repo-doc/README.md"),
            &readme,
            &[("REPO", repo), ("PROJECT", &project_name), ("DESCRIPTION", "What this repo does, in one line.")],
        ) {
            die!("cannot write {}: {e}", readme.display());
        }
        // The index row: the description that ends up in each repo's pointer
        // comes from there, so an empty table leaves the pointers mute.
        if let Some(text) = crate::files::read_optional(&index) {
            let mut lines: Vec<String> = text.split('\n').map(String::from).collect();
            let row = format!("| `{repo}/` | `{project_name}/{repo}` | What this repo does, in one line |");
            if let Some(e) = lines.iter().position(|l| empty_row.is_match(l)) {
                lines[e] = row;
            } else if let Some(last) = lines.iter().rposition(|l| l.starts_with('|')) {
                lines.insert(last + 1, row);
            }
            if let Err(e) = crate::files::write(&index, &lines.join("\n")) {
                die!("{e}");
            }
        }
    }
    if !repos.is_empty() {
        ui::ok(format!("{} folders in repos/", repos.len()));
    }

    let list = repos.iter().map(|r| format!("\"{r}\"")).collect::<Vec<_>>().join(", ");
    let language = if language.is_empty() { "es".to_string() } else { language };
    let contract = format!(
        r#"{{
  "crux": "{version}",
  "project": "{project_name}",
  "profile": "{profile}",
  "language": "{language}",
  "branch": "{branch}",
  "repos": [{list}],
  "sections": [],
  "quality": {{
    "gate": [],
    "repos": {{}}
  }},
  "conventions": {{
    "checks": []
  }},
  "remote": {{
    "url": "{remote_tmpl}",
    "visibility": "{visibility}"
  }},
  "workspace": {{
    "portBase": 3000,
    "portsPerSlot": 10,
    "envFile": ".env.local",
    "repos": {{}}
  }}
}}
"#,
        version = env::crux_version()
    );
    if let Err(e) = std::fs::write(docs.join(names::CONTRACT), contract) {
        die!("cannot write crux.json: {e}");
    }
    ui::ok("crux.json written");

    // On a freshly set up machine there may be no identity configured, and
    // bootstrap should not fall over because of that.
    git::run(&docs, &["add", "-A"]);
    let name = env::var("GIT_AUTHOR_NAME")
        .or_else(|| git::out(&docs, &["config", "user.name"]).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| "crux".into());
    let email = env::var("GIT_AUTHOR_EMAIL")
        .or_else(|| git::out(&docs, &["config", "user.email"]).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| "crux@localhost".into());
    git::run(
        &docs,
        &[
            "-c",
            &format!("user.name={name}"),
            "-c",
            &format!("user.email={email}"),
            "commit",
            "-q",
            "-m",
            "init: scaffold the docs repo under the crux standard",
        ],
    );
    if remote {
        git::run(&docs, &["push", "-q", "-u", "origin", "HEAD"]);
    }
    ui::ok("initial commit");

    println!();
    super::call("link", &[&docs.to_string_lossy()]);
    println!();
    println!("done: {}", docs.display());
    println!();
    if pending_create {
        println!();
        ui::warn(format!("the remote repo does not exist yet: create it on your provider as **{visibility}**"));
        ui::info("crux cannot apply visibility outside GitHub: you choose it when creating it");
        ui::info(format!("cd {} && git push -u origin HEAD", docs.display()));
    }
    println!("Next steps:");
    println!("  1. Put the code repos in {}/ as siblings of the docs repo.", root.display());
    println!("  2. To register a new one: /add-repo-to-docs <repo>");
    println!("  3. To check at any time: crux doctor");
    Ok(())
}
