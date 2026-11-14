//! crux visual — the visual review a person approves, with a receipt.
//!
//! `approve` is run after whoever decides has seen the comparisons and said
//! yes. The receipt stores the commit they were captured on: if another one
//! lands afterwards, the images no longer show what is proposed.
//!
//! The images are not committed to the proposal's branch: they would end up on
//! the main branch. They go to a separate branch that is never merged, written
//! with plumbing so as not to touch the working tree.

use crate::args::Parser;
use crate::error::{exit, Exit, Res};
use crate::names;
use crate::task::template;
use crate::{die, files, git, policy, project, sh, ui};
use std::path::{Path, PathBuf};

const START: &str = "<!-- visual-review:start -->";
const END: &str = "<!-- visual-review:end -->";

struct Ctx {
    repo: PathBuf,
    receipt: PathBuf,
}

impl Ctx {
    fn value(&self, k: &str) -> String {
        files::read_or_empty(&self.receipt)
            .lines()
            .find_map(|l| l.strip_prefix(&format!("{k} ")).map(String::from))
            .unwrap_or_default()
    }
    fn profile(&self) -> (String, Option<PathBuf>) {
        let docs = project::find_docs_repo(&self.repo);
        let profile = docs.as_deref().and_then(|d| project::contract_field(d, "profile")).unwrap_or_default();
        (profile, docs)
    }
    fn setting(&self, key: &str, default: &str) -> String {
        let (p, d) = self.profile();
        policy::get(&p, d.as_deref(), key).unwrap_or_else(|| default.into())
    }
    fn read_receipt(&self) -> Res {
        if !self.receipt.is_file() {
            die!("no visual review approved: 'crux visual approve <folder>' after the yes");
        }
        let dir = self.value("dir");
        if dir.is_empty() || !Path::new(&dir).is_dir() {
            die!("the receipt folder does not exist: {}", if dir.is_empty() { "empty" } else { &dir });
        }
        Ok(())
    }
    fn head(&self) -> String {
        git::head_sha(&self.repo).unwrap_or_default()
    }
}

fn images_of(dir: &Path) -> Vec<PathBuf> {
    let re = crate::regex!(r"(?i)\.(png|webp|jpe?g)$");
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|e| e.flatten().map(|x| x.path()).filter(|p| p.is_file() && re.is_match(&p.to_string_lossy())).collect())
        .unwrap_or_default();
    v.sort();
    v
}

fn short(sha: &str) -> String {
    sha.chars().take(8).collect()
}

fn approve(ctx: &Ctx, argv: &[String]) -> Res {
    let (mut dir, mut note) = (String::new(), String::new());
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--note" => note = p.value(),
            other => dir = other.to_string(),
        }
    }
    if dir.is_empty() {
        die!("usage: crux visual approve <folder> [--note \"<text>\"]");
    }
    let Some(dir) = project::resolve_dir(Path::new(&dir)) else { die!("folder does not exist: {dir}") };
    let total = images_of(&dir).len();
    if total == 0 {
        die!("no images in {} (png, webp or jpg)", dir.display());
    }
    let mut text = format!(
        "# visual review approved — crux\nsha {}\nbranch {}\ndir {}\napproved {}\n",
        ctx.head(),
        git::out(&ctx.repo, &["branch", "--show-current"]).unwrap_or_default(),
        dir.display(),
        chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
    );
    if !note.is_empty() {
        text.push_str(&format!("note {note}\n"));
    }
    if let Err(e) = std::fs::write(&ctx.receipt, text) {
        die!("cannot write the receipt: {e}");
    }
    ui::ok(format!(
        "visual review recorded on {} with {}",
        git::out(&ctx.repo, &["rev-parse", "--short", "HEAD"]).unwrap_or_default(),
        ui::count(total, "image", "images")
    ));
    Ok(())
}

fn show(ctx: &Ctx) -> Res {
    ctx.read_receipt()?;
    let (sha, head) = (ctx.value("sha"), ctx.head());
    ui::info(format!("approved on {} on {}", ctx.value("approved"), short(&sha)));
    ui::info(format!("{} images in {}", images_of(Path::new(&ctx.value("dir"))).len(), ctx.value("dir")));
    if sha != head {
        ui::warn(format!("the captures are from {} and HEAD is {}: show them again", short(&sha), short(&head)));
        return exit(1);
    }
    Ok(())
}

fn repo_github(repo: &Path) -> Option<String> {
    let url = git::out(repo, &["config", "--get", "remote.origin.url"])?;
    let c = crate::regex!(r"github\.com[:/]([^/]+)/([^/]+)$").captures(&url)?;
    Some(format!("{}/{}", &c[1], c[2].strip_suffix(".git").unwrap_or(&c[2])))
}

