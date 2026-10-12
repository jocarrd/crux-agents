//! crux hooks — hooks the standard into the moments where it applies.
//!
//!   crux hooks status     what is installed and whether it points at something real
//!   crux hooks install    installs the agent's hooks and, where it applies, git's
//!   crux hooks remove     removes only the ones crux manages
//!
//! A standard you have to remember to check gets checked sometimes. These
//! hooks check it every time.
//!
//! The git hooks crux installs are shell scripts on purpose: they live inside
//! each repo and must work for whoever commits there, with or without crux on
//! their PATH.

use crate::agent_hooks::{Hook, Scope};
use crate::error::Res;
use crate::{die, env, files, git, policy, project, ui};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

const MARK: &str = "crux/adapters";
const CRUX_HOOKS: &str = "doc-sync|cycle-guard|memory-guard|task-context|worktree-guard|destructive-guard|proposal-guard|wait-guard|session-sync|session-idle|profile-reminder";
const GIT_HOOK_NAMES: [&str; 15] = [
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-commit",
    "pre-merge-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-rebase",
    "post-checkout",
    "post-merge",
    "pre-push",
    "post-rewrite",
    "pre-auto-gc",
    "push-to-checkout",
];

struct Paths {
    home: PathBuf,
    settings: PathBuf,
    codex_dir: PathBuf,
}

impl Paths {
    fn hook(&self, name: &str) -> PathBuf {
        self.home.join(format!("adapters/claude/hooks/{name}.sh"))
    }
    fn s(&self, name: &str) -> String {
        self.hook(name).to_string_lossy().into_owned()
    }
}

