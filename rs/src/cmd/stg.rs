//! crux stg — publishes a built folder to a password-protected staging, to
//! show work that is not in production yet.
//!
//! The destination does not live here: it is declared once per machine in
//! ~/.crux/staging.env. Each demo has its own user and password, so removing
//! one cuts exactly that access. A deployment restarts nothing: it writes the
//! folder and the block and reloads the configuration, which Caddy validates
//! before applying.

use crate::error::{exit, Res};
use crate::{die, env, sh, ui};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const VARS: [&str; 4] = ["CRUX_STG_SSH", "CRUX_STG_DOMAIN", "CRUX_STG_ROOT", "CRUX_STG_CONTAINER"];

struct Stg {
    ssh: String,
    domain: String,
    root: String,
    container: String,
    keys: PathBuf,
}

/// The config is a shell file of assignments: read as such, without running it.
fn parse_env(text: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for l in text.lines() {
        let l = l.trim();
        let l = l.strip_prefix("export ").unwrap_or(l);
        if l.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = l.split_once('=') {
            let v = v.trim();
            let v = v
                .strip_prefix('"')
                .and_then(|x| x.strip_suffix('"'))
                .or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
                .unwrap_or(v);
            m.insert(k.trim().to_string(), v.to_string());
        }
    }
    m
}

fn read_config() -> Result<Stg, crate::error::Exit> {
    let config =
        env::var("CRUX_STG_CONFIG").map(PathBuf::from).unwrap_or_else(|| env::home().join(".crux/staging.env"));
    let Ok(text) = std::fs::read_to_string(&config) else {
        ui::err(format!("no staging configuration in {}", config.display()));
        ui::info("create it with the four variables documented in this command's header:");
        ui::info("  crux stg --help");
        return Err(crate::error::Exit(1));
    };
    let m = parse_env(&text);
    for v in VARS {
        if m.get(v).is_none_or(|x| x.is_empty()) {
            ui::err(format!("{v} missing in {}", config.display()));
            return Err(crate::error::Exit(1));
        }
    }
    Ok(Stg {
        ssh: m["CRUX_STG_SSH"].clone(),
        domain: m["CRUX_STG_DOMAIN"].clone(),
        root: m["CRUX_STG_ROOT"].clone(),
        container: m["CRUX_STG_CONTAINER"].clone(),
        keys: env::home().join(".crux/staging"),
    })
}