/// Writes the images to the review branch without a checkout: temporary
/// index, tree and commit by hand.
fn publish_review(repo: &Path, branch: &str, prefix: &str, dir: &Path) -> bool {
    let parent = if git::ok(repo, &["fetch", "-q", crate::names::git::REMOTE, branch]) {
        git::out(repo, &["rev-parse", "FETCH_HEAD"])
    } else {
        None
    };
    let index = std::env::temp_dir().join(format!("crux-visual-index.{}", std::process::id()));
    let _ = std::fs::remove_file(&index);
    let with_index = |args: &[&str]| sh::capture_cmd(git::cmd(repo).args(args).env("GIT_INDEX_FILE", &index));
    let result = (|| {
        if let Some(p) = &parent {
            if !with_index(&["read-tree", p]).ok() {
                return false;
            }
        }
        with_index(&["rm", "-rq", "--cached", "--ignore-unmatch", prefix]);
        for file in images_of(dir) {
            let Some(blob) = git::out(repo, &["hash-object", "-w", &file.to_string_lossy()]) else { return false };
            let name = files::name(&file);
            if !with_index(&["update-index", "--add", "--cacheinfo", &format!("100644,{blob},{prefix}/{name}")]).ok() {
                return false;
            }
        }
        let tree = with_index(&["write-tree"]).out();
        let msg = format!("chore(review): before and after for {prefix}");
        let mut args = vec!["commit-tree", tree.as_str()];
        if let Some(p) = &parent {
            args.push("-p");
            args.push(p);
        }
        args.push("-m");
        args.push(&msg);
        let Some(commit) = git::out(repo, &args) else { return false };
        git::ok(repo, &["push", "-q", crate::names::git::REMOTE, &format!("{commit}:refs/heads/{branch}")])
    })();
    let _ = std::fs::remove_file(&index);
    result
}

fn section(ctx: &Ctx, argv: &[String]) -> Result<String, Exit> {
    let mut publish = false;
    let mut p = Parser::new(argv);
    while let Some(arg) = p.next() {
        match arg {
            "--publish" => publish = true,
            "--lang" => {
                p.value_opt();
            }
            other => {
                ui::err(format!("unknown option: {other}"));
                return Err(Exit(1));
            }
        }
    }
    ctx.read_receipt()?;
    let (sha, head) = (ctx.value("sha"), ctx.head());
    if sha != head {
        ui::err(format!("the captures are from {} and HEAD is {}: show them again", short(&sha), short(&head)));
        return Err(Exit(1));
    }
    let dir = ctx.value("dir");
    let note = ctx.value("note");
    let summary = if note.is_empty() { template::SCREENSHOTS_REVIEWED.to_string() } else { note };
    let mut out = format!("{START}\n## {}\n\n{summary}\n", template::SCREENSHOTS);
    if ctx.setting("visual.publish", "branch") == "branch" && publish {
        let Some(slug) = repo_github(&ctx.repo) else {
            ui::err("the remote is not on GitHub: I do not know where to link the images");
            return Err(Exit(1));
        };
        let branch = ctx.setting("visual.branch", "crux-review");
        let prefix = {
            let b = ctx.value("branch");
            if b.is_empty() {
                short(&sha)
            } else {
                b
            }
        };
        if !publish_review(&ctx.repo, &branch, &prefix, Path::new(&dir)) {
            ui::err(format!("could not push the images to the {branch} branch"));
            return Err(Exit(1));
        }
        out.push_str(&format!("\n{}\n", template::SCREENSHOTS_CAPTION));
        for f in images_of(Path::new(&dir)) {
            let name = files::name(&f);
            let stem = name.rsplit_once('.').map(|(a, _)| a).unwrap_or(&name);
            out.push_str(&format!("\n![{stem}](https://github.com/{slug}/blob/{branch}/{prefix}/{name}?raw=true)\n"));
        }
    }
    out.push_str(&format!("{END}\n"));
    Ok(out)
}

/// Replaces the section if it is already between the markers. Otherwise it
/// goes before the first second-level heading, after the opening context and
/// ahead of the implementation details, where a reviewer looks first; with no
/// heading to anchor to, at the end, rather than splitting the prose.
pub fn replace_section(body: &str, section: &str) -> String {
    match (body.find(START), body.find(END)) {
        (Some(a), Some(b)) if b > a => format!("{}{}{}", &body[..a], section.trim(), &body[b + END.len()..]),
        _ => match first_heading(body) {
            Some(at) if at > 0 => {
                format!("{}\n\n{}\n\n{}", body[..at].trim_end(), section.trim(), &body[at..])
            }
            _ => format!("{}\n\n{}\n", body.trim_end(), section.trim()),
        },
    }
}

fn first_heading(body: &str) -> Option<usize> {
    let mut offset = 0;
    let mut fenced = false;
    for line in body.split_inclusive('\n') {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
        } else if !fenced && line.starts_with("## ") {
            return Some(offset);
        }
        offset += line.len();
    }
    None
}

fn pull_api_path(url: &str) -> Option<(String, String)> {
    let url = url.trim().trim_end_matches('/');
    let rest = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://"))?;
    match rest.split('/').collect::<Vec<_>>().as_slice() {
        [host, owner, repo, "pull", n] if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => {
            Some((host.to_string(), format!("repos/{owner}/{repo}/pulls/{n}")))
        }
        _ => None,
    }
}

