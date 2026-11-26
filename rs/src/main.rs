fn main() {
    // Rust ignores SIGPIPE and turns a closed pipe into a panic: `crux … | head`
    // has to end quietly, as any command does.
    // SAFETY: called once, before any thread exists or any output is written.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    // Every crux, git and gh this process starts runs as the same
    // installation: the shared `crux` on the PATH follows CRUX_DIR, and git
    // and gh take the installation's identity unless the environment already
    // carries one (ADR-027). Set here, before any thread exists.
    if std::env::var_os(crux::names::vars::DIR).is_none() {
        std::env::set_var(crux::names::vars::DIR, crux::env::crux_dir());
    }
    for (k, v) in crux::env::installation_identity() {
        if std::env::var_os(k).is_none() {
            std::env::set_var(k, v);
        }
    }
    let argv: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(crux::cmd::dispatch(&argv));
}
