fn main() {
    // Rust ignores SIGPIPE and turns a closed pipe into a panic: `crux … | head`
    // has to end quietly, as any command does.
    // SAFETY: called once, before any thread exists or any output is written.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let argv: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(crux::cmd::dispatch(&argv));
}
