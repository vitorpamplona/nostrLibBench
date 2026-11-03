//! What the app does with what a library delivers: count it, XOR its id, note the time of
//! EOSE and of any event that arrives after it. Also decides when a run has ended (HARNESS.md
//! "A run", step 3).

use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long the harness waits after EOSE for more events before it calls a run complete,
/// when the accepted set is not yet full (rejected ambiguous / dropped expired events).
pub const IDLE_AFTER_EOSE: Duration = Duration::from_secs(1);

pub struct Expected {
    pub events: usize,
    pub valid: usize,
    pub valid_xor: [u8; 32],
    pub ambiguous: Vec<[u8; 32]>,
    pub expired: Vec<[u8; 32]>,
}

pub struct Sink {
    exp: Arc<Expected>,
    full: usize,
    t0: Option<Instant>,
    cpu0: f64,
    pub accepted: usize,
    pub xor: [u8; 32],
    ambiguous_accepted: usize,
    expired_accepted: usize,
    eose: Option<(Instant, f64)>,
    last_after_eose: Option<(Instant, f64)>,
    last_event: Instant,
    /// The client calls [`Sink::batch_done`] after each batch of events, so the CPU snapshot
    /// for an event after EOSE is taken once per batch instead of once per event.
    pub batching: bool,
    /// Diagnostics: with `LIBBENCH_DUMP_IDS=<file>` set, the accepted ids of the run are
    /// written there (hex, one per line) by [`Sink::dump`].
    dump: Option<Vec<[u8; 32]>>,
}

impl Sink {
    pub fn new(exp: Arc<Expected>) -> Self {
        let full = exp.valid + exp.ambiguous.len();
        Sink {
            exp,
            full,
            t0: None,
            cpu0: 0.0,
            accepted: 0,
            xor: [0; 32],
            ambiguous_accepted: 0,
            expired_accepted: 0,
            eose: None,
            last_after_eose: None,
            last_event: Instant::now(),
            batching: false,
            dump: std::env::var_os("LIBBENCH_DUMP_IDS").map(|_| Vec::new()),
        }
    }

    /// `t0`: called right before the library's subscription call.
    #[inline]
    pub fn start(&mut self) {
        self.cpu0 = crate::cpu_ms();
        self.t0 = Some(Instant::now());
    }

    /// One event the library delivered as valid, by the id in its own event object.
    #[inline]
    pub fn event(&mut self, id: &[u8; 32]) {
        self.accepted += 1;
        if let Some(d) = self.dump.as_mut() {
            d.push(*id);
        }
        for (x, b) in self.xor.iter_mut().zip(id) {
            *x ^= b;
        }
        if self.exp.ambiguous.iter().any(|a| a == id) {
            self.ambiguous_accepted += 1;
        }
        if self.exp.expired.iter().any(|a| a == id) {
            self.expired_accepted += 1;
        }
        if self.eose.is_some() {
            let now = Instant::now();
            self.last_event = now;
            let cpu = if self.batching { f64::NAN } else { crate::cpu_ms() };
            self.last_after_eose = Some((now, cpu));
        }
    }

    /// End of a batch of events (see [`Sink::batching`]).
    pub fn batch_done(&mut self) {
        if let Some((t, c)) = self.last_after_eose.as_mut() {
            if c.is_nan() {
                *c = crate::cpu_ms();
                *t = Instant::now();
            }
        }
    }

    /// Like [`Sink::event`] for libraries that hand over the id as hex.
    #[inline]
    pub fn event_hex(&mut self, id: &str) -> bool {
        match decode_hex32(id) {
            Some(b) => {
                self.event(&b);
                true
            }
            None => false,
        }
    }

    pub fn dump(&self) {
        if let (Some(d), Some(path)) = (&self.dump, std::env::var_os("LIBBENCH_DUMP_IDS")) {
            let s: String = d.iter().map(|id| crate::hex(id) + "\n").collect();
            let _ = std::fs::write(path, s);
        }
    }

    /// The app has seen EOSE.
    pub fn eose(&mut self) {
        if self.eose.is_none() {
            let now = Instant::now();
            self.last_event = now;
            self.eose = Some((now, crate::cpu_ms()));
        }
    }

    pub fn seen_eose(&self) -> bool {
        self.eose.is_some()
    }

    /// Every valid event and every ambiguous one has arrived: nothing more can come.
    pub fn complete(&self) -> bool {
        self.accepted >= self.full
    }

    /// After EOSE: is the run over (complete, or idle for [`IDLE_AFTER_EOSE`])?
    pub fn done(&self) -> bool {
        self.eose.is_some() && (self.complete() || self.last_event.elapsed() >= IDLE_AFTER_EOSE)
    }

    /// How much longer to wait for an event after EOSE before the run is over.
    pub fn idle_left(&self) -> Duration {
        IDLE_AFTER_EOSE.saturating_sub(self.last_event.elapsed())
    }

    /// (ms, cpu_ms) of the run: `t_end = max(EOSE, last accepted event)`.
    pub fn finish(&self) -> Option<(f64, f64)> {
        let t0 = self.t0?;
        let (te, ce) = self.eose?;
        let (t_end, cpu_end) = match self.last_after_eose {
            Some((t, c)) if t > te => (t, c),
            _ => (te, ce),
        };
        Some(((t_end - t0).as_secs_f64() * 1e3, cpu_end - self.cpu0))
    }

    /// The accepted-set check of HARNESS.md "Correctness".
    pub fn summary(&self) -> Value {
        let e = &self.exp;
        let mut want = e.valid_xor;
        let dropped_expired = e.expired.len() - self.expired_accepted.min(e.expired.len());
        let expired_ok = self.expired_accepted == 0 || self.expired_accepted == e.expired.len();
        if self.expired_accepted == 0 {
            for id in &e.expired {
                xor_into(&mut want, id);
            }
        }
        // Which ambiguous ids were accepted is not tracked individually; with one ambiguous
        // event (every workload today) the count says which.
        if self.ambiguous_accepted == e.ambiguous.len() {
            for id in &e.ambiguous {
                xor_into(&mut want, id);
            }
        }
        let want_count = e.valid - dropped_expired + self.ambiguous_accepted;
        let ok = expired_ok
            && (self.ambiguous_accepted == 0 || self.ambiguous_accepted == e.ambiguous.len())
            && self.accepted == want_count
            && self.xor == want;
        json!({
            "accepted": self.accepted,
            "accepted_xor": crate::hex(&self.xor),
            "ambiguous_accepted": self.ambiguous_accepted,
            "expired_accepted": self.expired_accepted,
            "accepted_ok": ok,
        })
    }
}

fn xor_into(acc: &mut [u8; 32], id: &[u8; 32]) {
    for (x, b) in acc.iter_mut().zip(id) {
        *x ^= b;
    }
}

#[inline]
pub fn decode_hex32(s: &str) -> Option<[u8; 32]> {
    let b = s.as_bytes();
    if b.len() != 64 {
        return None;
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    };
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = (nib(b[2 * i])? << 4) | nib(b[2 * i + 1])?;
    }
    Some(out)
}
