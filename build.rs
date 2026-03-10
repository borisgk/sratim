use std::fs;
use std::path::Path;
use std::process::Command;

fn main() {
    let pkg_version = env!("CARGO_PKG_VERSION");
    let mut version = pkg_version.to_string();

    // Try to get git commit hash
    if let Ok(output) = Command::new("git")
        .args(&["rev-parse", "--short", "HEAD"])
        .output()
    {
        if output.status.success() {
            if let Ok(hash) = String::from_utf8(output.stdout) {
                let hash = hash.trim();
                version = format!("v{}-{}", pkg_version, hash);
                // Save it for remote builds that don't have .git
                let _ = fs::write(".build_version", &version);
            }
        }
    }

    // If git failed (e.g. on remote host without .git), try to read .build_version
    if version == pkg_version {
        if let Ok(saved_version) = fs::read_to_string(".build_version") {
            version = saved_version.trim().to_string();
        } else {
            version = format!("v{}", pkg_version);
        }
    }

    println!("cargo:rustc-env=BUILD_NUMBER={}", version);

    // Ensure we rebuild if git head changes (locally) or .build_version changes
    if Path::new(".git/HEAD").exists() {
        println!("cargo:rerun-if-changed=.git/HEAD");
    }
    println!("cargo:rerun-if-changed=.build_version");
}
