//! `crux __fn <function> <args...>`: single functions of the kernel for what
//! is still a shell script —a skill's script, a git hook— and for the suite
//! cases that test each piece on its own. Booleans answer with the exit code;
//! values are printed.

use crate::error::{exit, Res};
use crate::{env, git, project, registry, sh, template};

fn yes(b: bool) -> Res {
    if b {
        Ok(())
    } else {
        exit(1)
    }
}

fn print(v: Option<String>) -> Res {
    match v {
        Some(s) => {
            println!("{s}");
            Ok(())
        }
        None => exit(1),
    }
}

pub fn run(argv: &[String]) -> Res {
    let a = |i: usize| argv.get(i).cloned().unwrap_or_default();
    let p = |i: usize| std::path::PathBuf::from(a(i));
    match a(0).as_str() {
        "is_semver" => yes(project::is_semver(&a(1))),
        "version_greater_than" => yes(project::version_greater_than(&a(1), &a(2))),
        "valid_name" => yes(project::valid_name(&a(1))),
        "is_worktree" => yes(git::is_worktree(&p(1))),
        "main_repo" => print(git::main_repo(&p(1)).map(|m| project::normalize(&m).display().to_string())),
        "main_branch" => print(Some(project::main_branch(&p(1)))),
        "find_docs_repo" => print(project::find_docs_repo(&p(1)).map(|d| d.display().to_string())),
        "preference" => print(Some(env::preference(&a(1), &a(2)))),
        "projects_root" => print(Some(env::projects_root().display().to_string())),
        "task_dir" => print(Some(env::tasks_dir().display().to_string())),
        "json_get" => {
            let v = crate::files::read_json(&p(1)).ok().and_then(|j| crate::files::get(&j, &a(2)).cloned());
            print(v.map(|x| crate::files::value_text(&x)))
        }
        "json_value" => {
            let v = crate::files::read_json(&p(1)).ok().and_then(|j| crate::files::get(&j, &a(2)).cloned());
            print(v.map(|x| x.to_string()))
        }
        "json_rows" => json_rows(&p(1), &a(2), &argv[3.min(argv.len())..]),
        "json_quote" => print(Some(serde_json::Value::String(a(1)).to_string())),
        "json_set" | "json_del" | "json_push" => {
            edit_json(&p(1), a(0).as_str(), &a(2), argv.get(3).map(String::as_str))
        }
        "valid_json" => match crate::files::read_json(&p(1)) {
            Ok(_) => Ok(()),
            Err(e) => {
                print!("{e}");
                exit(1)
            }
        },
        "remote_url" => print(crate::files::read_json(&p(1)).ok().and_then(|c| project::remote_url(&c, &a(2)))),
        "remote_from_git" => print(project::remote_from_git(&p(1))),
        "normalize_git_url" => print(Some(project::normalize_git_url(&a(1)))),
        "owner_from_template" => print(Some(project::owner_from_template(&a(1)))),
        "template_for_owner" => print(Some(project::template_for_owner(&a(1)))),
        "render_managed" => {
            let code = match template::render_managed(&p(1), &p(2), &[]) {
                Ok(template::Managed::Created) => 0,
                Ok(template::Managed::Updated) => 1,
                Ok(template::Managed::Unchanged) => 2,
                Ok(template::Managed::Foreign) => 3,
                Ok(template::Managed::TemplateWithoutBlock) => 4,
                Err(_) => 5,
            };
            if code == 0 {
                Ok(())
            } else {
                exit(code)
            }
        }
        "with_timeout" => {
            let seconds = a(1).parse().unwrap_or(0);
            let mut c = std::process::Command::new(a(2));
            c.args(&argv[3.min(argv.len())..]);
            let r = sh::with_timeout(&mut c, seconds);
            print!("{}", r.stdout);
            eprint!("{}", r.stderr);
            if r.code == 0 {
                Ok(())
            } else {
                exit(r.code)
            }
        }
        "with_lock" => match registry::lock(a(1).parse().unwrap_or(300)) {
            Ok(_held) => print(Some("locked".into())),
            Err(e) => {
                crate::ui::err(e);
                exit(1)
            }
        },
        other => {
            eprintln!("unknown function: {other}");
            exit(2)
        }
    }
}

/// json_set creates the objects the dotted path lacks; the others do not.
fn edit_json(file: &std::path::Path, op: &str, path: &str, value: Option<&str>) -> Res {
    use serde_json::Value;
    let fail = |m: String| -> Res {
        eprintln!("{op}: {m}");
        exit(1)
    };
    let mut root = match crate::files::read_json(file) {
        Ok(v) => v,
        Err(e) => return fail(format!("{}: {e}", file.display())),
    };
    let value: Option<Value> = match value.map(serde_json::from_str) {
        Some(Ok(v)) => Some(v),
        Some(Err(e)) => return fail(format!("the value is not JSON: {e}")),
        None if op == "json_del" => None,
        None => return fail("missing the value".into()),
    };
    let keys: Vec<&str> = path.split('.').collect();
    let (last, parents) = keys.split_last().expect("split always yields one key");
    let mut node = &mut root;
    for k in parents {
        if !node.get(*k).is_some_and(Value::is_object) {
            if op != "json_set" {
                return fail(format!("{path}: '{k}' is not an object"));
            }
            node.as_object_mut().map(|o| o.insert(k.to_string(), Value::Object(Default::default())));
        }
        node = node.get_mut(*k).expect("just checked or inserted");
    }
    let Some(obj) = node.as_object_mut() else { return fail(format!("{path}: the parent is not an object")) };
    match (op, value) {
        ("json_set", Some(v)) => {
            obj.insert(last.to_string(), v);
        }
        ("json_del", _) => {
            obj.shift_remove(*last);
        }
        ("json_push", Some(v)) => match obj.get_mut(*last).and_then(Value::as_array_mut) {
            Some(list) => list.push(v),
            None => return fail(format!("{path} is not an array")),
        },
        _ => return fail("unknown operation".into()),
    }
    match std::fs::write(file, crate::files::json_pretty(&root)) {
        Ok(()) => Ok(()),
        Err(e) => fail(format!("{}: {e}", file.display())),
    }
}

/// One line per element of the array at `path`, its fields tab-separated and
/// empty where missing. Exit 2 when there is no such array; 1 when the file
/// cannot be read, which a caller must not take for "nothing declared".
fn json_rows(file: &std::path::Path, path: &str, fields: &[String]) -> Res {
    let root = match crate::files::read_json(file) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{}: {e}", file.display());
            return exit(1);
        }
    };
    let Some(list) = crate::files::get(&root, path).and_then(serde_json::Value::as_array) else { return exit(2) };
    for item in list {
        let row: Vec<String> = fields
            .iter()
            .map(|f| {
                crate::files::get(item, f).map(crate::files::value_text).unwrap_or_default().replace(['\t', '\n'], " ")
            })
            .collect();
        println!("{}", row.join("\t"));
    }
    Ok(())
}
