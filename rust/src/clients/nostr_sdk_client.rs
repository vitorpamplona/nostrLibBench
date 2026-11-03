//! rust-nostr `nostr-sdk`: `Client` with one relay. The relay task parses each frame
//! (`RelayMessage::from_json`, serde_json), drops expired events (NIP-40), verifies id + sig
//! (`EventVerifier::verify_and_cache`, a per-client LRU of verified ids) and checks its events
//! tracker (a per-client LRU of seen ids) before handing the event on. A new `Client` per run
//! starts with both caches empty; neither is process-global.

use std::time::Duration;

use futures::StreamExt;
use nostr_sdk::prelude::*;

use super::{Client as HarnessClient, Meta};
use crate::sink::Sink;

const WS: &str = "tokio-tungstenite 0.28 (via async-wsocket 0.17)";
const CRYPTO: &str = "libsecp256k1 0.4.1 (C, via secp256k1 0.30 / secp256k1-sys 0.10.1)";
const NOTES: &str = "Verifies id + signature of every event (always on; per-Client LRU cache of verified \
     ids, new Client per run). Drops events whose NIP-40 expiration has passed, before verifying \
     them (unconditional), so expired_accepted is 0. Default limits (5 MB message, 2000 tags) \
     left on.";

/// Channel size for the relay's internal notification broadcast (default 2048) and the
/// client's (default 2048), raised so no event of a workload can be lost to a lagging reader.
const CHANNEL: usize = 131_072;

pub const META_STREAM: Meta = Meta {
    id: "nostr-sdk-stream",
    library: "nostr-sdk",
    library_name: "nostr-sdk",
    api: "Client::add_relay(url).notification_channel_size(131072) + try_connect, then \
          Client::stream_events(filter) (ReqExitPolicy::ExitOnEOSE; the stream ends at EOSE)",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: "Verifies id + signature of every event (always on; per-Client LRU cache of verified \
            ids, new Client per run). Drops events whose NIP-40 expiration has passed, before \
            verifying them (unconditional), so expired_accepted is 0. The relay's notification \
            channel is raised from 2048 to 131072 (AddRelay::notification_channel_size): at the \
            default, a reader slower than the relay task makes the subscription's handler lag \
            the broadcast, and the stream then ends early as if EOSE had come (no error item); \
            see nostr-sdk-stream-default.",
    variant: false,
    binary: None,
};

pub const META_STREAM_DEFAULT: Meta = Meta {
    id: "nostr-sdk-stream-default",
    library: "nostr-sdk",
    library_name: "nostr-sdk",
    api: "Client::add_relay(url) + try_connect, then Client::stream_events(filter) (all defaults)",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: NOTES,
    variant: true,
    binary: None,
};

pub const META_NOTIFICATIONS: Meta = Meta {
    id: "nostr-sdk-notifications",
    library: "nostr-sdk",
    library_name: "nostr-sdk",
    api: "Client::builder().notification_channel_size(131072) + add_relay(url).notification_channel_size(131072); \
          Client::notifications() + Client::subscribe(filter): ClientNotification::Event per event, \
          ClientNotification::Message(EndOfStoredEvents) for EOSE",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: "Same pipeline as nostr-sdk-stream, delivered through the client's broadcast \
            notification channel; both broadcast channels raised from 2048 to 131072 (a reader \
            that lags at the default silently loses events). Drops expired events (NIP-40).",
    variant: true,
    binary: None,
};

pub const META_FETCH: Meta = Meta {
    id: "nostr-sdk-fetch",
    library: "nostr-sdk",
    library_name: "nostr-sdk",
    api: "Client::fetch_events(filter).max_events(n): returns a BTreeSet<Event> after EOSE",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: "Fetch-all API: events are delivered to the app at EOSE, sorted and deduplicated. \
            max_events raised from its default 10,000 (which fails the request) to the workload size. \
            Drops expired events (NIP-40).",
    variant: true,
    binary: None,
};

#[derive(Clone, Copy)]
pub enum Mode {
    Stream,
    StreamDefault,
    Notifications,
    Fetch,
}

pub struct Sdk {
    rt: tokio::runtime::Runtime,
    mode: Mode,
}

impl Sdk {
    pub fn new(mode: Mode) -> Result<Self, String> {
        Ok(Sdk { rt: super::tokio_runtime()?, mode })
    }
}

impl HarnessClient for Sdk {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        let mode = self.mode;
        self.rt.block_on(async move {
            // Setup: a new client, connected.
            let raise = !matches!(mode, Mode::StreamDefault);
            let client = if matches!(mode, Mode::Notifications) {
                Client::builder().notification_channel_size(std::num::NonZeroUsize::new(CHANNEL).unwrap()).build()
            } else {
                Client::default()
            };
            if raise {
                client.add_relay(url).notification_channel_size(CHANNEL).await
            } else {
                client.add_relay(url).await
            }
            .map_err(|e| e.to_string())?;
            let out = client.try_connect().timeout(Duration::from_secs(10)).await;
            if !out.failed.is_empty() {
                return Err(format!("connect: {:?}", out.failed));
            }
            let filter = Filter::new().limit(limit);
            let res = match mode {
                Mode::Stream | Mode::StreamDefault => {
                    sink.start();
                    let mut stream = client.stream_events(filter).await.map_err(|e| e.to_string())?;
                    let mut err = None;
                    while let Some((_url, item)) = stream.next().await {
                        match item {
                            Ok(event) => sink.event(event.id.as_bytes()),
                            Err(e) => err = Some(e.to_string()),
                        }
                    }
                    // ExitOnEOSE: the stream ends when EOSE arrives.
                    match err {
                        Some(e) if !sink.complete() => Err(format!("stream error: {e}")),
                        _ => {
                            sink.eose();
                            Ok(())
                        }
                    }
                }
                Mode::Notifications => {
                    let mut notifications = client.notifications();
                    sink.start();
                    client.subscribe(filter).await.map_err(|e| e.to_string())?;
                    loop {
                        let next = if sink.seen_eose() {
                            if sink.done() {
                                break;
                            }
                            match tokio::time::timeout(sink.idle_left(), notifications.next()).await {
                                Ok(n) => n,
                                Err(_) => break,
                            }
                        } else {
                            notifications.next().await
                        };
                        match next {
                            Some(ClientNotification::Event { event, .. }) => sink.event(event.id.as_bytes()),
                            Some(ClientNotification::Message { message, .. }) => {
                                if let RelayMessage::EndOfStoredEvents(_) = *message {
                                    sink.eose();
                                }
                            }
                            Some(ClientNotification::Shutdown) | None => break,
                        }
                    }
                    Ok(())
                }
                Mode::Fetch => {
                    sink.start();
                    let events = client.fetch_events(filter).max_events(limit).await.map_err(|e| e.to_string())?;
                    for event in events.iter() {
                        sink.event(event.id.as_bytes());
                    }
                    sink.eose();
                    Ok(())
                }
            };
            // Teardown.
            client.shutdown().await;
            res
        })
    }
}
