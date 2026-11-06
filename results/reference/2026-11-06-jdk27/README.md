# JVM rows on JDK 27, 2026-11-06

The JVM harness moved from JDK 21 to JDK 27 (Kotlin 2.5.0-Beta2, Java 27 bytecode, Temurin
27.0.1 runtime). This directory holds that harness's rerun of every JVM row, and a same-host
A/B against the JDK 21 build. The [2026-11-05 reference](../2026-11-05/report.md) still holds
the JVM rows in the root README's table: this rerun landed on a faster host, so its numbers
don't compare with the other languages' rows from 2026-11-05.

- **Settings:** the 2026-11-05 settings. `all`: 1 warm-up, ≥ 3 runs and ≥ 10 s, ≤ 30 runs.
  `nostr-java-relaypool`: one run, as the second pass (`jvm-pass2.json`). Forged checks: one
  run each (`jvm-forged.json`).
- **Host:** the same 4-core Xeon type at 2.1 GHz, after a container restart. The Go control
  row (`fiatjaf-nostr-relay-libsecp256k1`, `control/`) ran 53.5 µs/event at the start and 52.1
  at the end, against 63.8 to 66.8 during the 2026-11-05 run: this host is about 20% faster.
- **Code:** nostrLibBench `aa0db99`. Quartz is 2.16.0 from JitPack, compiled for Java 17, as
  on 2026-11-05.

## Outcomes

Every row's outcome matches 2026-11-05 on `all` and on the three forged checks. `nostr-sdk-stream`
still delivers a different set of events on every run, `rhodium-request` and
`nostr-java-relaypool` still fail the same forged checks.

## Does JDK 27 make Quartz faster?

No, not once the code is warm. Five rounds on one host, alternating the JDK 21 build
(`aa0db99^`) and the JDK 27 build, with the Go control first in each round (`ab/`). Both run
the same Quartz jar, so only the JDK and the harness's own bytecode differ. The median of each
round's median:

| client | JDK | wall ms (5 rounds) | CPU ms | first run ms | allocated per pass |
|---|---|---:|---:|---:|---:|
| `quartz-fetch` | 21 | 1,244 (1,198–1,261) | 1,475 | 1,722 | 113 MB |
| `quartz-fetch` | 27 | 1,266 (1,230–1,297) | 1,440 | 1,618 | 110 MB |
| `quartz-parallelverifier` | 21 | 521 (510–534) | 1,525 | 1,284 | 112 MB |
| `quartz-parallelverifier` | 27 | 519 (517–530) | 1,500 | 1,170 | 109 MB |
| Go control | | 1,631 (1,609–1,658) | | | |

- Warm wall time is within noise: the ranges overlap and the fastest runs are the same (1,190
  and 1,197 ms for `quartz-fetch`).
- The first run, while the JIT is still compiling, is 6 to 9% faster on JDK 27.
- JDK 27 allocates about 3% less per pass, in every round.
- The Go control stayed within ±1.5% over the five rounds.

So the rerun's lower numbers (`quartz-fetch` 40.2 µs/event against 48.7 on 2026-11-05) come
from the host, not from JDK 27.
