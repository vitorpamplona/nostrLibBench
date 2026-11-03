//! The clients: one entry per (library, API) pair. Every client creates a new library client
//! per run (untimed), calls `sink.start()` right before the library's subscription call, feeds
//! each delivered event to the sink, marks EOSE, and tears down (untimed).

use crate::sink::Sink;

mod nostr_rust_client;
mod nostr_sdk_client;
mod nostr_types_client;
mod nostrdb_client;
mod nostro2_client;

pub struct Meta {
    /// Row id, `<library>-<variant>`.
    pub id: &'static str,
    /// Crate name, for the resolved version and license.
    pub library: &'static str,
    /// Library name as reported.
    pub library_name: &'static str,
    pub api: &'static str,
    pub websocket: &'static str,
    pub crypto: &'static str,
    pub verify: &'static str,
    pub notes: &'static str,
    pub variant: bool,
}

pub trait Client {
    /// One run: setup, subscribe with `{"limit": limit}`, deliver to `sink` until EOSE (and
    /// the post-EOSE wait), teardown.
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String>;
}

pub fn all() -> Vec<Meta> {
    vec![
        nostr_sdk_client::META_STREAM,
        nostr_sdk_client::META_NOTIFICATIONS,
        nostr_sdk_client::META_FETCH,
        nostro2_client::META,
        nostr_rust_client::META_NEXT,
        nostr_rust_client::META_FETCH,
        nostr_types_client::META,
        nostrdb_client::META,
    ]
}

pub fn make(id: &str) -> Result<Box<dyn Client>, String> {
    Ok(match id {
        "nostr-sdk-stream" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Stream)?),
        "nostr-sdk-notifications" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Notifications)?),
        "nostr-sdk-fetch" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Fetch)?),
        "nostro2-relay" => Box::new(nostro2_client::Nostro2),
        "nostr_rust-next_data" => Box::new(nostr_rust_client::NostrRust { fetch: false }),
        "nostr_rust-get_events_of" => Box::new(nostr_rust_client::NostrRust { fetch: true }),
        "nostr-types-client" => Box::new(nostr_types_client::NostrTypes::new()?),
        "nostrdb-tungstenite" => Box::new(nostrdb_client::NostrDb::new()?),
        other => return Err(format!("unknown client {other}")),
    })
}

pub fn tokio_runtime() -> Result<tokio::runtime::Runtime, String> {
    // What `#[tokio::main]` builds: the multi-threaded scheduler, one worker per core.
    tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())
}
