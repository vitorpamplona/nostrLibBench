//! `nostro2-relay`: one `NostrRelay`, a blocking driver thread per connection that owns the
//! socket (its own RFC 6455 codec), parses each frame into `nostro2::NostrRelayEvent` (serde),
//! verifies notes (`NoteVerifier`, `VerifyPolicy::Reject` by default: id recomputed and
//! compared, then the BIP-340 signature with k256) and pushes them onto a lock-free ring the app
//! reads with `recv_blocking`.

use super::{Client, Meta};
use crate::sink::Sink;
use nostro2_relay::NostrRelay;
use nostro2_relay::nostro2::{NostrRelayEvent, NostrSubscription};

pub const META: Meta = Meta {
    id: "nostro2-relay",
    library: "nostro2-relay",
    library_name: "nostro2-relay",
    api: "NostrRelay::connect_blocking + relay.send(NostrSubscription) + recv_blocking() \
          (NostrRelayEvent::NewNote / EndOfSubscription)",
    websocket: "nostro2-relay's own blocking RFC 6455 codec (coyoquil 0.4 handshake), one driver thread per relay",
    crypto: "k256 0.14 (RustCrypto, pure Rust; nostro2's default `k256` feature)",
    verify: "library",
    notes: "Default VerifyPolicy::Reject: the driver thread checks id (recomputed hash) and signature \
            before publishing a note. The inbound ring (default 1024) drops events when the reader \
            falls behind (logged). The driver delivers in order, so nothing can arrive after EOSE.",
    variant: false,
};

pub struct Nostro2;

impl Client for Nostro2 {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        let mut relay = NostrRelay::connect_blocking(url).map_err(|e| format!("connect: {e}"))?;
        let sub = NostrSubscription { limit: Some(limit as u32), ..Default::default() };
        sink.start();
        relay.send(sub).map_err(|e| format!("send: {e}"))?;
        let res = loop {
            match relay.recv_blocking() {
                Some(NostrRelayEvent::NewNote(_, _, note)) => {
                    match note.id.as_deref() {
                        Some(id) if sink.event_hex(id) => {}
                        _ => break Err("delivered a note without a hex id".to_string()),
                    }
                }
                Some(NostrRelayEvent::EndOfSubscription(..)) => {
                    sink.eose();
                    break Ok(());
                }
                Some(NostrRelayEvent::ClosedSubscription(_, _)) => break Err("subscription closed".into()),
                Some(_) => {}
                None => break Err("connection ended before EOSE".into()),
            }
        };
        relay.close();
        res
    }
}
