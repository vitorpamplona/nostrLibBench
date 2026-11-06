# Notedeck's relay path without the database write, 2026-11-06

nostrdb (Damus, Notedeck) is a database, not a relay client: its `nostrdb-tungstenite` row
stores every event in LMDB before it delivers it, so it is a variant and doesn't compare with
the client libraries. This run adds two rows that read a relay the way Notedeck does and stop
where nostrdb would store the note, and reruns `nostrdb-tungstenite` beside them.

- **Code:** nostrLibBench `7896125`. nostrdb is nostrdb-rs `e22e5632a75e` (0.10.0, git), the
  revision Notedeck pins (damus-io/notedeck `9395544`, 2026-10-18); its C library is nostrdb
  `12398c2`, which bundles libsecp256k1 0.4.1. crates.io's nostrdb 0.9.0, which the
  2026-11-05 row ran, bundles 0.6.0.
- **Settings:** the 2026-11-05 settings: `all`, 1 warm-up, ≥ 3 runs and ≥ 10 s, ≤ 30 runs;
  the forged checks one run each (`rust-forged.json`).
- **Host:** a 4-core Xeon @ 2.1 GHz, the reference's host type. The Go control row
  (`fiatjaf-nostr-relay-libsecp256k1`, `control/`) ran 51.7 µs/event before and 53.7 after,
  against 63.8 to 66.8 during the 2026-11-05 run: this host is about 19% faster.

## What the rows do

Notedeck reads a relay through its `enostr` crate:

1. A tokio task owns a tokio-tungstenite 0.24 socket and pushes every text frame into an
   unbounded channel (`relay/ws.rs`).
2. The outbox service drains it and classifies each frame by its first bytes, with no JSON
   parse (`RelayMessage::from_json`, `relay/message.rs`).
3. Each `EVENT` frame becomes a `tokio::spawn`ed `Ndb::process_event_with(frame)`.
4. nostrdb copies the frame and pushes it, round-robin and without blocking, to one of its
   ingester threads (one per core, a 32,768-entry inbox each, full = dropped).
5. The ingester parses the frame with nostrdb's own JSON parser (`ndb_ws_event_from_json`,
   with a callback that looks the id up in LMDB), recomputes and compares the id and
   verifies the signature (`ndb_note_verify`).
6. The note goes to the writer thread, which stores it in LMDB; the app reads it through a
   subscription.

- **`nostrdb-notedeck`** does steps 1 to 5 with the same crates, versions and nostrdb functions,
  and hands the verified note's id to the app instead of step 6. Left out with step 6 is what
  only storing needs: the id lookup during the parse, and the per-note `malloc` nostrdb makes
  because the note moves on to the writer (each thread reuses one buffer of the same size).
- **`nostrdb-notedeck-inline`** parses and verifies each frame on the task that reads the
  socket: single-threaded, no channel, spawn, copy or ingester threads.
- **`nostrdb-tungstenite`** is the stored path, unchanged: frames to `Ndb::process_event`, notes
  back through `SubscriptionStream` and a read transaction.

nostrdb-rs keeps its C bindings private and has no public parse-and-verify, so the new rows
declare the C functions from `nostrdb.h` and call them through FFI. All three are variants:
nostrdb has no relay client, and `HARNESS.md` pairs such a library with the client its users
pair it with, as a variant.

## Results

`all` workload (31,161 events):

| row | wall ms (runs) | CPU ms | cores | first run ms | peak RSS | accepted |
|---|---:|---:|---:|---:|---:|---:|
| `nostrdb-tungstenite` (stores in LMDB) | 453 (433–511) | 1,572 | 3.5 | 470 | 209 MB | 27,233 |
| `nostrdb-notedeck` (no write) | 433 (417–482) | 1,495 | 3.5 | 395 | 83 MB | 27,233 |
| `nostrdb-notedeck-inline` (one thread) | 1,383 (1,177–1,403) | 1,377 | 1.0 | 1,329 | 11 MB | 27,233 |

- **The write costs little time on 4 cores:** 4.6% wall and 5% CPU, with the two rows' runs
  overlapping. The writer is a thread of its own, off the ingesters' path. What it costs is
  memory: peak RSS 209 MB against 83.
- **Parsing and verifying on one thread** takes 44.4 µs per event; the ingester threads spread
  it over the 4 cores (3.5 used).
- **Against the 2026-11-05 ranking,** scaled by the Go control: `nostrdb-notedeck` would be about
  17 µs/event, ahead of `quartz-parallelverifier` (21.1, also every core: 64 µs of CPU per event
  against about 48), and `nostrdb-notedeck-inline` about 55, level with `nostr-sdk-stream` (55.3)
  and behind `zig-nostr-relay` (46.2) and `quartz-fetch` (48.7). The stored row's 14.6 µs/event
  here matches its 17.5 on 2026-11-05 after the same scaling, so nostrdb 0.10.0 is as fast as 0.9.0.
- **Not the same job as a ranked row:** nostrdb's parser can't read `\uXXXX` escapes and drops
  those 2,380 valid events (and the ambiguous one) before verifying them, so these rows verify
  about 8% fewer events than a correct client and deliver 27,233 of 29,613. nostrdb 0.10.0 still
  has the bug, so Notedeck loses the same events.
- **The two paths deliver the same events from the stream.** The stored row also delivers the
  note a kind 6 repost carries in its content, which nostrdb's writer stores as an event of its
  own: on `all` those are in the stream anyway; on `smoke` (11) and on the forged checks (4)
  they are not, which is why it accepts 185 where the others accept 181.
- **Forged checks:** checked against the accepted ids, none of the three delivers a forged
  copy on `forged-content`, `forged-id` or `forged-sig`, and all three miss the same 16 valid
  events (`\u` escapes): the new rows deliver 181 of 197.
- **Allocation:** `alloc_bytes` counts Rust allocations only. The new rows count the frame
  copies (in Rust) that nostrdb makes in C on the stored path, so their 95 MB against 30 MB is
  not a difference in work.
