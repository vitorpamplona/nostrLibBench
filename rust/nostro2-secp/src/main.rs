#![allow(dead_code)] // shares source files with the main binary, which uses all of them
//! Child-only binary for `nostro2-relay-secp256k1`: the same client code and child protocol
//! as the main harness binary (shared source files), linked against nostro2 built with its
//! `secp256k1` feature. The main binary's parent launches it with `--child`.

#[path = "../../src/harness.rs"]
mod harness;
#[path = "../../src/sink.rs"]
mod sink;
#[path = "../../src/clients/nostro2_client.rs"]
#[allow(dead_code)]
mod nostro2_client;

// What `nostro2_client` imports from its parent module.
use harness::{Client, Meta};

fn make(id: &str) -> Result<Box<dyn Client>, String> {
    match id {
        "nostro2-relay-secp256k1" => Ok(Box::new(nostro2_client::Nostro2 { default_config: false })),
        other => Err(format!("{other} is not built into this binary")),
    }
}

fn main() {
    let a = harness::parse_args();
    let Some(id) = a.child.clone() else {
        eprintln!("this binary only runs `--child <client>`; use libbench-rust");
        std::process::exit(2);
    };
    harness::run_child(&a, &id, make);
}