fn paths() -> Paths {
    let home = env::crux_home().unwrap_or_default();
    let settings =
        env::var("CLAUDE_SETTINGS").map(PathBuf::from).unwrap_or_else(|| env::home().join(".claude/settings.json"));
    let codex_dir = env::var("CODEX_HOME_DIR")
        .or_else(|| env::var("CODEX_HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| env::home().join(".codex"));
    Paths { home, settings, codex_dir }
}

/// Only the file names: the kernel path can contain a hook name, as in a
/// workspace called wait-guard, and then every hook matched.
fn names(cmd: &str) -> String {
    cmd.split_whitespace().map(|t| t.rsplit('/').next().unwrap_or(t)).collect::<Vec<_>>().join(" ")
}

/// In a worktree, .git is a file and the hooks live in the common directory.
fn dir_hooks(repo: &Path) -> Option<PathBuf> {
    let d = git::out(repo, &["rev-parse", "--git-common-dir"])?;
    let d = if Path::new(&d).is_absolute() { PathBuf::from(d) } else { repo.join(d) };
    let hooks = d.join("hooks");
    std::fs::create_dir_all(&hooks).ok()?;
    Some(hooks)
}

fn executable(p: &Path) {
    let _ = std::fs::set_permissions(p, std::os::unix::fs::PermissionsExt::from_mode(0o755));
}

/// In front of every git hook crux uses, so a repo can keep its own in
/// `<name>.local` without crux ever overwriting it.
const DISPATCHER: &str = r#"#!/usr/bin/env bash
# Installed by crux hooks install: crux's part first, then the repo's own.
# The repo's own hook goes in <name>.local next to this file; crux never writes it.
here="$(cd "$(dirname "$0")" && pwd)"
name="$(basename "$0")"
# Only these get input from git: read in any other, a hook run by hand waits.
input=/dev/null
case "$name" in
  pre-push|pre-receive|post-receive|post-rewrite|reference-transaction)
    input="$(mktemp)"; trap 'rm -f "$input"' EXIT; cat > "$input" ;;
esac
for part in "$here/$name.crux" "$here/$name.local"; do
  [[ -x "$part" ]] || continue
  "$part" "$@" < "$input" || exit $?
done
exit 0
"#;
const DISPATCHER_MARK: &str = "crux's part first, then the repo's own";

/// A hook some version of crux wrote: replacing it loses nothing.
fn is_crux_hook(text: &str) -> bool {
    ["crux hooks install", "crux archive", DISPATCHER_MARK].iter().any(|m| text.contains(m))
}

fn crux_hook_at(f: &Path) -> bool {
    std::fs::read(f).is_ok_and(|t| is_crux_hook(&String::from_utf8_lossy(&t)))
}

/// A hook that was there and is not crux's moves to `<name>.local` instead of
/// being overwritten.
pub fn put_hook(hooks: &Path, name: &str, body: &str) -> Result<(), String> {
    let main = hooks.join(name);
    let local = hooks.join(format!("{name}.local"));
    if main.exists() {
        let text = std::fs::read(&main).map_err(|e| format!("cannot read {}: {e}", main.display()))?;
        if !is_crux_hook(&String::from_utf8_lossy(&text)) {
            if local.exists() {
                return Err(format!(
                    "{} and {name}.local both exist and neither is crux's: left as they are",
                    main.display()
                ));
            }
            std::fs::rename(&main, &local).map_err(|e| format!("cannot move {}: {e}", main.display()))?;
            ui::info(format!("{name}: the repo's own hook is now {name}.local and runs after crux's"));
        }
    }
    let part = hooks.join(format!("{name}.crux"));
    files::write(&part, body)?;
    executable(&part);
    files::write(&main, DISPATCHER)?;
    executable(&main);
    Ok(())
}

pub fn take_hook(hooks: &Path, name: &str) -> bool {
    let main = hooks.join(name);
    let part = hooks.join(format!("{name}.crux"));
    let local = hooks.join(format!("{name}.local"));
    let ours = crux_hook_at(&main);
    let had = part.exists() || ours;
    let _ = std::fs::remove_file(&part);
    if ours {
        let _ = std::fs::remove_file(&main);
    }
    if local.exists() && !main.exists() {
        let _ = std::fs::rename(&local, &main);
    }
    had
}

pub fn needs_new_hooks(repo: &Path) -> bool {
    let Some(hooks) = dir_hooks(repo) else { return false };
    let main = hooks.join("commit-msg");
    crux_hook_at(&main) && !files::read_or_empty(&main).contains(DISPATCHER_MARK)
}

fn read_settings(p: &Path) -> Value {
    files::read_json(p).unwrap_or_else(|_| json!({}))
}

fn write_settings(p: &Path, v: &Value) -> Result<(), String> {
    files::write(p, &files::json_pretty(v))
}

/// A repo with core.hooksPath —its own versioned hooks, as many clients
/// have— makes git ignore .git/hooks, and with it every hook crux installs.
/// crux keeps writing its hooks where it always did and points core.hooksPath
/// at wrappers that run crux's hook first and then the repo's own. Local
/// config: nothing of the client's repo changes.
fn chain_hooks_path(repo: &Path) {
    let Some(common) = git::common_dir(repo) else { return };
    let chain = common.join("crux-hooks");
    let Some(own) = git::out(repo, &["config", "--get", "core.hooksPath"]).filter(|o| !o.is_empty()) else { return };
    if Path::new(&own) != chain {
        git::run(repo, &["config", "crux.originalHooksPath", &own]);
        git::run(repo, &["config", "core.hooksPath", &chain.to_string_lossy()]);
    }
    let _ = std::fs::create_dir_all(&chain);
    let wrapper = r#"#!/usr/bin/env bash
# Installed by crux hooks install: crux's hook, then the repo's own.
name="$(basename "$0")"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
original="$(git config --get crux.originalHooksPath || true)"
[[ -z "$original" || "$original" = /* ]] || original="$(git rev-parse --show-toplevel)/$original"
# Only these get input from git: read in any other, a hook run by hand waits.
input=/dev/null
case "$name" in
  pre-push|pre-receive|post-receive|post-rewrite|reference-transaction)
    input="$(mktemp)"; trap 'rm -f "$input"' EXIT; cat > "$input" ;;
esac
if [[ -x "$common/hooks/$name" ]]; then
  "$common/hooks/$name" "$@" < "$input" || exit $?
fi
if [[ -n "$original" && -x "$original/$name" ]]; then
  "$original/$name" "$@" < "$input" || exit $?
fi
exit 0
"#;
    for name in GIT_HOOK_NAMES {
        let f = chain.join(name);
        if let Err(e) = files::write(&f, wrapper) {
            ui::warn(format!("{e} — {} runs neither crux's hooks nor its own", files::name(repo)));
            return;
        }
        executable(&f);
    }
    ui::info(format!("{} has its own hooks ({own}): crux runs its hooks first, then those", files::name(repo)));
}

fn unchain_hooks_path(repo: &Path) {
    let Some(common) = git::common_dir(repo) else { return };
    let chain = common.join("crux-hooks");
    if git::out(repo, &["config", "--get", "core.hooksPath"]).as_deref() != Some(&chain.to_string_lossy()) {
        return;
    }
    let original = git::out(repo, &["config", "--get", "crux.originalHooksPath"]).unwrap_or_default();
    if original.is_empty() {
        git::run(repo, &["config", "--unset", "core.hooksPath"]);
    } else {
        git::run(repo, &["config", "core.hooksPath", &original]);
    }
    git::run(repo, &["config", "--unset", "crux.originalHooksPath"]);
    let _ = std::fs::remove_dir_all(&chain);
    ui::ok(format!(
        "{}: core.hooksPath back to {}",
        files::name(repo),
        if original.is_empty() { "the default" } else { &original }
    ));
}

fn status(p: &Paths) -> Res {
    println!("agent hooks — {}", p.settings.display());
    if !p.settings.is_file() {
        ui::warn("does not exist yet");
    } else {
        let s = match files::read_json(&p.settings) {
            Ok(v) => v,
            Err(e) => die!("{} cannot be read: {e}", p.settings.display()),
        };
        let home = env::home().to_string_lossy().into_owned();
        let mut n = 0;
        for (event, groups) in s.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default() {
            for g in groups.as_array().cloned().unwrap_or_default() {
                for h in g.get("hooks").and_then(Value::as_array).cloned().unwrap_or_default() {
                    n += 1;
                    let cmd = h.get("command").and_then(Value::as_str).unwrap_or("").to_string();
                    let path = cmd.strip_prefix('~').map(|r| format!("{home}{r}")).unwrap_or_else(|| cmd.clone());
                    let first = path.split(' ').next().unwrap_or("");
                    let exists = Path::new(first).exists();
                    let own = if cmd.contains(MARK) { "[crux] " } else { "" };
                    println!("      {}  {event:<12} {own}{cmd}", if exists { "ok " } else { "BROKEN" });
                }
            }
        }
        if n == 0 {
            println!("      none configured");
        }
    }
    println!();
    if let Some(docs) = project::find_docs_repo(&std::env::current_dir().unwrap_or_default()) {
        println!("git hooks — {}", files::name(&docs));
        let hooks = dir_hooks(&docs).unwrap_or_default();
        let has = |name: &str, needles: &[&str]| {
            [hooks.join(format!("{name}.crux")), hooks.join(name)].iter().any(|f| {
                let text = files::read_or_empty(f);
                needles.iter().any(|n| text.contains(n))
            })
        };
        if has("pre-commit", &[MARK, "crux doctor"]) {
            ui::ok("pre-commit installed")
        } else {
            ui::info("no crux pre-commit")
        }
        if has("pre-push", &["crux workspace"]) {
            ui::ok("pre-push installed — no direct push to the main branch")
        } else {
            ui::info("no crux pre-push")
        }
        if hooks.join("commit-msg").is_file() {
            ui::ok("commit-msg installed — messages in English")
        } else {
            ui::info("no crux commit-msg")
        }
    }
    Ok(())
}

/// Replaces the entries that point at an earlier version of the same hook and
/// leaves the rest untouched: the file is the user's, not ours.
fn hook_up(settings: &mut Value, event: &str, cmd: &str, previous: &str, matcher: &str) {
    let re = regex::Regex::new(previous).unwrap();
    let obj = settings.as_object_mut().unwrap();
    let hooks = obj.entry("hooks").or_insert_with(|| json!({}));
    let groups = hooks.as_object_mut().unwrap().entry(event).or_insert_with(|| json!([]));
    let mut replaced = 0;
    for g in groups.as_array_mut().unwrap() {
        if let Some(list) = g.get_mut("hooks").and_then(Value::as_array_mut) {
            for h in list {
                if re.is_match(&names(h.get("command").and_then(Value::as_str).unwrap_or(""))) {
                    replaced += 1;
                    h.as_object_mut().unwrap().insert("command".into(), json!(cmd));
                }
            }
        }
    }
    if replaced == 0 {
        groups
            .as_array_mut()
            .unwrap()
            .push(json!({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]}));
        println!("      new entry");
    } else {
        println!("      replaced {replaced} previous entries");
    }
}

/// The Claude Code plugin carries the mod that draws the task reminder as a
/// panel. It is loaded through CLAUDE_CODE_PLUGIN_DIRS in Claude's settings,
/// which no other agent reads.
fn plugin_claude(settings: &mut Value, add: bool, dir: &Path) {
    let obj = settings.as_object_mut().unwrap();
    let env_v = obj.entry("env").or_insert_with(|| json!({}));
    let e = env_v.as_object_mut().unwrap();
    let re = crate::regex!(r"/adapters/claude/plugin/?$");
    let mut others: Vec<String> = e
        .get("CLAUDE_CODE_PLUGIN_DIRS")
        .and_then(Value::as_str)
        .unwrap_or("")
        .split(':')
        .filter(|d| !d.is_empty() && !re.is_match(d))
        .map(String::from)
        .collect();
    if add {
        others.push(dir.to_string_lossy().into_owned());
    }
    if others.is_empty() {
        e.shift_remove("CLAUDE_CODE_PLUGIN_DIRS");
    } else {
        e.insert("CLAUDE_CODE_PLUGIN_DIRS".into(), json!(others.join(":")));
    }
    if e.is_empty() {
        obj.shift_remove("env");
    }
}

fn strip_crux(s: &mut Value, pattern: &str) {
    let re = regex::Regex::new(pattern).unwrap();
    let Some(hooks) = s.get_mut("hooks").and_then(Value::as_object_mut) else { return };
    let events: Vec<String> = hooks.keys().cloned().collect();
    for ev in events {
        let groups = hooks.get(&ev).and_then(Value::as_array).cloned().unwrap_or_default();
        let kept: Vec<Value> = groups
            .into_iter()
            .map(|mut g| {
                let list: Vec<Value> = g
                    .get("hooks")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|h| !re.is_match(&names(h.get("command").and_then(Value::as_str).unwrap_or(""))))
                    .collect();
                g.as_object_mut().map(|o| o.insert("hooks".into(), Value::Array(list)));
                g
            })
            .filter(|g| g.get("hooks").and_then(Value::as_array).is_some_and(|l| !l.is_empty()))
            .collect();
        if kept.is_empty() {
            hooks.shift_remove(&ev);
        } else {
            hooks.insert(ev, Value::Array(kept));
        }
    }
}

/// Codex reads its hooks from ~/.codex/hooks.json in Claude's format, so the
/// same scripts are registered. It has no file tools of its own, the hooks
/// that give context go through contexto.sh, and the memory guard is left out
/// because it reviews Claude's memories.
fn codex_hooks(p: &Paths, add: bool) -> Result<(), String> {
    let file = p.codex_dir.join("hooks.json");
    let mut s = if file.exists() { read_settings(&file) } else { json!({}) };
    if !s.get("hooks").is_some_and(Value::is_object) {
        s.as_object_mut().unwrap().insert("hooks".into(), json!({}));
    }
    strip_crux(&mut s, &format!("{CRUX_HOOKS}|contexto\\.sh"));
    if add {
        let q = |x: String| serde_json::to_string(&x).unwrap();
        let ctx = p.home.join("adapters/codex/hooks/contexto.sh").to_string_lossy().into_owned();
        let hooks = s.get_mut("hooks").unwrap().as_object_mut().unwrap();
        let mut put = |ev: &str, matcher: &str, commands: Vec<String>| {
            let mut g = Map::new();
            if !matcher.is_empty() {
                g.insert("matcher".into(), json!(matcher));
            }
            g.insert(
                "hooks".into(),
                Value::Array(commands.into_iter().map(|c| json!({"type": "command", "command": c})).collect()),
            );
            hooks.entry(ev).or_insert_with(|| json!([])).as_array_mut().unwrap().push(Value::Object(g));
        };
        put("SessionStart", "startup|resume|clear", vec![p.s(Hook::SessionSync.name())]);
        put(
            "UserPromptSubmit",
            "",
            vec![
                format!("{} UserPromptSubmit {}", q(ctx.clone()), q(p.s(Hook::CycleGuard.name()))),
                format!("{} UserPromptSubmit {}", q(ctx.clone()), q(p.s("task-context"))),
                format!("{} UserPromptSubmit {}", q(ctx.clone()), q(p.s("profile-reminder"))),
                p.s("session-idle"),
            ],
        );
        put("PreToolUse", "Bash", vec![p.s("destructive-guard"), p.s("worktree-guard"), p.s("proposal-guard")]);
        put("Stop", "", vec![p.s(Hook::DocSync.name())]);
    }
    if s.get("hooks").and_then(Value::as_object).is_some_and(|h| h.is_empty()) {
        s.as_object_mut().unwrap().shift_remove("hooks");
    }
    write_settings(&file, &s)
}

/// Blocks direct pushes to the main branch. The real protection is server
/// side, but a private repo without a paid plan does not have it: this covers
/// the slip, which is the real case. `--no-verify` skips it, and then it is a
/// decision.
fn install_pre_push(repo: &Path) -> bool {
    let Some(hooks) = dir_hooks(repo) else { return false };
    let main = project::main_branch(repo);
    // The name ends up inside hook code, and it comes from a versioned file
    // anyone can change in a proposal. A valid refname carries none of this.
    if !crate::regex!(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$").is_match(&main) {
        ui::warn(format!("main branch with invalid characters: '{main}'"));
        ui::info(format!("the pre-push of {} is not installed", files::name(repo)));
        return false;
    }
    let written = put_hook(
        &hooks,
        "pre-push",
        &format!(
            r#"#!/usr/bin/env bash
# Installed by crux hooks install.
# Work comes in through a proposal, not by direct push to {main}.
while read -r _ _ remote_ref remote_sha; do
  [[ "$remote_ref" == "refs/heads/{main}" ]] || continue
  # If the remote does not have the branch yet, this push creates it: it is the
  # first upload of a new repo, not work skipping the proposal.
  [[ "$remote_sha" =~ ^0+$ ]] && continue
  echo
  echo "direct push to {main} blocked"
  echo
  echo "  crux workspace new <task>      # own branch and isolated environment"
  echo "  crux workspace finish <task>   # pushes the branch and opens the proposal"
  echo
  echo "If you really need to: git push --no-verify"
  exit 1
done
exit 0
"#
        ),
    );
    if let Err(e) = written {
        ui::warn(e);
        return false;
    }
    true
}

/// Copied instead of calling the kernel from the hook: it keeps working even
/// if `crux` is not on the PATH of whoever commits. In a client's repo only
/// the tool's signature is stripped: their language and format are theirs.
fn install_commit_msg(p: &Paths, repo: &Path, scope: Scope, language: &str) -> bool {
    let Some(hooks) = dir_hooks(repo) else { return false };
    let language = if crate::regex!(r"^[a-z]{2}$").is_match(language) {
        language.to_string()
    } else {
        ui::warn(format!("invalid commit language: '{language}'"));
        "en".into()
    };
    let scope = scope.as_str();
    let template = p.home.join("adapters/git/commit-msg.sh");
    let src = match std::fs::read_to_string(&template) {
        Ok(t) => t,
        Err(e) => {
            ui::warn(format!("cannot read {}: {e}", template.display()));
            return false;
        }
    };
    let out: Vec<String> = src
        .lines()
        .map(|l| {
            if l.starts_with("SCOPE=\"${CRUX_COMMIT_MSG_SCOPE:-full}\"") {
                l.replacen(
                    "SCOPE=\"${CRUX_COMMIT_MSG_SCOPE:-full}\"",
                    &format!("SCOPE=\"${{CRUX_COMMIT_MSG_SCOPE:-{scope}}}\""),
                    1,
                )
            } else if l.starts_with("COMMIT_LANG=\"${CRUX_COMMIT_MSG_LANG:-en}\"") {
                l.replacen(
                    "COMMIT_LANG=\"${CRUX_COMMIT_MSG_LANG:-en}\"",
                    &format!("COMMIT_LANG=\"${{CRUX_COMMIT_MSG_LANG:-{language}}}\""),
                    1,
                )
            } else if l.starts_with("KERNEL=") {
                format!("KERNEL=\"{}\"", p.home.display())
            } else {
                l.to_string()
            }
        })
        .collect();
    if let Err(e) = put_hook(&hooks, "commit-msg", &(out.join("\n") + "\n")) {
        ui::warn(e);
        return false;
    }
    true
}

const PRE_COMMIT: &str = r#"#!/usr/bin/env bash
# Installed by crux hooks install.
# Checks conformance before allowing a commit in the docs repo.
command -v crux >/dev/null || exit 0
if ! crux doctor >/tmp/crux-precommit.$$ 2>&1; then
  echo
  echo "crux doctor does not pass — the commit is stopped:"
  echo
  grep -E "^error" /tmp/crux-precommit.$$ | sed 's/^/  /'
  echo
  echo "Fix it, or skip the check with: git commit --no-verify"
  rm -f /tmp/crux-precommit.$$
  exit 1
fi
rm -f /tmp/crux-precommit.$$
"#;

fn install(p: &Paths) -> Res {
    for h in Hook::ALL {
        if !p.hook(h.name()).is_file() {
            die!("missing {}", p.hook(h.name()).display());
        }
        executable(&p.hook(h.name()));
    }
    let commit_msg = p.home.join("adapters/git/commit-msg.sh");
    if !commit_msg.is_file() {
        die!("missing {}", commit_msg.display());
    }
    executable(&commit_msg);
    if let Some(d) = p.settings.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    if !p.settings.is_file() {
        if let Err(e) = crate::files::write(&p.settings, "{}\n") {
            die!("{e}");
        }
    }
    let _ = std::fs::copy(&p.settings, p.settings.with_extension("json.bak"));
    let mut s = match files::read_json(&p.settings) {
        Ok(v) if v.is_object() => v,
        Ok(_) | Err(_) => die!("{} cannot be read as JSON: fix it before installing hooks", p.settings.display()),
    };
    for h in Hook::ALL {
        let r = h.registration();
        hook_up(&mut s, r.event, &p.s(h.name()), r.previous, r.matcher);
        if let Err(e) = write_settings(&p.settings, &s) {
            die!("{e}");
        }
        ui::ok(r.what);
    }
    // Only if Codex is on the machine: creating its folder installs nothing.
    let ctx = p.home.join("adapters/codex/hooks/contexto.sh");
    if p.codex_dir.is_dir() && ctx.is_file() {
        executable(&ctx);
        if let Err(e) = codex_hooks(p, true) {
            die!("{e}");
        }
        ui::ok(format!(
            "Codex hooks in {} (approve them the first time you open Codex)",
            p.codex_dir.join("hooks.json").display()
        ));
    }
    let plugin = p.home.join("adapters/claude/plugin");
    if plugin.join(".claude-plugin/plugin.json").is_file() {
        plugin_claude(&mut s, true, &plugin);
        if let Err(e) = write_settings(&p.settings, &s) {
            die!("{e}");
        }
        ui::ok("Claude Code plugin: the task reminder as a panel (Claude only)");
    }
    ui::info(format!("previous copy in {}.bak", p.settings.display()));

    // Only a kernel that is a working clone has a repo to guard. Under the
    // suite that clone is the real one, shared by every worktree of it.
    let kernel = env::crux_home().filter(|k| !env::in_tests() && git::ok(k, &["rev-parse", "--git-dir"]));
    if let Some(kernel) = kernel {
        // Both run even if the first fails: `&`, not `&&`.
        let installed = install_pre_push(&kernel) & install_commit_msg(p, &kernel, Scope::Full, "en");
        chain_hooks_path(&kernel);
        if installed {
            ui::ok("pre-push and commit-msg in the kernel");
        }
    }
    let docs = project::find_docs_repo(&std::env::current_dir().unwrap_or_default())
        .filter(|d| git::ok(d, &["rev-parse", "--git-dir"]));
    let Some(docs) = docs else {
        ui::info("no docs repo in the current directory: the pre-commit is not installed");
        ui::info("enter one and repeat to hook it");
        return Ok(());
    };
    let docs_name = files::name(&docs);
    let hooks = dir_hooks(&docs).unwrap_or_default();
    // The docs repo is pushed directly, as the profile rule says: a pre-push
    // there only served to be skipped. The one crux installed earlier goes.
    let crux_pre_push = |f: &Path| {
        files::read_or_empty(f).contains("Installed by crux hooks install")
            || files::read_or_empty(f).contains("Instalado por crux hooks install")
    };
    if (crux_pre_push(&hooks.join("pre-push")) || crux_pre_push(&hooks.join("pre-push.crux")))
        && take_hook(&hooks, "pre-push")
    {
        ui::ok(format!("pre-push removed from {docs_name}: documentation is pushed directly"));
    }
    if let Err(e) = put_hook(&hooks, "pre-commit", PRE_COMMIT) {
        die!("{e}");
    }
    let installed = install_commit_msg(p, &docs, Scope::Full, "en");
    chain_hooks_path(&docs);
    if installed {
        ui::ok(format!("pre-commit and commit-msg in {docs_name}"));
    }

    // Commits in code repos are the majority. Client repos too: .git/hooks is
    // not versioned and travels in no push; skipping them left the one place
    // where the tool's signature must not appear without the net.
    let contract = project::contract_lenient(&docs).unwrap_or_default();
    let profile = files::get_str(&contract, "profile").unwrap_or_else(|| "multi-repo".into());
    let scope =
        if policy::flag(&profile, Some(&docs), "pointers.write", true) { Scope::Full } else { Scope::Signature };
    let language = policy::commit_language(&profile, Some(&docs));
    let root = docs.parent().unwrap();
    for repo in files::str_list(contract.get("repos")).into_iter().filter(|r| !r.is_empty()) {
        if !project::valid_name(&repo) {
            ui::warn(format!("invalid repo name in the contract: {repo}"));
            continue;
        }
        let dir = root.join(&repo);
        if !git::ok(&dir, &["rev-parse", "--git-dir"]) {
            continue;
        }
        if install_commit_msg(p, &dir, scope, &language) {
            ui::ok(format!("commit-msg in {repo} ({})", scope.as_str()));
        }
        if install_pre_push(&dir) {
            ui::ok(format!("pre-push in {repo}"));
        }
        chain_hooks_path(&dir);
    }
    Ok(())
}

fn remove(p: &Paths) -> Res {
    if !p.settings.is_file() {
        die!("no {}", p.settings.display());
    }
    let _ = std::fs::copy(&p.settings, p.settings.with_extension("json.bak"));
    let mut s = match files::read_json(&p.settings) {
        Ok(v) => v,
        Err(e) => die!("{} cannot be read: {e}", p.settings.display()),
    };
    strip_crux(&mut s, CRUX_HOOKS);
    plugin_claude(&mut s, false, &p.home.join("adapters/claude/plugin"));
    if let Err(e) = write_settings(&p.settings, &s) {
        die!("{e}");
    }
    if p.codex_dir.join("hooks.json").is_file() {
        if let Err(e) = codex_hooks(p, false) {
            die!("{e}");
        }
    }
    ui::ok("crux hooks removed (the rest is left as it was)");
    if let Some(docs) = project::find_docs_repo(&std::env::current_dir().unwrap_or_default()) {
        let hooks = dir_hooks(&docs).unwrap_or_default();
        if take_hook(&hooks, "pre-commit") {
            ui::ok("pre-commit removed");
        }
        if take_hook(&hooks, "commit-msg") {
            ui::ok("commit-msg removed");
        }
        unchain_hooks_path(&docs);
        let contract = project::contract_lenient(&docs).unwrap_or_default();
        for repo in files::str_list(contract.get("repos")) {
            let dir = docs.parent().unwrap().join(&repo);
            if !repo.is_empty() && project::valid_name(&repo) && dir.is_dir() {
                if let Some(h) = dir_hooks(&dir) {
                    if take_hook(&h, "commit-msg") | take_hook(&h, "pre-push") {
                        ui::ok(format!("git hooks removed from {repo}"));
                    }
                }
                unchain_hooks_path(&dir);
            }
        }
    }
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let p = paths();
    match argv.first().map(String::as_str).unwrap_or("status") {
        "status" => status(&p),
        "install" => install(&p),
        "remove" => remove(&p),
        _ => die!("usage: crux hooks {{status|install|remove}}"),
    }
}
