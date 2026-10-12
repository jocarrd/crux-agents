// What a kernel copy holds: build.rs packs it into the binary and install lays
// it out, from that pack or from a clone. One list, so the two cannot drift.
pub const KERNEL_PIECES: [&str; 10] =
    ["bin", "skills", "templates", "profiles", "adapters", "VERSION", "STANDARD.md", "GUIA.md", "README.md", "AGENTS.md"];
