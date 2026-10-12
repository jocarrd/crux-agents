//! Packs the kernel into the binary, so the binary alone can install it.
//!
//! The format is the simplest that keeps the executable bit: for each file,
//! its path, a newline, its mode in octal, a newline, its length, a newline
//! and its bytes. A tar would need a crate for nothing more.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

include!("kernel_pieces.rs");

fn add(root: &Path, path: &Path, pack: &mut Vec<u8>) {
    if path.is_dir() {
        let mut entries: Vec<PathBuf> = fs::read_dir(path).unwrap().flatten().map(|e| e.path()).collect();
        entries.sort();
        for e in entries {
            add(root, &e, pack);
        }
    } else if path.is_file() {
        // An installed kernel keeps its binary in bin/: it is not part of the source.
        if path.file_name().is_some_and(|n| n == "crux-core") {
            return;
        }
        let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
        let bytes = fs::read(path).unwrap();
        let mode = fs::metadata(path).unwrap().permissions().mode() & 0o777;
        pack.extend_from_slice(format!("{rel}\n{mode:o}\n{}\n", bytes.len()).as_bytes());
        pack.extend_from_slice(&bytes);
    }
}

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("..");
    let mut pack = Vec::new();
    for piece in KERNEL_PIECES {
        let path = root.join(piece);
        println!("cargo:rerun-if-changed={}", path.display());
        add(&root, &path, &mut pack);
    }
    println!("cargo:rerun-if-changed=kernel_pieces.rs");
    fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("kernel.pack"), pack).unwrap();
}
