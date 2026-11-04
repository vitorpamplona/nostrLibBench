//! `nostr_rust` (0xtlt, last release Jan 2023): a synchronous client over tungstenite 0.18.
//! It has no verifying receive path: `next_data` hands over raw WebSocket messages and
//! `events::extract_events_ws` parses the event objects out of one; `Event::verify` checks only
//! the signature (over the hash it recomputes, never compared with the event's `id`), so the
//! harness also compares `Event::get_content_id()` (the library's own id function) with `id`.
//! There is no call that does both, so each event is serialised and hashed twice (once in
//! `verify`, once in `get_content_id`, events.rs:195-248): a library cost, named in notes.

use super::{Client as HarnessClient, Meta};
use crate::sink::Sink;
use nostr_rust::events::{Event, extract_events_ws};
use nostr_rust::nostr_client::Client;
use nostr_rust::req::ReqFilter;

const WS: &str = "tungstenite 0.18 (sync, blocking read on the app thread)";
const CRYPTO: &str = "libsecp256k1 0.2.0 (C, via secp256k1 0.26 / secp256k1-sys 0.8.2)";

pub const META_NEXT: Meta = Meta {
    id: "nostr_rust-next_data",
    library: "nostr_rust",
    library_name: "nostr_rust",
    api: "Client::new([url]) + Client::subscribe([ReqFilter]) + loop Client::next_data() -> events::extract_events_ws(msg)",
    websocket: WS,
    crypto: CRYPTO,
    verify: "explicit",
    notes: "No verification on receive. Harness calls Event::verify() (signature only, over the \
            recomputed hash) and compares Event::get_content_id() (library's id hash, serde_json \
            json! serialization) with the event's id. The library has no single verify-both call: \
            verify() serialises and hashes the event, get_content_id() serialises and hashes it \
            again (nostr_rust-0.20.3 events.rs:195-248), so every event is serialised and hashed \
            twice (library cost). EOSE detected by the harness (frame prefix), \
            the library has no EOSE helper on this path. Unmaintained since 2023.",
    variant: false,
    binary: None,
};

pub const META_FETCH: Meta = Meta {
    id: "nostr_rust-get_events_of",
    library: "nostr_rust",
    library_name: "nostr_rust",
    api: "Client::get_events_of([ReqFilter]): returns Vec<Event> after EOSE",
    websocket: WS,
    crypto: CRYPTO,
    verify: "explicit",
    notes: "Fetch-all API: buffers raw messages until EOSE (dedup by a linear scan of the buffer \
            per message, O(n^2)), then parses them. Harness verifies each returned event with \
            Event::verify() + get_content_id() == id. The library has no single verify-both call: \
            verify() serialises and hashes the event, get_content_id() serialises and hashes it \
            again (nostr_rust-0.20.3 events.rs:195-248), so every event is serialised and hashed \
            twice (library cost).",
    variant: true,
    binary: None,
};

pub struct NostrRust {
    pub fetch: bool,
}

#[inline]
fn valid(e: &Event) -> bool {
    e.verify().is_ok() && e.get_content_id() == e.id
}

impl HarnessClient for NostrRust {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        let mut client = Client::new(vec![url]).map_err(|e| format!("connect: {e:?}"))?;
        let filter = ReqFilter {
            ids: None,
            authors: None,
            kinds: None,
            e: None,
            p: None,
            since: None,
            until: None,
            limit: Some(limit as u64),
        };
        if self.fetch {
            sink.start();
            let events = client.get_events_of(vec![filter]).map_err(|e| format!("{e:?}"))?;
            for e in &events {
                if valid(e) {
                    sink.event_hex(&e.id);
                }
            }
            sink.eose();
        } else {
            sink.start();
            let sub = client.subscribe(vec![filter]).map_err(|e| format!("{e:?}"))?;
            let eose = format!("[\"EOSE\",\"{sub}\"]");
            'read: loop {
                let data = client.next_data().map_err(|e| format!("{e:?}"))?;
                for (_relay, msg) in &data {
                    for e in extract_events_ws(msg) {
                        if valid(&e) {
                            sink.event_hex(&e.id);
                        }
                    }
                    if msg.is_text() && msg.to_text().is_ok_and(|t| t.starts_with("[\"EOSE\"") && t.replace(' ', "") == eose) {
                        sink.eose();
                        break 'read;
                    }
                }
            }
            let _ = client.unsubscribe(&sub);
        }
        Ok(())
    }
}
