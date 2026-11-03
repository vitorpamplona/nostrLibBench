//! `nostro2-relay`: one `NostrRelay`, a blocking driver thread per connection that owns the
//! socket (its own RFC 6455 codec), parses each frame into `nostro2::NostrRelayEvent` (serde),
//! verifies notes (`NoteVerifier`, `VerifyPolicy::Reject` by default: id recomputed and
//! compared, then the BIP-340 signature with k256) and pushes them onto a lock-free ring the app
//! reads with `recv_blocking`.

use super::{Client, Meta};
use crate::sink::Sink;
use nostro2_relay::{DriverConfig, NostrRelay, RelayUrl};
use nostro2_relay::nostro2::{NostrRelayEvent, NostrSubscription};

const WS: &str = "nostro2-relay's own blocking RFC 6455 codec (coyoquil 0.4 handshake), one driver thread per relay";
const CRYPTO: &str = "k256 0.14 (RustCrypto, pure Rust; nostro2's default `k256` feature)";

/// Inbound ring size of the headline row (the default is 1024).
const RING: usize = 65_536;

pub const META: Meta = Meta {
    id: "nostro2-relay",
    library: "nostro2-relay",
    library_name: "nostro2-relay",
    api: "NostrRelay::connect_blocking_config(DriverConfig::new(url).with_capacities(256, 65536)) + \
          relay.send(NostrSubscription) + recv_blocking() (NostrRelayEvent::NewNote / EndOfSubscription)",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: "Default VerifyPolicy::Reject: the driver thread checks the id (recomputed hash) and the \
            signature before publishing a note. The driver drops events when its inbound ring is \
            full (by design: it never blocks the socket); at the default 1024 slots it lost ~3% of \
            a run's events on this busy machine (see nostro2-relay-default), so this row raises the \
            ring to 65536 with DriverConfig::with_capacities. In-order delivery: nothing can \
            arrive after EOSE.",
    variant: false,
};

pub const META_DEFAULT: Meta = Meta {
    id: "nostro2-relay-default",
    library: "nostro2-relay",
    library_name: "nostro2-relay",
    api: "NostrRelay::connect_blocking(url) (default DriverConfig) + relay.send(NostrSubscription) + recv_blocking()",
    websocket: WS,
    crypto: CRYPTO,
    verify: "library",
    notes: "Library defaults, including the 1024-slot inbound ring that drops events when the reader \
            falls behind: a run can lose events (then the row is an error: a run delivered a \
            different set).",
    variant: true,
};

pub struct Nostro2 {
    pub default_config: bool,
}

impl Client for Nostro2 {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        let mut relay = if self.default_config {
            NostrRelay::connect_blocking(url)
        } else {
            let url = RelayUrl::parse(url).map_err(|e| format!("url: {e}"))?;
            NostrRelay::connect_blocking_config(DriverConfig::new(url).with_capacities(256, RING))
        }
        .map_err(|e| format!("connect: {e}"))?;
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
