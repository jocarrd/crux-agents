//! What `crux <command> --help` prints. Each command's usage is a text file
//! in help/, so it can be read and edited as text; the binary carries them.

pub fn text(name: &str) -> Option<&'static str> {
    let text = match name {
        "add-repo" => include_str!("help/add-repo.txt"),
        "adopt" => include_str!("help/adopt.txt"),
        "archive" => include_str!("help/archive.txt"),
        "bootstrap" => include_str!("help/bootstrap.txt"),
        "checks" => include_str!("help/checks.txt"),
        "clone" => include_str!("help/clone.txt"),
        "doctor" => include_str!("help/doctor.txt"),
        "hooks" => include_str!("help/hooks.txt"),
        "init" => include_str!("help/init.txt"),
        "link" => include_str!("help/link.txt"),
        "machine" => include_str!("help/machine.txt"),
        "mcp" => include_str!("help/mcp.txt"),
        "memory" => include_str!("help/memory.txt"),
        "merge" => include_str!("help/merge.txt"),
        "profile" => include_str!("help/profile.txt"),
        "release" => include_str!("help/release.txt"),
        "review" => include_str!("help/review.txt"),
        "ship" => include_str!("help/ship.txt"),
        "skill" => include_str!("help/skill.txt"),
        "status" => include_str!("help/status.txt"),
        "stg" => include_str!("help/stg.txt"),
        "sync" => include_str!("help/sync.txt"),
        "task" => include_str!("help/task.txt"),
        "upgrade" => include_str!("help/upgrade.txt"),
        "usage" => include_str!("help/usage.txt"),
        "prose" => include_str!("help/prose.txt"),
        "visual" => include_str!("help/visual.txt"),
        "workspace" => include_str!("help/workspace.txt"),
        _ => return None,
    };
    Some(text.strip_suffix('\n').unwrap_or(text))
}
