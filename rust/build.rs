//! Embeds the toolchain description and, from `cargo metadata`, the resolved version, license
//! and source of every crate the harness depends on directly.

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-env-changed=RUSTFLAGS");

    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let rustc_version = Command::new(&rustc)
        .arg("--version")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "rustc (unknown)".into());
    let flags = env::var("CARGO_ENCODED_RUSTFLAGS")
        .unwrap_or_default()
        .split('\u{1f}')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let profile = env::var("PROFILE").unwrap_or_default();
    println!("cargo:rustc-env=LIBBENCH_RUSTC={rustc_version}");
    println!("cargo:rustc-env=LIBBENCH_RUSTFLAGS={flags}");
    println!("cargo:rustc-env=LIBBENCH_PROFILE={profile}");

    let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let manifest = Path::new(&manifest_dir).join("Cargo.toml");
    let target = env::var("TARGET").unwrap_or_default();
    let meta = Command::new(cargo)
        .args(["metadata", "--format-version", "1", "--offline", "--locked", "--filter-platform", &target])
        .arg("--manifest-path")
        .arg(&manifest)
        .output();
    // name -> (version, license); every package in the graph (direct deps win on name clashes).
    let mut crates: BTreeMap<String, (String, String)> = BTreeMap::new();
    match meta {
        Ok(o) if o.status.success() => {
            let v: serde_json::Value = serde_json::from_slice(&o.stdout).expect("cargo metadata json");
            let packages = v["packages"].as_array().unwrap();
            let by_id: BTreeMap<&str, &serde_json::Value> =
                packages.iter().map(|p| (p["id"].as_str().unwrap(), p)).collect();
            let describe = |p: &serde_json::Value| {
                let mut version = p["version"].as_str().unwrap().to_string();
                // A git dependency: name the commit too.
                if let Some(src) = p["source"].as_str().filter(|s| s.starts_with("git+")) {
                    if let Some(rev) = src.rsplit('#').next() {
                        version.push_str(&format!(" (git {})", &rev[..rev.len().min(7)]));
                    }
                }
                // SPDX: old crates write "MIT/Apache-2.0" for "MIT OR Apache-2.0".
                let license = p["license"].as_str().unwrap_or("(see license-file)").replace('/', " OR ");
                (version, license)
            };
            for p in packages {
                let name = p["name"].as_str().unwrap().to_string();
                crates.entry(name).or_insert_with(|| describe(p));
            }
            let nodes = v["resolve"]["nodes"].as_array().unwrap();
            if let Some(node) = nodes
                .iter()
                .find(|n| by_id[n["id"].as_str().unwrap()]["name"] == "libbench-rust")
            {
                for dep in node["deps"].as_array().unwrap() {
                    let p = by_id[dep["pkg"].as_str().unwrap()];
                    crates.insert(p["name"].as_str().unwrap().to_string(), describe(p));
                }
            }
        }
        Ok(o) => println!("cargo:warning=cargo metadata failed: {}", String::from_utf8_lossy(&o.stderr)),
        Err(e) => println!("cargo:warning=cargo metadata failed: {e}"),
    }
    let mut src = String::from("pub const CRATES: &[(&str, &str, &str)] = &[\n");
    for (name, (version, license)) in &crates {
        src.push_str(&format!("    ({name:?}, {version:?}, {license:?}),\n"));
    }
    src.push_str("];\n");
    let out = Path::new(&env::var("OUT_DIR").unwrap()).join("crates.rs");
    fs::write(out, src).unwrap();
}