/// The name is a domain label and a remote folder: limited to what is legal
/// in both so as not to have to trust whoever writes it.
fn valid(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('-')
        && !name.ends_with('-')
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

impl Stg {
    fn on_server(&self, script: &str) -> Command {
        let mut c = Command::new("ssh");
        c.args(["-o", "BatchMode=yes", &self.ssh, script]);
        c
    }
    fn run(&self, script: &str) -> sh::Run {
        sh::capture_cmd(&mut self.on_server(script))
    }
    fn with_input(&self, script: &str, input: &str) -> sh::Run {
        let mut c = self.on_server(script);
        c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let Ok(mut child) = c.spawn() else {
            return sh::Run { code: 127, stdout: String::new(), stderr: String::new() };
        };
        let _ = child.stdin.take().unwrap().write_all(input.as_bytes());
        match child.wait_with_output() {
            Ok(o) => sh::Run {
                code: o.status.code().unwrap_or(1),
                stdout: String::from_utf8_lossy(&o.stdout).into(),
                stderr: String::from_utf8_lossy(&o.stderr).into(),
            },
            Err(_) => sh::Run { code: 1, stdout: String::new(), stderr: String::new() },
        }
    }
    /// The plaintext password is stored only here, to repeat the link without
    /// rotating it. The server holds the hash.
    fn key_of(&self, name: &str) -> String {
        let f = self.keys.join(format!("{name}.pass"));
        if !f.is_file() {
            let _ = std::fs::create_dir_all(&self.keys);
            let mut key = String::new();
            if let Ok(mut r) = std::fs::File::open("/dev/urandom") {
                let mut buf = [0u8; 256];
                while key.len() < 20 {
                    if r.read_exact(&mut buf).is_err() {
                        break;
                    }
                    key.extend(buf.iter().map(|&b| b as char).filter(char::is_ascii_alphanumeric).take(20 - key.len()));
                }
            }
            let _ = crate::files::write_atomic(&f, &key, Some(0o600));
        }
        std::fs::read_to_string(&f).unwrap_or_default()
    }
    /// It does not import another project's snippet: if someone renames it,
    /// the staging goes down and the reason is visible nowhere.
    fn caddy_block(&self, name: &str, hash: &str) -> String {
        format!(
            "# Generated by `crux stg deploy {name}`. Do not edit by hand.
{name}.{domain} {{
    encode zstd gzip

    basic_auth {{
        {name} {hash}
    }}

    # This is unpublished work: it is not indexed even if someone shares the link.
    header {{
        X-Robots-Tag \"noindex, nofollow, noarchive\"
        X-Content-Type-Options \"nosniff\"
        Referrer-Policy \"strict-origin-when-cross-origin\"
        -Server
    }}

    root * /srv/staging/{name}
    file_server
}}
",
            domain = self.domain
        )
    }
    /// Validated before reloading: the error reads better here than in the
    /// container's log.
    fn reload(&self) -> Res {
        if !self
            .run(&format!(
                "sudo docker exec {} caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile",
                self.container
            ))
            .ok()
        {
            die!("the Caddy configuration does not validate; nothing was reloaded");
        }
        if !self
            .run(&format!(
                "sudo docker exec -w /etc/caddy {} caddy reload --config /etc/caddy/Caddyfile",
                self.container
            ))
            .ok()
        {
            die!("Caddy did not accept the reload");
        }
        Ok(())
    }
}

fn deploy(s: &Stg, args: &[String]) -> Res {
    let (Some(name), Some(folder)) = (args.first().filter(|x| !x.is_empty()), args.get(1).filter(|x| !x.is_empty()))
    else {
        die!("usage: crux stg deploy <name> <folder>")
    };
    if !valid(name) {
        die!("invalid name: '{name}' — lowercase letters, digits and hyphens");
    }
    let folder_p = Path::new(folder);
    if !folder_p.is_dir() {
        die!("folder {folder} does not exist");
    }
    if !folder_p.join("index.html").is_file() {
        ui::warn(format!("{folder} has no index.html at the root"));
    }
    let key = s.key_of(name);
    // Through stdin and not as an argument: `sudo` leaves the whole command
    // in the server's auth.log forever, and `ps` shows it meanwhile. Caddy
    // asks for the password and its confirmation.
    let r =
        s.with_input(&format!("sudo docker exec -i {} caddy hash-password", s.container), &format!("{key}\n{key}\n"));
    if !r.ok() {
        die!("caddy did not compute the password hash on {}", s.ssh);
    }
    let hash = r.out();
    if !hash.starts_with("$2") {
        die!("caddy returned something that is not a bcrypt hash: {hash}");
    }
    s.run(&format!("mkdir -p '{}/sites/{name}'", s.root));
    let code = sh::status(Command::new("rsync").args([
        "-a",
        "--delete",
        "-e",
        "ssh -o BatchMode=yes",
        &format!("{folder}/"),
        &format!("{}:{}/sites/{name}/", s.ssh, s.root),
    ]));
    if code != 0 {
        return exit(code);
    }
    s.with_input(&format!("cat > '{}/caddy/{name}.caddy'", s.root), &s.caddy_block(name, &hash));
    s.reload()?;
    ui::ok(format!("published {name}"));
    ui::info(format!("https://{name}.{}", s.domain));
    ui::info(format!("user {name} · password {key}"));
    let weight = sh::capture("du", &["-sh", folder]).out();
    ui::info(format!("{} uploaded", weight.split('\t').next().unwrap_or("")));
    Ok(())
}

fn list(s: &Stg) -> Res {
    let names = s.run(&format!("ls -1 '{}/sites' 2>/dev/null", s.root)).out();
    if names.is_empty() {
        ui::info("no demo published");
        return Ok(());
    }
    for n in names.lines().filter(|n| !n.is_empty()) {
        match std::fs::read_to_string(s.keys.join(format!("{n}.pass"))) {
            Ok(k) => println!("  https://{n}.{}  ·  {n} / {k}", s.domain),
            Err(_) => println!("  https://{n}.{}  ·  password not stored on this machine", s.domain),
        }
    }
    Ok(())
}

fn url(s: &Stg, args: &[String]) -> Res {
    let Some(name) = args.first().filter(|x| !x.is_empty()) else { die!("usage: crux stg url <name>") };
    if !valid(name) {
        die!("invalid name: '{name}' — lowercase letters, digits and hyphens");
    }
    if !s.run(&format!("test -d '{}/sites/{name}'", s.root)).ok() {
        die!("there is no demo called {name}");
    }
    println!("https://{name}.{}", s.domain);
    match std::fs::read_to_string(s.keys.join(format!("{name}.pass"))) {
        Ok(k) => println!("user {name} · password {k}"),
        Err(_) => ui::warn("the password is not stored on this machine; regenerate it with a deploy"),
    }
    Ok(())
}

fn rm(s: &Stg, args: &[String]) -> Res {
    let Some(name) = args.first().filter(|x| !x.is_empty()) else { die!("usage: crux stg rm <name>") };
    if !valid(name) {
        die!("invalid name: '{name}' — lowercase letters, digits and hyphens");
    }
    s.run(&format!("rm -f '{}/caddy/{name}.caddy' && rm -rf '{}/sites/{name}'", s.root, s.root));
    s.reload()?;
    let _ = std::fs::remove_file(s.keys.join(format!("{name}.pass")));
    ui::ok(format!("removed {name}"));
    Ok(())
}

pub fn run(argv: &[String]) -> Res {
    let sub = argv.first().map(String::as_str).unwrap_or("");
    let rest = if argv.is_empty() { &[][..] } else { &argv[1..] };
    match sub {
        "deploy" | "list" | "url" | "rm" => {
            let s = read_config()?;
            match sub {
                "deploy" => deploy(&s, rest),
                "list" => list(&s),
                "url" => url(&s, rest),
                _ => rm(&s, rest),
            }
        }
        _ => {
            super::help("stg");
            if sub.is_empty() {
                Ok(())
            } else {
                exit(1)
            }
        }
    }
}
