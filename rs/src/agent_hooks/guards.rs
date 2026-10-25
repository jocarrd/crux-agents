//! The guards that run before a tool: they read the command about to run
//! and stop what cannot be undone or should not run in the foreground.

use super::{cwd, field, input, stop};
use crate::error::Res;
use crate::{env, git, project, registry};
use fancy_regex::Regex as Fancy;
use serde_json::Value;
use std::path::Path;

pub(super) fn fancy(rx: &str) -> Fancy {
    Fancy::new(rx).expect("a guard's expression compiles")
}

pub(super) fn is_match(rx: &Fancy, text: &str) -> bool {
    rx.is_match(text).unwrap_or(false)
}

/// What is not executed does not count: heredoc bodies (commit messages go
/// there), quoted text and comments; except what is handed to another shell.
pub(super) fn runnable(command: &str, unwrap_shells: bool, comments: bool) -> String {
    let heredoc = fancy(r#"<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)"#);
    let mut t = heredoc.replace_all(command, " ").into_owned();
    if unwrap_shells {
        let shells = fancy(r#"\b(bash|sh|zsh|eval)\s+(-c\s+)?(["'])([\s\S]*?)\3"#);
        t = shells.replace_all(&t, " $4 ").into_owned();
    }
    let quoted = fancy(r#""(?:[^"\\]|\\.)*"|'[^']*'"#);
    t = quoted.replace_all(&t, " \"\" ").into_owned();
    if comments {
        let comment = fancy(r"(^|\s)#[^\n]*");
        t = comment.replace_all(&t, " ").into_owned();
    }
    t
}

/// Stops a command known to take minutes when it runs in the foreground:
/// otherwise the agent sits watching it while independent work waits.
pub(super) fn wait_guard() -> Res {
    let event = input();
    if field(&event, "tool_name") != "Bash" {
        return Ok(());
    }
    let params = event.get("tool_input").cloned().unwrap_or(Value::Null);
    if params.get("run_in_background") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    let command = field(&params, "command");
    if is_match(&fancy(r"(^|[\s;&|(])CRUX_WAIT=1\s"), &command) {
        return Ok(());
    }
    // Unwrapped: what goes inside sh -c "…" is what runs, and what is decided on
    let text = runnable(&command, true, false);
    let long: [(&str, &str); 9] = [
        // Only where it runs: as an argument of grep or sed it is being read.
        (r"(^|[;&|(]|\b(?:bash|sh)\s+)\s*(?:[\w.~/-]*/)?test/run\.sh(?=\s*($|[;&|)<>]))", "the whole test suite"),
        (r"(^|[;&|(]|\b(?:bash|sh)\s+)\s*(?:[\w.~/-]*/)?test/e2e\.sh(?=\s*($|[;&|)<>]))", "the end-to-end battery"),
        // The gate is as long as the command it runs: a git diff, a grep or a syntax check is instant.
        (
            r"\bcrux\s+ship\s+run\s+--\s+(?=\S)(?!(git|true|echo|test|ls|cat|grep|rg|wc|diff|head|tail|jq)\b|(?:ba)?sh\s+-n\b)",
            "the quality gate",
        ),
        (r"\bgh\s+(pr\s+checks|run\s+watch)\b[^;&|\n]*--watch|\bgh\s+run\s+watch\b", "watching CI"),
        (r"\buntil\b[\s\S]*?\bdo\b[\s\S]*?\bsleep\b", "a loop that waits"),
        (r"\bsleep\s+([1-9]\d{2,})\b", "a long sleep"),
        (r"\bdocker\s+(compose\s+)?build\b|\bdocker\s+buildx\s+build\b", "an image build"),
        (r"\bgradlew\b[^;&|\n]*\b(assemble|bundle|build)", "an Android build"),
        (r"\beas(-cli)?\s+build(?![:\w-])(?![^;&|\n]*--no-wait)", "a cloud build that is waited for"),
    ];
    let Some((_, what)) = long.iter().find(|(rx, _)| is_match(&fancy(rx), &text)) else { return Ok(()) };
    stop(&format!(
        "Stopped: {what} takes minutes, and in the foreground everything else waits.

Run it in the background and carry on with what does not depend on it; you
are notified when it ends. If the next step really needs this result and
nothing else is left, say so and put CRUX_WAIT=1 in front of the command.
"
    ))
}

/// Stops a `gh pr create` by hand where crux manages the repo: `finish` is
/// what demands the gate receipt, and opening it by hand skips that.
pub(super) fn proposal_guard() -> Res {
    let event = input();
    let command = event.get("tool_input").map(|p| field(p, "command")).unwrap_or_default();
    let text = runnable(&command, true, true);
    if !is_match(&fancy(r"\bgh\b[^;&|\n]*\bpr\s+(create|new)\b"), &text) {
        return Ok(());
    }
    // If the command first enters another folder, that is the one that counts.
    let cd = fancy(r"(?:^|[;&|]\s*)cd\s+(\S+)\s*&&[^;&|\n]*\bgh\b[^;&|\n]*\bpr\s+(create|new)\b");
    let target = match cd.captures(&text).ok().flatten() {
        Some(c) => c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default(),
        None => {
            let c = field(&event, "cwd");
            if c.is_empty() {
                cwd().to_string_lossy().into_owned()
            } else {
                c
            }
        }
    };
    let target = target.strip_prefix('~').map(|r| format!("{}{r}", env::home().display())).unwrap_or(target);
    let target = Path::new(&target);
    if !target.is_dir() {
        return Ok(());
    }
    let Some(top) = git::toplevel(target) else { return Ok(()) };
    let Some(docs) = project::find_docs_repo(&top).filter(|d| *d != top) else { return Ok(()) };
    let _ = docs;
    let base = top.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let next = match base.split_once("-ws-") {
        Some(_) => format!("  crux workspace finish {}", base.rsplit("-ws-").next().unwrap_or("")),
        // Outside a workspace no finish applies: the work goes through one first.
        None => "  crux workspace new <task>      and work there; then\n  crux workspace finish <task>".to_string(),
    };
    stop(&format!(
        "Stopped: in this project the proposal is opened by crux, not by hand with gh pr create.

{next}

finish pushes the branch and opens the proposal, but first it demands the
quality gate receipt (crux ship run and crux ship seal). Opening it by hand
skips that.

If a person wants it as is, they run it themselves with '! <command>' in the
conversation.
"
    ))
}

/// Private keys and credentials. Public ones (.pub) and .env files are left
/// out: the former are not secrets and the latter are moved by carry-env.
fn is_secret(p: &str) -> bool {
    let home = env::home().to_string_lossy().into_owned();
    let p = if p.starts_with("~/") { format!("{home}{}", &p[1..]) } else { p.to_string() };
    [
        r"(^|/)\.ssh/(?!.*\.pub$)(id_[^/]*|[^/]*_key|identity)$",
        r"\.(pem|p12|pfx)$",
        r"(^|/)[^/]*private[^/]*\.key$",
        r"(^|/)\.aws/credentials$",
        r"(^|/)\.config/gh/hosts\.ya?ml$",
        r"(^|/)\.netrc$",
    ]
    .iter()
    .any(|rx| is_match(&fancy(rx), &p))
}

fn secret_stop(path: &str) -> Res {
    stop(&format!(
        "'{path}' is a private key or a credential. Reading it leaves it in the
conversation and in its log.

If it must be used, use it without dumping it (ssh -i, gh auth). If it really
has to be seen, a person should open it.
"
    ))
}

/// Commands that destroy work irreversibly, and reading private keys. With
/// the agent's permissions skipped, it is the only brake left between a wrong
/// deduction and a `reset --hard`.
pub(super) fn destructive_guard() -> Res {
    let event = input();
    let tool = field(&event, "tool_name");
    let params = event.get("tool_input").cloned().unwrap_or(Value::Null);
    if tool != "Bash" {
        let path = ["file_path", "notebook_path", "path"]
            .iter()
            .map(|k| field(&params, k))
            .find(|p| !p.is_empty())
            .unwrap_or_default();
        if !path.is_empty() && is_secret(&path) {
            return secret_stop(&path);
        }
        return Ok(());
    }
    let text = runnable(&field(&params, "command"), true, true);
    let rules: [(&str, &str, &str, &str); 9] = [
        (
            r"\bgit\b[^;&|\n]*\breset\b[^;&|\n]*--hard\b",
            "git reset --hard",
            "throws away uncommitted changes",
            "git stash push -u -m \"<reason>\", or a temporary commit",
        ),
        (
            r"\bgit\b[^;&|\n]*\bpush\b(?=[^;&|\n]*(\s--force(?!-with-lease)\b|\s-[A-Za-z]*f))",
            "git push --force",
            "rewrites the remote history without checking what is there",
            "git push --force-with-lease",
        ),
        (
            r"\bgit\b[^;&|\n]*\bclean\b(?=[^;&|\n]*\s-[A-Za-z]*f)(?=[^;&|\n]*\s-[A-Za-z]*[dxX])",
            "git clean -fd",
            "deletes untracked files, which git cannot recover",
            "git clean -n to see first what it would delete",
        ),
        (
            r"\bgit\b[^;&|\n]*\b(checkout\s+--|restore)\s+(\.|:/)(?=\s|$)",
            "discarding the whole tree",
            "throws away all uncommitted changes in the repo",
            "discard file by file, after looking at the diff",
        ),
        (
            r"\bgit\b[^;&|\n]*\bstash\s+clear\b",
            "git stash clear",
            "the stash stack is shared between worktrees and sessions",
            "git stash drop <sha> of your own",
        ),
        (
            r"\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*[rR])[^;&|\n]*\s(/|~|~/|\$HOME|\$\{HOME\}|\$HOME/|\.|\.\.|\*|\./\*)(?=[\s;&|]|$)",
            "rm -r on /, ~, . or *",
            "takes a whole directory with it",
            "name the exact path you want to delete",
        ),
        (
            r"\bchmod\s+-R\s+0?777\b",
            "chmod -R 777",
            "opens all permissions on a whole tree",
            "grant only the missing permission, to the file that needs it",
        ),
        (r"\bchown\s+-R\b", "chown -R", "changes the owner of a whole tree", "change it on the specific path"),
        (
            r"(^|[\s;&|(])(pkill|killall)\b",
            "pkill / killall",
            "kills by name and takes processes that are not yours",
            "find the PID (pgrep -a <name>) and use kill <PID>",
        ),
    ];
    for (rx, name, why, instead) in rules {
        if is_match(&fancy(rx), &text) {
            return stop(&format!(
                "Stopped: {name} {why}.

Instead: {instead}

If a person wants it as is, they run it themselves with '! <command>' in the
conversation.
"
            ));
        }
    }
    // Reading a private key from the shell. Using it (ssh -i) does not dump
    // it into the conversation, so that is allowed.
    let readers = crate::regex!(r"\b(cat|less|more|head|tail|base64|xxd|od|strings|bat|cp|scp|rsync)\b([^;&|\n]*)");
    for c in readers.captures_iter(&text) {
        if let Some(hit) = c[2].split_whitespace().find(|t| is_secret(t)) {
            return secret_stop(hit);
        }
    }
    Ok(())
}

/// A heredoc body is data for whoever reads it, not more commands, unless the
/// reader is a shell. An apostrophe in the body would otherwise open a quote
/// that swallows the rest.
pub(super) fn drop_heredocs(text: &str) -> String {
    let shell = crate::regex!(r"\b(?:bash|sh|zsh|dash|ksh|ssh|eval)\b");
    let open = fancy(r#"(?<!<)<<(?!<)(-?)\s*(["']?)([A-Za-z_][\w.-]*)\2"#);
    let mut out = vec![];
    let mut pending: Vec<(String, bool, bool)> = vec![];
    for line in text.split('\n') {
        if let Some((word, tabs, keep)) = pending.first().cloned() {
            let l = if tabs { line.trim_start_matches('\t') } else { line };
            if l == word {
                pending.remove(0);
            }
            out.push(if keep { line.to_string() } else { String::new() });
            continue;
        }
        out.push(line.to_string());
        let mut from = 0;
        while let Ok(Some(c)) = open.captures_from_pos(line, from) {
            let m = c.get(0).unwrap();
            let g = |i: usize| c.get(i).map(|m| m.as_str().to_string()).unwrap_or_default();
            pending.push((g(3), g(1) == "-", shell.is_match(&line[..m.start()])));
            from = m.end();
        }
    }
    out.join("\n")
}

/// Each command on its own: a later `; export X=<workspace>` is not part of
/// what gets deleted. Separators inside quotes or escaped do not end one.
pub(super) fn segments(text: &str) -> Vec<String> {
    let mut out = vec![];
    let (mut quote, mut cur) = (None::<char>, String::new());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            cur.push(c);
            if let Some(n) = chars.next() {
                cur.push(n);
            }
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            cur.push(c);
            continue;
        }
        if c == '"' || c == '\'' {
            quote = Some(c);
            cur.push(c);
            continue;
        }
        if matches!(c, '\n' | ';' | '|' | '&') {
            out.push(std::mem::take(&mut cur));
            continue;
        }
        cur.push(c);
    }
    out.push(cur);
    out
}

/// A wildcard deletes the workspaces that match it even if their name does
/// not appear written out.
fn by_wildcard(text: &str, path: &str) -> bool {
    let base = path.rsplit('/').next().unwrap_or(path);
    text.split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|')).any(|t| {
        let clean = t.trim_matches(|c| c == '"' || c == '\'').trim_end_matches('/');
        if !clean.contains(['*', '?', '[']) {
            return false;
        }
        let rx: String = clean
            .chars()
            .map(|c| match c {
                '*' => "[^/]*".to_string(),
                '?' => "[^/]".to_string(),
                '.' | '+' | '^' | '$' | '{' | '}' | '(' | ')' | '|' | '\\' => format!("\\{c}"),
                other => other.to_string(),
            })
            .collect();
        let Ok(re) = regex::Regex::new(&format!("^{rx}$")) else { return false };
        if clean.starts_with('/') {
            re.is_match(path)
        } else {
            re.is_match(base) || re.is_match(path)
        }
    })
}

