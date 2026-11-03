# nostrLibBench: PHP harness

`bench.php` follows [`../HARNESS.md`](../HARNESS.md): same flags, timing, accepted-set check
and output schema. Output goes to `results/php.json`.

```bash
php/run.sh --relay ws://127.0.0.1:7777 --quick
php/run.sh --clients nostr-php-persistent --workloads metadata
php/run.sh --list
```

`run.sh` installs the packages pinned in `composer.lock` into `php/vendor` (git-ignored)
with `composer install --no-plugins`, again whenever the lockfile changes, then runs
`bench.php` from the repo root. It needs PHP 8.3 with **ext-gmp** (swentel/nostr-php
requires it; Debian/Ubuntu: `php8.3-gmp`) and ext-pcntl (per-run timeout). `PHP=` picks
another binary. The CLI runs with its default configuration (opcache and JIT off for the
CLI); enabling the tracing JIT changed the verify cost by ~5% in a quick check.

## How it measures

The orchestrator starts `bench.php --child <client> --workload <w>` in a fresh `php`
process per client and workload and reads one JSON line per run from it; it waits at most
`--timeout-ms` + 60 s per line and kills a child that stops making progress. Per run
(HARNESS.md "A run"):

1. Setup, untimed: a new `Relay` (and with it a new phrity WebSocket client), connected
   with `Relay::connect()`, a new `Subscription` id and `Filter` with `setLimit(<events>)`.
2. Timed: `t0 = hrtime()` right before the subscription call. Every delivered event is
   verified with the library's `Event::verify()` and, if valid, counted and its id XORed
   into `accepted_xor` (GMP). EOSE is timestamped when it reaches the app.
3. End: `t_end = max(EOSE, last accepted event)`; then wait for a complete set or 1 s
   without events (untimed; a no-op here since everything runs on one thread).
4. Teardown, untimed: close the connection.

`cpu_ms` is `getrusage()` user + system over t0..end; `peak_rss_mb` is `ru_maxrss` at the
end of the child. The per-run timeout is a `pcntl_alarm`: when it fires, the child reports
how many events it had accepted and the time per accepted event, and the row gets
`error: "timeout: …"`.

**Cost.** `Event::verify` takes ~65 ms of CPU per event on this machine (paragonie/ecc's
BIP-340 verify in PHP on GMP): about 34 minutes for the 31,161-event `all` workload, so
with the default `--timeout-ms` (300 s) both rows on `all` end in a timeout error that
carries the per-event cost. Use a small workload (`--workloads metadata`: 268 events,
~18 s per run) or a much larger timeout to get timings.

## Clients

| client | library | verify | crypto | websocket |
|---|---|---|---|---|
| `nostr-php-persistent` | [swentel/nostr-php](https://github.com/nostrver-se/nostr-php) 1.9.4 (MIT) | explicit | paragonie/ecc 2.6 `SchnorrSignature` (pure PHP on ext-gmp) | phrity/websocket 3.8 (pure PHP, blocking streams) |
| `nostr-php-request` (variant) | swentel/nostr-php 1.9.4 | explicit | same | same |

### swentel/nostr-php

The library delivers relay messages as `RelayResponse` objects (`RelayResponseEvent` has
the `json_decode()`d event as a `stdClass`) and verifies nothing on receipt.
`Event::verify(object|string)` is its verify function: it checks field types, recomputes
the id (SHA-256 of `json_encode([0, pubkey, created_at, kind, tags, content],
JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)`) and verifies the BIP-340 signature with
paragonie/ecc. The harness calls it on every delivered event (`verify: explicit`).

- `json_encode` writes U+0000 as `\u0000`: the ambiguous event is accepted. Expired events
  are delivered (no NIP-40 handling).
- `"sig":""` returns false (no exception).
- An offline check of the id step over the whole corpus matched the expected valid set.
  (`JSON_UNESCAPED_UNICODE` without `JSON_UNESCAPED_LINE_TERMINATORS` escapes U+2028 and
  U+2029, which would break the id of an event containing them; none in this corpus does.)

`nostr-php-persistent` (headline): `new PersistentConnection($relay, $requestMessage)`,
`onReceive($callback)`, `transmit()`. `transmit()` sends the REQ and blocks in phrity's
listen loop, calling the callback for every frame; the library never ends a subscription
on its own, so the callback `pause()`s the connection at EOSE (what its example does with
a timer). It also keeps every `RelayResponse` it received in an array for the life of the
connection, and phrity runs `gc_collect_cycles()` after every frame. `close()` throws
`ConnectionFailureException` on some runs (it disconnects, then sends a close frame on
the closed connection); teardown ignores it.

`nostr-php-request` (variant, fetch-all): `(new Request($relay, $requestMessage))->send()`
reads until EOSE, sends CLOSE, disconnects and returns every response; EOSE reaches the
app when `send()` returns and the events are verified after it.

## Not included

- **innis/nostr-client** 0.10 (+ innis/nostr-core; AMPHP websocket-client) and
  **nostriphant/client** 3.0 (AMPHP websocket-client, nostriphant/nip-01): every released
  version requires PHP ^8.4; this machine has PHP 8.3 (Ubuntu 24.04), and installing 8.4
  from a third-party PPA was not possible here. With PHP 8.4 they could be added to
  `composer.json`. Note for later: nostriphant/secp256k1's fallback `verify()` (used when the
  `secp256k1_nostr` extension is not loaded) calls `openssl_verify` with ECDSA/SHA-256, not
  BIP-340 Schnorr, so without the extension it would reject every valid event.
- **revolution/laravel-nostr**: a Laravel wrapper over swentel/nostr-php (needs a Laravel
  app); its relay path is swentel/nostr-php's, measured above.
- **uma/secp256k1-nostr**: a C extension (libsecp256k1 BIP-340) for PHP, not a client;
  swentel/nostr-php does not use it.
