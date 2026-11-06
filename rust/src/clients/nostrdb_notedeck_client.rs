//! Notedeck's relay read path, without nostrdb's database write.
//!
//! Notedeck (damus-io/notedeck 9395544, its `enostr` crate) reads a relay like this: a tokio task
//! owns a tokio-tungstenite 0.24 socket and pushes every text frame into an unbounded channel
//! (`relay/ws.rs`); the outbox service drains it and classifies each frame by its prefix, with no
//! JSON parse (`RelayMessage::from_json`, `relay/message.rs`); every `EVENT` frame becomes a
//! `tokio::spawn`ed `Ndb::process_event_with(frame)` (`outbox/service/mod.rs` ->
//! `remote_data/remote_bridge.rs`). nostrdb copies the frame (`strdupn`) and pushes it,
//! round-robin and without blocking, to one of its ingester threads (one per core, a
//! 32,768-entry inbox each; a full inbox drops the frame), and the ingester parses it with
//! nostrdb's own JSON parser (`ndb_ws_event_from_json`), recomputes and compares the id and
//! verifies the signature with its bundled libsecp256k1 (`ndb_note_verify`), then hands the note
//! to the writer thread, which stores it in LMDB (`nostrdb.c`, `ndb_ingester_process_event` and
//! `ndb_ingester_process_note`).
//!
//! These rows run the same path and the same nostrdb functions up to the hand-off to the
//! writer, and deliver the verified note's id to the app instead of storing it. nostrdb-rs keeps
//! its C bindings private and has no public parse-and-verify, so the functions are declared here
//! from `nostrdb.h` at the pinned commit and resolve against the C library the `nostrdb` crate
//! builds and links.

