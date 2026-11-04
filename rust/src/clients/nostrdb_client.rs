//! `nostrdb` (Damus / notedeck core, C over LMDB) has no WebSocket client. notedeck's `enostr`
//! reads relays with tokio-tungstenite and hands every `EVENT` frame to
//! `Ndb::process_event`, whose ingester threads parse the frame (its own JSON parser), verify id
//! + signature (bundled libsecp256k1) and write the note to LMDB; the app learns of new notes
//! through an ndb subscription and reads them in a read transaction. This client does the same:
//! tokio-tungstenite reader task -> `process_event`, `SubscriptionStream` (nostrdb's async
//! subscription) -> `get_note_by_key` -> `note.id()`.

use std::time::Duration;

use futures::{SinkExt, StreamExt};
use nostrdb::{Config, Filter, Ndb, SubscriptionStream, Transaction};
use tokio_tungstenite::tungstenite::Message;

use super::{Client, Meta};
use crate::sink::Sink;

pub const META: Meta = Meta {
    id: "nostrdb-tungstenite",
    library: "nostrdb",
    library_name: "nostrdb",
    api: "tokio-tungstenite reader -> Ndb::process_event(frame); Ndb::subscribe(filter) + \
          SubscriptionStream -> Transaction + Ndb::get_note_by_key -> Note::id()",
    websocket: "tokio-tungstenite 0.28 (paired by the harness, as notedeck's enostr does; nostrdb has no WebSocket client)",
    crypto: "libsecp256k1 0.6.0 (C, bundled in nostrdb)",
    verify: "library",
    notes: "Variant, unranked: nostrdb is a database, not a relay client; this row belongs with the \
            app relay stacks (Notedeck/Damus) rather than the client libraries. Config: ingester \
            threads = cores (default), verification on (skip_validation=false, default), and the \
            optional indexing turned off with Config::set_flags(NDB_FLAG_NO_FULLTEXT | \
            NDB_FLAG_NO_NOTE_BLOCKS | NDB_FLAG_NO_STATS) (nostrdb.h:23-25: no full-text index, no \
            parsed content blocks, no stats). The LMDB write of every note remains: storing it is \
            the library's job and the only way it delivers a note (subscription -> read \
            transaction), which is why the row is not ranked. Each run writes to a fresh LMDB in a \
            temp dir (an existing note would skip verification). EOSE is read off the socket \
            before the ingesters finish, so the run ends at the last note delivered after it. The \
            app's read path (subscription poll + read transaction + get_note_by_key) is timed.",
    variant: true,
    binary: None,
};

// nostrdb.h:23-25 (the crate keeps its bindings private).
const NDB_FLAG_NO_FULLTEXT: i32 = 1 << 2;
const NDB_FLAG_NO_NOTE_BLOCKS: i32 = 1 << 3;
const NDB_FLAG_NO_STATS: i32 = 1 << 4;

pub struct NostrDb {
    rt: tokio::runtime::Runtime,
    n: usize,
}

impl NostrDb {
    pub fn new() -> Result<Self, String> {
        Ok(NostrDb { rt: super::tokio_runtime()?, n: 0 })
    }
}

impl Client for NostrDb {
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String> {
        self.n += 1;
        let dir = std::env::temp_dir().join(format!("libbench-ndb-{}-{}", std::process::id(), self.n));
        let _ = std::fs::remove_dir_all(&dir);
        let res = self.rt.block_on(async {
            let cfg = Config::new();
            let flags = cfg.config.flags | NDB_FLAG_NO_FULLTEXT | NDB_FLAG_NO_NOTE_BLOCKS | NDB_FLAG_NO_STATS;
            let cfg = cfg.set_flags(flags);
            let ndb = Ndb::new(dir.to_str().unwrap(), &cfg).map_err(|e| format!("ndb: {e}"))?;
            let (ws, _) = tokio_tungstenite::connect_async(url).await.map_err(|e| format!("connect: {e}"))?;
            let (mut tx, mut rx) = ws.split();
            let (eose_tx, mut eose_rx) = tokio::sync::oneshot::channel::<()>();

            sink.batching = true;
            sink.start();
            let sub = ndb
                .subscribe(&[Filter::new().limit(limit as u64).build()])
                .map_err(|e| format!("ndb subscribe: {e}"))?;
            let mut stream = SubscriptionStream::new(ndb.clone(), sub).notes_per_await(4096);
            tx.send(Message::text(format!("[\"REQ\",\"bench\",{{\"limit\":{limit}}}]")))
                .await
                .map_err(|e| format!("send: {e}"))?;
            let reader_ndb = ndb.clone();
            let reader = tokio::spawn(async move {
                let mut eose_tx = Some(eose_tx);
                while let Some(msg) = rx.next().await {
                    let Ok(Message::Text(text)) = msg else { continue };
                    if text.starts_with("[\"EVENT\"") {
                        let _ = reader_ndb.process_event(&text);
                    } else if text.starts_with("[\"EOSE\"") {
                        if let Some(t) = eose_tx.take() {
                            let _ = t.send(());
                        }
                    }
                }
            });

            let mut eose_seen = false;
            let mut err = None;
            loop {
                if sink.done() {
                    break;
                }
                let wait = if eose_seen { sink.idle_left() } else { Duration::from_secs(3600) };
                tokio::select! {
                    biased;
                    r = &mut eose_rx, if !eose_seen => {
                        if r.is_err() {
                            err = Some("connection ended before EOSE".to_string());
                            break;
                        }
                        eose_seen = true;
                        sink.eose();
                    }
                    r = tokio::time::timeout(wait, stream.next()) => match r {
                        Ok(Some(keys)) => {
                            let txn = Transaction::new(&ndb).map_err(|e| format!("txn: {e}"))?;
                            for key in keys {
                                match ndb.get_note_by_key(&txn, key) {
                                    Ok(note) => sink.event(note.id()),
                                    Err(e) => { err = Some(format!("get_note_by_key: {e}")); }
                                }
                            }
                            sink.batch_done();
                        }
                        Ok(None) => { err = Some("subscription ended".into()); break; }
                        Err(_) => if eose_seen { break },
                    }
                }
            }
            reader.abort();
            drop(stream);
            drop(ndb);
            match err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        });
        let _ = std::fs::remove_dir_all(&dir);
        res
    }
}