fn pr(ctx: &Ctx, argv: &[String]) -> Res {
    let Some(pr) = argv.first().filter(|p| !p.is_empty()) else { die!("usage: crux visual pr <number|url>") };
    if !sh::exists("gh") {
        die!("gh is needed to edit the proposal");
    }
    let new_section = section(ctx, &["--publish".into()])?;
    let body = sh::capture_in(&ctx.repo, "gh", &["pr", "view", pr, "--json", "body", "-q", ".body"]);
    if !body.ok() {
        die!("could not read proposal {pr}");
    }
    let url = sh::capture_in(&ctx.repo, "gh", &["pr", "view", pr, "--json", "url", "-q", ".url"]);
    let Some((host, path)) = url.ok().then(|| pull_api_path(&url.out())).flatten() else {
        die!("could not find the address of proposal {pr}: {}", url.stderr.trim());
    };
    let new_body = replace_section(&body.out(), &new_section);
    let tmp = std::env::temp_dir().join(format!("crux-visual-body.{}", std::process::id()));
    if let Err(e) = crate::files::write(&tmp, &format!("{new_body}\n")) {
        die!("{e}");
    }
    let done = (|| {
        if !super::call_quiet(&ctx.repo, "ship", &["body", &tmp.to_string_lossy()]).ok() {
            ui::err("the new body does not pass the proposal filter");
            return false;
        }
        let field = format!("body=@{}", tmp.to_string_lossy());
        let edit = sh::capture_in(&ctx.repo, "gh", &["api", "--hostname", &host, "-X", "PATCH", &path, "-F", &field]);
        if !edit.ok() {
            ui::err(format!("could not edit proposal {pr}: {}", edit.stderr.trim()));
            return false;
        }
        true
    })();
    let _ = std::fs::remove_file(&tmp);
    if !done {
        return exit(1);
    }
    ui::ok(format!("visual review put in proposal {pr}"));
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let cwd = std::env::current_dir().unwrap_or_default();
    let Some(repo) = git::toplevel(&cwd) else { die!("this is not a git repository") };
    let ctx = Ctx { receipt: repo.join(names::VISUAL_RECEIPT), repo };
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    match argv.first().map(String::as_str).unwrap_or("") {
        "approve" => approve(&ctx, rest),
        "show" => show(&ctx),
        "section" => {
            print!("{}", section(&ctx, rest)?);
            Ok(())
        }
        "pr" => pr(&ctx, rest),
        "clear" => {
            let _ = std::fs::remove_file(&ctx.receipt);
            ui::ok("visual review discarded");
            Ok(())
        }
        _ => {
            for l in crate::help::text("visual").unwrap_or_default().lines().take(7) {
                println!("{l}");
            }
            exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pull_url_becomes_its_rest_path() {
        assert_eq!(
            pull_api_path("https://github.com/acme/web/pull/12\n"),
            Some(("github.com".into(), "repos/acme/web/pulls/12".into()))
        );
        assert_eq!(
            pull_api_path("https://git.example.org/team/app/pull/3/"),
            Some(("git.example.org".into(), "repos/team/app/pulls/3".into()))
        );
        assert_eq!(pull_api_path("https://github.com/acme/web/issues/12"), None);
        assert_eq!(pull_api_path("https://github.com/acme/web/pull/x"), None);
        assert_eq!(pull_api_path(""), None);
    }

    const SECTION: &str = "<!-- visual-review:start -->\n## Shots\n<!-- visual-review:end -->";

    #[test]
    fn the_review_goes_before_the_first_heading() {
        let body = "Fixes the curtain.\n\n## Changes\n- a\n";
        let out = replace_section(body, SECTION);
        assert!(out.starts_with("Fixes the curtain.\n\n<!-- visual-review:start -->"));
        assert!(out.find("## Shots").unwrap() < out.find("## Changes").unwrap());
    }

    #[test]
    fn with_no_heading_it_goes_at_the_end() {
        let out = replace_section("Only prose.", SECTION);
        assert!(out.starts_with("Only prose.\n\n<!-- visual-review:start -->"));
    }

    #[test]
    fn a_heading_inside_a_code_block_is_not_an_anchor() {
        let body = "Intro.\n\n```\n## not a heading\n```\n\n## Testing\n";
        let out = replace_section(body, SECTION);
        assert!(out.find("<!-- visual-review:start -->").unwrap() > out.find("not a heading").unwrap());
        assert!(out.find("<!-- visual-review:start -->").unwrap() < out.find("## Testing").unwrap());
    }

    #[test]
    fn an_existing_review_is_replaced_in_place() {
        let body = "Intro.\n\n<!-- visual-review:start -->\nold\n<!-- visual-review:end -->\n\n## Changes\n";
        let out = replace_section(body, SECTION);
        assert!(!out.contains("old"));
        assert_eq!(out.matches("<!-- visual-review:start -->").count(), 1);
        assert!(out.find("## Shots").unwrap() < out.find("## Changes").unwrap());
    }

    #[test]
    fn a_body_that_opens_with_a_heading_keeps_it_first() {
        let out = replace_section("## Summary\ntext\n", SECTION);
        assert!(out.starts_with("## Summary"));
    }
}