use std::ffi::{c_char, c_int, c_uint, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio_tungstenite_024 as tt;
use tt::tungstenite::Message;

use super::{Client, Meta};
use crate::sink::Sink;

const COMMON_NOTES: &str = "Variant, unranked: nostrdb has no relay client, so this is Notedeck's \
    relay stack, built by the harness from the pieces Notedeck uses (HARNESS.md: a library with no \
    client is paired with the one its users pair it with). Everything nostrdb's ingester does up to \
    the database is kept, and only what storing needs is left out: the writer thread and LMDB, the \
    id lookup in LMDB during the parse (ndb_ws_event_from_json gets no id callback), and the \
    per-note malloc nostrdb makes because the note moves on to the writer (each thread reuses one \
    buffer of max(frame length x 8, 4096) bytes instead). nostrdb's functions are called through \
    FFI (nostrdb-rs keeps its bindings private): ndb_ws_event_from_json, ndb_note_verify (id \
    recomputed and compared, then secp256k1_xonly_pubkey_parse + secp256k1_schnorrsig_verify), \
    with a SECP256K1_CONTEXT_VERIFY context and a 2 MiB scratch buffer per thread, as its \
    ingesters have. The socket is enostr's: tokio-tungstenite 0.24 over a tokio TcpStream (enostr \
    also sets TCP keepalive, which does nothing on a 1-second local stream). alloc_bytes counts \
    the Rust side only (tokio-tungstenite, the frame copies, the channels); nostrdb's parser \
    writes into the reused buffers and allocates nothing.";

pub const META: Meta = Meta {
    id: "nostrdb-notedeck",
    library: "nostrdb",
    library_name: "nostrdb",
    api: "enostr's path: tokio-tungstenite 0.24 task -> unbounded channel -> prefix check -> \
          tokio::spawn per EVENT -> frame copy -> round-robin to nostrdb-style ingester threads \
          (one per core) -> ndb_ws_event_from_json + ndb_note_verify -> app",
    websocket: "tokio-tungstenite 0.24.0 (enostr's, Notedeck's Cargo.lock)",
    crypto: "libsecp256k1 (C, bundled in nostrdb; ndb_note_verify)",
    verify: "explicit",
    notes: COMMON_NOTES,
    variant: true,
    binary: None,
};

pub const META_INLINE: Meta = Meta {
    id: "nostrdb-notedeck-inline",
    library: "nostrdb",
    library_name: "nostrdb",
    api: "tokio-tungstenite 0.24 read loop -> prefix check -> ndb_ws_event_from_json + \
          ndb_note_verify on the reading task -> app",
    websocket: "tokio-tungstenite 0.24.0 (enostr's, Notedeck's Cargo.lock)",
    crypto: "libsecp256k1 (C, bundled in nostrdb; ndb_note_verify)",
    verify: "explicit",
    notes: "As nostrdb-notedeck, but single-threaded: the task that reads the socket parses and \
            verifies each EVENT frame itself, with no channel, spawn, frame copy or ingester \
            threads in between, so it compares with the single-threaded clients. Variant, \
            unranked, for the same reason as nostrdb-notedeck.",
    variant: true,
    binary: None,
};

// nostrdb.h at nostrdb 12398c2 (the submodule of nostrdb-rs e22e5632a75e).
#[repr(C)]
struct NdbNote {
    _opaque: [u8; 0],
}

/// `struct ndb_tce`: `enum tce_type evtype; const char *subid; int subid_len;` and a union of
/// `struct ndb_event { struct ndb_note *note; }` and `struct ndb_command_result` (24 bytes).
#[repr(C)]
struct NdbTce {
    evtype: c_int,
    subid: *const c_char,
    subid_len: c_int,
    union: [usize; 4],
}

const NDB_TCE_EVENT: c_int = 0x1;
/// secp256k1.h: SECP256K1_FLAGS_TYPE_CONTEXT | SECP256K1_FLAGS_BIT_CONTEXT_VERIFY, what
/// nostrdb's ingester threads create.
const SECP256K1_CONTEXT_VERIFY: c_uint = (1 << 0) | (1 << 8);
/// nostrdb.c DEFAULT_WRITER_SCRATCH_SIZE, the ingesters' scratch buffer.
const SCRATCH_SIZE: usize = 2 * 1024 * 1024;
/// nostrdb.c DEFAULT_QUEUE_SIZE, each ingester thread's inbox.
const INBOX: usize = 32768;

unsafe extern "C" {
    fn ndb_ws_event_from_json(
        json: *const c_char,
        len: c_int,
        tce: *mut NdbTce,
        buf: *mut u8,
        bufsize: c_int,
        cb: *mut c_void,
    ) -> c_int;
    fn ndb_note_verify(secp_ctx: *mut c_void, scratch: *mut u8, scratch_size: usize, note: *mut NdbNote) -> c_int;
    fn ndb_note_id(note: *mut NdbNote) -> *mut u8;
    fn secp256k1_context_create(flags: c_uint) -> *mut c_void;
    fn secp256k1_context_destroy(ctx: *mut c_void);
}

/// One ingester's state: what nostrdb's `ndb_ingester_thread` allocates once.
struct Ingester {
    secp: *mut c_void,
    scratch: Vec<u8>,
    buf: Vec<u8>,
}

impl Ingester {
    fn new() -> Self {
        Ingester {
            secp: unsafe { secp256k1_context_create(SECP256K1_CONTEXT_VERIFY) },
            scratch: vec![0; SCRATCH_SIZE],
            buf: Vec::new(),
        }
    }

    /// `ndb_ingester_process_event` for a relay frame, up to the writer: the verified note's id.
    fn process(&mut self, frame: &[u8]) -> Option<[u8; 32]> {
        let need = (frame.len() * 8).max(4096);
        if self.buf.len() < need {
            self.buf.resize(need, 0);
        }
        let mut tce = NdbTce { evtype: 0, subid: std::ptr::null(), subid_len: 0, union: [0; 4] };
        unsafe {
            let size = ndb_ws_event_from_json(
                frame.as_ptr().cast(),
                frame.len() as c_int,
                &mut tce,
                self.buf.as_mut_ptr(),
                self.buf.len() as c_int,
                std::ptr::null_mut(),
            );
            if size <= 0 || tce.evtype != NDB_TCE_EVENT {
                return None;
            }
            let note = tce.union[0] as *mut NdbNote;
            if ndb_note_verify(self.secp, self.scratch.as_mut_ptr(), self.scratch.len(), note) != 1 {
                return None;
            }
            Some(*(ndb_note_id(note) as *const [u8; 32]))
        }
    }
}

impl Drop for Ingester {
    fn drop(&mut self) {
        unsafe { secp256k1_context_destroy(self.secp) }
    }
}

/// nostrdb's ingester pool: round-robin, non-blocking push into per-thread inboxes.
struct Pool {
    inboxes: Vec<SyncSender<Vec<u8>>>,
    next: AtomicUsize,
    dropped: AtomicUsize,
}

impl Pool {
    /// `ndb_process_event_with` -> `ndb_ingest_event`: copy the frame, dispatch it.
    fn ingest(&self, frame: &[u8]) {
        let copy = frame.to_vec();
        let i = self.next.fetch_add(1, Ordering::Relaxed) % self.inboxes.len();
        if let Err(TrySendError::Full(_)) = self.inboxes[i].try_send(copy) {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}

enum Frame {
    Event,
    Eose,
    Other,
}

/// What enostr's `RelayMessage::from_json` decides from the frame's first bytes.
fn classify(text: &str) -> Frame {
    if text.starts_with("[\"EVENT\"") {
        Frame::Event
    } else if text.starts_with("[\"EOSE\"") {
        Frame::Eose
    } else {
        Frame::Other
    }
}

pub struct NostrDbNotedeck {
    rt: tokio::runtime::Runtime,
    inline: bool,
}

impl NostrDbNotedeck {
    pub fn new(inline: bool) -> Result<Self, String> {
        Ok(NostrDbNotedeck { rt: super::tokio_runtime()?, inline })
    }
}

async fn connect(url: &str) -> Result<tt::WebSocketStream<tokio::net::TcpStream>, String> {
    // enostr's `connect`: its own TcpStream, then the handshake over it (client_async_tls, which
    // for a ws:// URL is client_async on the plain stream; this build has no TLS feature).
    let addr = url.trim_start_matches("ws://");
    let host = addr.split('/').next().unwrap_or(addr);
    let tcp = tokio::net::TcpStream::connect(host).await.map_err(|e| format!("tcp connect: {e}"))?;
    let (ws, _) = tt::client_async(url, tcp).await.map_err(|e| format!("handshake: {e}"))?;
    Ok(ws)
}

impl Client for NostrDbNotedeck {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        let inline = self.inline;
        self.rt.block_on(async move {
            let ws = connect(url).await?;
            if inline { run_inline(ws, limit, sink).await } else { run_pipeline(ws, limit, sink).await }
        })
    }
}

fn req(limit: usize) -> Message {
    Message::text(format!("[\"REQ\",\"bench\",{{\"limit\":{limit}}}]"))
}

async fn run_inline(
    ws: tt::WebSocketStream<tokio::net::TcpStream>,
    limit: usize,
    sink: &mut Sink,
) -> Result<(), String> {
    let (mut tx, mut rx) = ws.split();
    let mut ingester = Ingester::new();
    sink.start();
    tx.send(req(limit)).await.map_err(|e| format!("send: {e}"))?;
    loop {
        if sink.done() {
            return Ok(());
        }
        let wait = if sink.seen_eose() { sink.idle_left() } else { Duration::from_secs(3600) };
        let msg = match tokio::time::timeout(wait, rx.next()).await {
            Ok(Some(Ok(m))) => m,
            Ok(Some(Err(e))) => return Err(format!("read: {e}")),
            Ok(None) => return Err("connection ended before EOSE".into()),
            Err(_) => return Ok(()),
        };
        let Message::Text(text) = msg else { continue };
        match classify(&text) {
            Frame::Event => {
                if let Some(id) = ingester.process(text.as_bytes()) {
                    sink.event(&id);
                }
            }
            Frame::Eose => sink.eose(),
            Frame::Other => {}
        }
    }
}

async fn run_pipeline(
    ws: tt::WebSocketStream<tokio::net::TcpStream>,
    limit: usize,
    sink: &mut Sink,
) -> Result<(), String> {
    let (mut tx, mut rx) = ws.split();

    // enostr's connection task: every text frame into an unbounded channel.
    let (frames_tx, mut frames) = tokio::sync::mpsc::unbounded_channel::<String>();
    let conn = tokio::spawn(async move {
        while let Some(Ok(msg)) = rx.next().await {
            if let Message::Text(text) = msg {
                if frames_tx.send(text).is_err() {
                    break;
                }
            }
        }
    });

    // nostrdb's ingester threads, one per core (its default ingester_threads).
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let (ids_tx, mut ids) = tokio::sync::mpsc::unbounded_channel::<[u8; 32]>();
    let mut inboxes = Vec::with_capacity(threads);
    let mut workers = Vec::with_capacity(threads);
    for _ in 0..threads {
        let (inbox, frames_in) = sync_channel::<Vec<u8>>(INBOX);
        inboxes.push(inbox);
        let ids_tx = ids_tx.clone();
        workers.push(std::thread::spawn(move || {
            let mut ingester = Ingester::new();
            for frame in frames_in {
                if let Some(id) = ingester.process(&frame) {
                    if ids_tx.send(id).is_err() {
                        break;
                    }
                }
            }
        }));
    }
    drop(ids_tx);
    let pool = Arc::new(Pool { inboxes, next: AtomicUsize::new(0), dropped: AtomicUsize::new(0) });

    sink.batching = true;
    sink.start();
    tx.send(req(limit)).await.map_err(|e| format!("send: {e}"))?;

    let mut err = None;
    let mut frames_open = true;
    loop {
        if sink.done() {
            break;
        }
        let wait = if sink.seen_eose() { sink.idle_left() } else { Duration::from_secs(3600) };
        tokio::select! {
            // The outbox service: classify, and spawn an ingest per EVENT frame.
            f = frames.recv(), if frames_open => match f {
                Some(text) => match classify(&text) {
                    Frame::Event => {
                        let pool = pool.clone();
                        tokio::spawn(async move { pool.ingest(text.as_bytes()) });
                    }
                    Frame::Eose => sink.eose(),
                    Frame::Other => {}
                },
                None => {
                    frames_open = false;
                    if !sink.seen_eose() {
                        err = Some("connection ended before EOSE".to_string());
                        break;
                    }
                }
            },
            // The app: every verified note the ingesters hand over.
            id = ids.recv() => match id {
                Some(id) => {
                    sink.event(&id);
                    while let Ok(id) = ids.try_recv() {
                        sink.event(&id);
                    }
                    sink.batch_done();
                }
                None => { err = Some("ingesters stopped".to_string()); break; }
            },
            _ = tokio::time::sleep(wait), if sink.seen_eose() => break,
        }
    }
    conn.abort();
    let dropped = pool.dropped.load(Ordering::Relaxed);
    // Close the inboxes so the ingester threads end, and wait for them (untimed teardown)
    // unless a spawned ingest still holds the pool: then they end when it does.
    let last = Arc::strong_count(&pool) == 1;
    drop(pool);
    drop(frames);
    if last {
        for w in workers {
            let _ = w.join();
        }
    }
    if dropped > 0 && err.is_none() {
        err = Some(format!("{dropped} frames dropped: an ingester inbox was full"));
    }
    match err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