/// Stops a `git worktree remove` or an `rm -r` on a registered workspace:
/// the shortcut leaves registry entries pointing to folders that are gone.
pub(super) fn worktree_guard() -> Res {
    let event = input();
    if event.is_null() || !registry::path().is_file() {
        return Ok(());
    }
    let command = event.get("tool_input").map(|p| field(p, "command")).unwrap_or_default();
    let comment = fancy(r"(^|\s)#[^\n]*");
    let text = comment.replace_all(&drop_heredocs(&command), " ").into_owned();
    let destroys = [
        r"\bworktree\s+remove\b",
        r"\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*[rR])",
        r"\brm\b(?=[^\n]*--recursive)",
        r"\bfind\b(?=[^\n]*\s-delete\b)",
        r"\bfind\b(?=[^\n]*-exec\s+rm\b)",
    ];
    // Only what comes after the destructive command counts: mentioning the
    // path before, in a cd or an echo, is not deleting it.
    let mut tails = vec![];
    for seg in segments(&text) {
        let first = destroys.iter().filter_map(|rx| fancy(rx).find(&seg).ok().flatten().map(|m| m.start())).min();
        if let Some(i) = first {
            tails.push(seg[i..].to_string());
        }
    }
    if tails.is_empty() {
        return Ok(());
    }
    let tail = tails.join("\n");
    let Ok(list) = registry::read() else { return Ok(()) };
    let end = r#"(?=[\s"';&|]|/?$|/[\s"';&|])"#;
    for w in list {
        let base = w.path.rsplit('/').next().unwrap_or(&w.path);
        let by_path = fancy(&format!("{}{end}", fancy_regex::escape(&w.path)));
        let by_name = fancy(&format!(r#"(^|[\s/"']){}{end}"#, fancy_regex::escape(base)));
        if is_match(&by_path, &tail) || is_match(&by_name, &tail) || by_wildcard(&tail, &w.path) {
            let n = w.name;
            return stop(&format!(
                "'{n}' is a workspace registered in crux. Removing it by hand leaves its
entry in the registry and its task open.

  crux workspace rm {n}

It does the same, removes the entry, archives the task if it is already merged
and refuses if anything is left uncommitted.
"
            ));
        }
    }
    Ok(())
}
