# Quartz against Notedeck's relay path, 2026-11-06

Quartz's two JVM rows against the three nostrdb rows, on one host, alternating. The nostrdb
rows are Notedeck's relay stack: `nostrdb-tungstenite` with the LMDB write, `nostrdb-notedeck`
without it and `nostrdb-notedeck-inline` single-threaded (see the
[Notedeck run](../2026-11-06-notedeck/README.md) for what each does).

- **Code:** nostrLibBench `b06d3b5`. Quartz 2.16.0 (JitPack) on Temurin 27.0.1, `-Xmx2g`, G1;
  nostrdb-rs `e22e5632a75e` (0.10.0), the revision Notedeck pins.
- **Host:** one 4-core Xeon @ 2.1 GHz for the whole run (one boot id). It slowed down while the
  run went on: the Go control row (`fiatjaf-nostr-relay-libsecp256k1`, `control/`) ran 52.7
  µs/event at the start, 60.3 after the rounds, 56.4 and 56.0 after the second and third long
  rounds. Rows compare within a round, where both sides ran minutes apart.
- **`rounds/`:** three rounds at the 2026-11-05 reference settings (`all`, 1 warm-up, ≥ 3 runs
  and ≥ 10 s, ≤ 30 runs), each the two Quartz rows then the three nostrdb rows. That gives 5 to
  7 timed runs per row, and Quartz's JIT is still compiling during them.
- **`long/`:** three rounds of 25 timed runs per row after a warm-up, so the JVM reaches its
  steady state: Quartz first in rounds 1 and 3, nostrdb first in round 2.
- **Earlier version:** this directory first held a run in which the nostrdb rows gave nostrdb
  their whole reused buffer, which grows to the largest frame seen, instead of the per-event
  size its ingester allocates. nostrdb's parse slows down with the size it is given, so that
  run understated `nostrdb-notedeck` and `nostrdb-notedeck-inline`; these are the rows after
  the fix.

## Results

`all` workload: 31,161 events; a correct client delivers the 29,613 valid ones, plus the one
ambiguous event it may accept (29,614). `long/`, median of the three rounds' medians (range):

| row | wall ms | CPU ms | µs per verified event | peak RSS | delivered |
|---|---:|---:|---:|---:|---:|
| `nostrdb-notedeck` (no write) | 422 (416–428) | 1,471 | 15.5 | 96–111 MB | 27,233 ✘ |
| `nostrdb-tungstenite` (stores in LMDB) | 495 (494–496) | 1,675 | 18.2 | 211–214 MB | 27,233 ✘ |
| `quartz-parallelverifier` | 526 (518–545) | 1,490 | 17.8 | 378–389 MB | 29,614 ✔ |
| `nostrdb-notedeck-inline` (one thread) | 1,285 (1,278–1,314) | 1,281 | 47.2 | 11 MB | 27,233 ✘ |
| `quartz-fetch` (one thread) | 1,307 (1,291–1,337) | 1,420 | 44.1 | 362–400 MB | 29,614 ✔ |

`rounds/`, the reference settings, median of the three rounds' medians (range), and each
round's first run:

| row | wall ms | CPU ms | first run ms |
|---|---:|---:|---:|
| `nostrdb-notedeck` | 407 (390–426) | 1,462 | 398–464 |
| `nostrdb-tungstenite` | 464 (452–475) | 1,632 | 485–530 |
| `quartz-parallelverifier` | 516 (505–524) | 1,495 | 1,189–1,405 |
| `nostrdb-notedeck-inline` | 1,216 (1,206–1,363) | 1,209 | 1,143–1,285 |
| `quartz-fetch` | 1,263 (1,153–1,310) | 1,510 | 1,556–1,689 |

- **On every core, Notedeck's path is ahead of Quartz:** warm, `nostrdb-notedeck` takes 422 ms
  against 526 for `quartz-parallelverifier`, 20% less, in each of the three long rounds, at
  about the same CPU (1,471 ms against 1,490). It verifies 2,381 fewer events, because nostrdb's
  parser drops those with `\uXXXX` escapes before verifying them, but it is ahead per verified
  event too: 15.5 µs against 17.8. With the LMDB write (`nostrdb-tungstenite`, 495 ms) it is
  still 6% ahead.
- **On one thread, the two are level:** warm, `quartz-fetch` 1,307 ms against
  `nostrdb-notedeck-inline` 1,285, nostrdb ahead by 0.5 to 2% in each long round. Per verified
  event Quartz is 7% ahead (44.1 µs against 47.2); it spends 11% more CPU (1,420 ms against
  1,281).
- **Before the JIT is done, the gap is wider:** at the reference settings `nostrdb-notedeck`
  takes 407 ms against 516, and a first run takes Quartz 1.2 to 1.7 s against nostrdb's 0.40
  to 0.53.
- **Memory:** the JVM peaks at 362 to 400 MB (`-Xmx2g`), nostrdb at 96 to 111 MB without the
  write, 211 to 214 MB with it, and 11 MB single-threaded.
- **Correctness:** both Quartz rows deliver exactly the valid set and the ambiguous event; the
  nostrdb rows lose the 2,380 valid events with `\u` escapes and the ambiguous one, as Notedeck
  does.
