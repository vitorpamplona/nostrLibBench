# Quartz against Notedeck's relay path, 2026-11-06

Quartz's two JVM rows against the three nostrdb rows, on one host, alternating. The nostrdb
rows are Notedeck's relay stack: `nostrdb-tungstenite` with the LMDB write, `nostrdb-notedeck`
without it and `nostrdb-notedeck-inline` single-threaded (see the
[Notedeck run](../2026-11-06-notedeck/README.md) for what each does).

- **Code:** nostrLibBench `5e668d4`. Quartz 2.16.0 (JitPack) on Temurin 27.0.1, `-Xmx2g`, G1;
  nostrdb-rs `e22e5632a75e` (0.10.0), the revision Notedeck pins.
- **Host:** one 4-core Xeon @ 2.1 GHz for the whole run (one boot id). The Go control row
  (`fiatjaf-nostr-relay-libsecp256k1`, `control/`) ran 53.3, 50.8 and 52.1 µs/event at the
  start, after the rounds and after the long round.
- **`rounds/`:** three rounds at the 2026-11-05 reference settings (`all`, 1 warm-up, ≥ 3 runs
  and ≥ 10 s, ≤ 30 runs), each the two Quartz rows then the three nostrdb rows. That gives 5 to
  7 timed runs per row, and Quartz's JIT is still compiling during them: its runs get faster
  to the last one.
- **`long/`:** one run of 25 timed runs per row, after a warm-up, so the JVM reaches its
  steady state.

## Results

`all` workload: 31,161 events; a correct client delivers the 29,613 valid ones, plus the one
ambiguous event it may accept (29,614). `long/`, median of 25 runs:

| row | wall ms | CPU ms | µs per verified event | peak RSS | delivered |
|---|---:|---:|---:|---:|---:|
| `quartz-parallelverifier` | 460 | 1,310 | 15.5 | 380 MB | 29,614 ✔ |
| `nostrdb-notedeck` (no write) | 439 | 1,494 | 16.1 | 105 MB | 27,233 ✘ |
| `nostrdb-tungstenite` (stores in LMDB) | 459 | 1,573 | 16.9 | 221 MB | 27,233 ✘ |
| `quartz-fetch` (one thread) | 1,174 | 1,250 | 39.6 | 376 MB | 29,614 ✔ |
| `nostrdb-notedeck-inline` (one thread) | 1,302 | 1,292 | 47.8 | 11 MB | 27,233 ✘ |

`rounds/`, the reference settings, median of the three rounds' medians, and each round's first
run:

| row | wall ms (rounds) | CPU ms | first run ms |
|---|---:|---:|---:|
| `quartz-parallelverifier` | 564 (553–574) | 1,615 | 1,178–1,270 |
| `nostrdb-notedeck` | 452 (425–461) | 1,522 | 417–451 |
| `nostrdb-tungstenite` | 474 (473–478) | 1,629 | 463–490 |
| `quartz-fetch` | 1,265 (1,226–1,281) | 1,410 | 1,429–1,711 |
| `nostrdb-notedeck-inline` | 1,332 (1,307–1,361) | 1,317 | 1,285–1,427 |

- **Warm, on every core, the two are level:** `quartz-parallelverifier` 460 ms against
  `nostrdb-notedeck` 439 and `nostrdb-tungstenite` 459. Quartz spends 12% less CPU (1,310 ms
  against 1,494), and verifies 2,381 more events: nostrdb's parser can't read `\uXXXX` escapes
  and drops those events before verifying them. Per verified event, Quartz is slightly ahead
  (15.5 µs against 16.1).
- **On one thread, Quartz is ahead:** `quartz-fetch` 1,174 ms against 1,302, 10% faster while
  verifying 9% more events; 39.6 µs per verified event against 47.8.
- **Before the JIT is done, nostrdb is ahead:** at the reference settings
  `quartz-parallelverifier` is 25% slower than `nostrdb-notedeck` (564 ms against 452), and a
  first run takes Quartz 1.2 to 1.7 s against nostrdb's 0.42 to 0.49.
- **Memory:** the JVM peaks at 376 to 380 MB (`-Xmx2g`), nostrdb at 105 MB without the write,
  221 MB with it, and 11 MB single-threaded.
- **Correctness:** both Quartz rows deliver exactly the valid set and the ambiguous event; the
  nostrdb rows lose the 2,380 valid events with `\u` escapes and the ambiguous one, as Notedeck
  does.
