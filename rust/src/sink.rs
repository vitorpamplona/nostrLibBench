//! What the app does with what a library delivers: count it and XOR its id (nothing else,
//! HARNESS.md "Fairness" 5), and note the time of EOSE and of any event that arrives after
//! it. Also decides when a run has ended (HARNESS.md "A run", step 3) and checks the accepted
//! set afterwards.

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
    alloc0: u64,
    pub accepted: usize,
    pub xor: [u8; 32],
    /// (time, cpu ms, allocated bytes) at EOSE and at the last event after it.
    eose: Option<(Instant, f64, u64)>,
    last_after_eose: Option<(Instant, f64, u64)>,
    last_event: Instant,
    /// The client calls [`Sink::batch_done`] after each batch of events, so the CPU snapshot
    /// for an event after EOSE is taken once per batch instead of once per event.
    pub batching: bool,
    /// The accepted ids, kept only in the untimed diagnostic run (or with
    /// `LIBBENCH_DUMP_IDS=<file>` set, which writes them there).
    record: Option<Vec<[u8; 32]>>,
    /// Diagnostics: `LIBBENCH_CONSUMER_DELAY_US=<n>` makes the app spin n µs per delivered
    /// event, a slow consumer, to probe a library's back-pressure. Off (0) in every real run.
    delay: Duration,
}

impl Sink {
    pub fn new(exp: Arc<Expected>, record: bool) -> Self {
        let full = exp.valid + exp.ambiguous.len();
        let record = record || std::env::var_os("LIBBENCH_DUMP_IDS").is_some();
        Sink {
            exp,
            full,
            t0: None,
            cpu0: 0.0,
            alloc0: 0,
            accepted: 0,
            xor: [0; 32],
            eose: None,
            last_after_eose: None,
            last_event: Instant::now(),
            batching: false,
            record: record.then(Vec::new),
            delay: Duration::from_micros(
                std::env::var("LIBBENCH_CONSUMER_DELAY_US").ok().and_then(|v| v.parse().ok()).unwrap_or(0),
            ),
        }
    }

    /// `t0`: called right before the library's subscription call. The first call of the
    /// process also records `base_rss_mb` (before the clock starts).
    #[inline]
    pub fn start(&mut self) {
        crate::harness::note_base_rss();
        self.cpu0 = crate::harness::cpu_ms();
        self.alloc0 = crate::harness::allocated_bytes();
        self.t0 = Some(Instant::now());
    }

    /// One event the library delivered as valid, by the id in its own event object.
    #[inline]
    pub fn event(&mut self, id: &[u8; 32]) {
        self.accepted += 1;
        for (x, b) in self.xor.iter_mut().zip(id) {
            *x ^= b;
        }
        if let Some(r) = self.record.as_mut() {
            r.push(*id);
        }
        if !self.delay.is_zero() {
            let t = Instant::now();
            while t.elapsed() < self.delay {
                std::hint::spin_loop();
            }
        }
        if self.eose.is_some() {
            let now = Instant::now();
            self.last_event = now;
            let cpu = if self.batching { f64::NAN } else { crate::harness::cpu_ms() };
            self.last_after_eose = Some((now, cpu, crate::harness::allocated_bytes()));
        }
    }

    /// Like [`Sink::event`] for libraries whose event object holds the id as hex.
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

    /// End of a batch of events (see [`Sink::batching`]).
    pub fn batch_done(&mut self) {
        if let Some((t, c, a)) = self.last_after_eose.as_mut() {
            if c.is_nan() {
                *c = crate::harness::cpu_ms();
                *t = Instant::now();
                *a = crate::harness::allocated_bytes();
            }
        }
    }

    pub fn dump(&self) {
        if let (Some(d), Some(path)) = (&self.record, std::env::var_os("LIBBENCH_DUMP_IDS")) {
            let s: String = d.iter().map(|id| crate::harness::hex(id) + "\n").collect();
            let _ = std::fs::write(path, s);
        }
    }

    /// The app has seen EOSE.
    pub fn eose(&mut self) {
        if self.eose.is_none() {
            let now = Instant::now();
            self.last_event = now;
            let cpu = crate::harness::cpu_ms();
            self.eose = Some((now, cpu, crate::harness::allocated_bytes()));
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

    /// (ms, cpu_ms, alloc_bytes) of the run: `t_end = max(EOSE, last accepted event)`.
    pub fn finish(&self) -> Option<(f64, f64, u64)> {
        let t0 = self.t0?;
        let (te, ce, ae) = self.eose?;
        let (t_end, cpu_end, alloc_end) = match self.last_after_eose {
            Some((t, c, a)) if t > te => (t, c, a),
            _ => (te, ce, ae),
        };
        Some(((t_end - t0).as_secs_f64() * 1e3, cpu_end - self.cpu0, alloc_end.wrapping_sub(self.alloc0)))
    }

    /// The accepted-set check of HARNESS.md "Correctness": the (count, XOR) must equal one of
    /// the correct outcomes (expired all delivered or all dropped, each ambiguous event either
    /// way). Which one it matched gives `ambiguous_accepted` and `expired_accepted`; when it
    /// matches none, those come from the recorded ids if this sink kept them, else are null.
    pub fn summary(&self) -> Value {
        let e = &self.exp;
        let xor_all = |ids: &[[u8; 32]]| {
            let mut x = [0u8; 32];
            for id in ids {
                xor_into(&mut x, id);
            }
            x
        };
        let expired_xor = xor_all(&e.expired);
        let n_amb = e.ambiguous.len().min(8);
        let mut matched = None;
        // Each subset of the ambiguous ids (one today) x expired all-or-none.
        'outer: for mask in 0u32..(1 << n_amb) {
            let amb: Vec<[u8; 32]> =
                (0..n_amb).filter(|i| mask & (1 << i) != 0).map(|i| e.ambiguous[i]).collect();
            for expired_in in [true, false] {
                let mut want = e.valid_xor;
                let mut count = e.valid + amb.len();
                if !expired_in {
                    xor_into(&mut want, &expired_xor);
                    count -= e.expired.len();
                }
                xor_into(&mut want, &xor_all(&amb));
                if count == self.accepted && want == self.xor {
                    matched = Some((amb.len(), if expired_in { e.expired.len() } else { 0 }));
                    break 'outer;
                }
            }
        }
        let (amb, exp) = match (matched, &self.record) {
            (Some((a, x)), _) => (json!(a), json!(x)),
            (None, Some(ids)) => (
                json!(ids.iter().filter(|id| e.ambiguous.contains(id)).count()),
                json!(ids.iter().filter(|id| e.expired.contains(id)).count()),
            ),
            (None, None) => (Value::Null, Value::Null),
        };
        json!({
            "accepted": self.accepted,
            "accepted_xor": crate::harness::hex(&self.xor),
            "ambiguous_accepted": amb,
            "expired_accepted": exp,
            "accepted_ok": matched.is_some(),
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
