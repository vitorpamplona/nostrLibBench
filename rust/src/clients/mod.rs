//! The clients: one entry per (library, API) pair. Every client creates a new library client
//! per run (untimed), calls `sink.start()` right before the library's subscription call, feeds
//! each delivered event to the sink, marks EOSE, and tears down (untimed).

mod nostr_rust_client;
mod nostr_sdk_client;
mod nostr_types_client;
mod nostrdb_client;
mod nostrdb_notedeck_client;
mod nostro2_client;

pub use crate::harness::{Client, Meta};

pub fn all() -> Vec<Meta> {
    vec![
        nostr_sdk_client::META_STREAM,
        nostr_sdk_client::META_STREAM_DEFAULT,
        nostr_sdk_client::META_NOTIFICATIONS,
        nostr_sdk_client::META_FETCH,
        nostro2_client::META,
        nostro2_client::META_SECP,
        nostro2_client::META_DEFAULT,
        nostr_rust_client::META_NEXT,
        nostr_rust_client::META_FETCH,
        nostr_types_client::META,
        nostrdb_client::META,
        nostrdb_notedeck_client::META,
        nostrdb_notedeck_client::META_INLINE,
    ]
}

pub fn make(id: &str) -> Result<Box<dyn Client>, String> {
    Ok(match id {
        "nostr-sdk-stream" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Stream)?),
        "nostr-sdk-stream-default" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::StreamDefault)?),
        "nostr-sdk-notifications" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Notifications)?),
        "nostr-sdk-fetch" => Box::new(nostr_sdk_client::Sdk::new(nostr_sdk_client::Mode::Fetch)?),
        "nostro2-relay" => Box::new(nostro2_client::Nostro2 { default_config: false }),
        "nostro2-relay-default" => Box::new(nostro2_client::Nostro2 { default_config: true }),
        "nostr_rust-next_data" => Box::new(nostr_rust_client::NostrRust { fetch: false }),
        "nostr_rust-get_events_of" => Box::new(nostr_rust_client::NostrRust { fetch: true }),
        "nostr-types-client" => Box::new(nostr_types_client::NostrTypes::new()?),
        "nostrdb-tungstenite" => Box::new(nostrdb_client::NostrDb::new()?),
        "nostrdb-notedeck" => Box::new(nostrdb_notedeck_client::NostrDbNotedeck::new(false)?),
        "nostrdb-notedeck-inline" => Box::new(nostrdb_notedeck_client::NostrDbNotedeck::new(true)?),
        other => return Err(format!("unknown client {other}")),
    })
}

pub fn tokio_runtime() -> Result<tokio::runtime::Runtime, String> {
    // What `#[tokio::main]` builds: the multi-threaded scheduler, one worker per core.
    tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())
}
