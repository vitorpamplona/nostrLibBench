//! `nostr-types` (Mike Dilger's, the event model of the gossip client) with its `client`
//! feature: `nostr_types::client::Client`, a tokio-tungstenite connection whose listener task
//! parses every frame into a `RelayMessage` (serde) and pushes it onto a shared
//! `Vec<RelayMessage>`; `wait_for_subscribed_event_or_eose` scans that Vec for the next message
//! of the subscription and removes it. Events are not verified on receive: the app calls
//! `Event::verify(None)` (id + signature).

use std::time::Duration;

use super::{Client as HarnessClient, Meta};
use crate::sink::Sink;
use nostr_types::Filter;
use nostr_types::client::Client;

pub const META: Meta = Meta {
    id: "nostr-types-client",
    library: "nostr-types",
    library_name: "nostr-types",
    api: "client::Client::new(url) + subscribe(filter) + loop wait_for_subscribed_event_or_eose(sub)",
    websocket: "tokio-tungstenite 0.28 (nostr-types `client` feature)",
    crypto: "libsecp256k1 0.6.0 (C, via secp256k1 0.31 / secp256k1-sys 0.11.0)",
    verify: "explicit",
    notes: "No verification on receive; the harness calls Event::verify(None) (recomputes the id, \
            compares it, checks the signature) on every delivered event. Client connects lazily on \
            the first subscribe, so the connect (~1 ms on loopback) is inside the timed part. \
            Unreleased git version (crates.io has only 0.4.0 from 2023); gossip itself uses its own \
            relay code (tokio-tungstenite) with this crate's types.",
    variant: false,
};

pub struct NostrTypes {
    rt: tokio::runtime::Runtime,
}

impl NostrTypes {
    pub fn new() -> Result<Self, String> {
        Ok(NostrTypes { rt: super::tokio_runtime()? })
    }
}

impl HarnessClient for NostrTypes {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        self.rt.block_on(async move {
            let client = Client::new(url);
            let filter = Filter { limit: Some(limit), ..Default::default() };
            // The per-call timeout; the harness's own --timeout-ms watchdog bounds the run.
            let wait = Duration::from_secs(300);
            sink.start();
            let sub = client.subscribe(filter, Duration::from_secs(10)).await.map_err(|e| e.to_string())?;
            let res = loop {
                match client.wait_for_subscribed_event_or_eose(sub.clone(), wait).await {
                    Ok(Some(event)) => {
                        if event.verify(None).is_ok() {
                            sink.event(&event.id.0);
                        }
                    }
                    Ok(None) => {
                        sink.eose();
                        break Ok(());
                    }
                    Err(e) => break Err(format!("wait_for_subscribed_event_or_eose: {e}")),
                }
            };
            let _ = client.close_subscription(sub).await;
            let _ = client.disconnect().await;
            res
        })
    }
}
