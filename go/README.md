# nostrLibBench: Go harness

The Go side of [nostrLibBench](../HARNESS.md): every Go Nostr client library, driven
through its own relay client, its own WebSocket stack, JSON decoder and signature check,
on one job: subscribe, receive every event of the workload, verify it, hand it to the
app, until EOSE.

```bash
./go/run.sh --relay ws://127.0.0.1:7777                 # every client -> results/go.json
./go/run.sh --relay ws://127.0.0.1:7777 --quick
./go/run.sh --clients go-nostr-relay,orly-ws --workloads all,notes
./go/run.sh --list
```

`run.sh` builds from the pinned `go.mod`/`go.sum` and runs from the repo root, so relative
`--corpus`/`--out` paths are relative to it. It takes every HARNESS.md flag. `go.mod`
says `go 1.26.8` (nmilat needs it); with the default `GOTOOLCHAIN=auto` an older local
`go` downloads that toolchain on the first build.

It builds three binaries into `go/libbench/` (git-ignored):

| binary | what |
|---|---|
| `libbench` | every client, default build (pure-Go crypto); also the parent |
| `libbench-secp-gonostr` | go-nostr built with its `libsecp256k1` tag (cgo) |
| `libbench-secp-fiatjaf` | fiatjaf.com/nostr built with its `libsecp256k1` tag (cgo) |

go-nostr and fiatjaf.com/nostr vendor the same libsecp256k1 C sources and `#include` them
from a cgo file, so linking both into one cgo binary fails with duplicate symbols; each
gets its own binary (`lib_gonostr.go` / `lib_fiatjaf.go` carry the build constraints).
The cgo builds need a C compiler (gcc); without one those two rows report an error.

## How it measures

The harness follows HARNESS.md "A run"; the Go specifics:

- **Isolation.** The parent (`libbench`) runs each client in a fresh child process of
  the binary that client needs (`--child --clients <id>`), one at a time. The child
  writes its rows to a file the parent names, so nothing a library prints can corrupt
  them; a child that crashes still gets rows with `error` set (the panic line goes in
  `error`), and the parent kills a child stuck outside a run.
- **Setup (untimed).** A new client per run: `RelayConnect` / `NewPool` + `EnsureRelay` /
  `client.Connect` / `NewRelayManager` + `Connect`, connected to `<relay>/<workload>`
  before `t0`. Every library here connects explicitly, so no connect is timed.
- **Timed part.** `t0` = `time.Now()` (monotonic) right before the library's subscribe
  call with one filter `{"limit": <events>}`. The adapter (`lib_*.go`) consumes the
  library's streaming API on a goroutine, as an app would: for each delivered event it
  runs the verification the row's `verify`/`notes` name, then the collector counts it,
  XORs its 32-byte id (from the library's own event object) and notes the time (nothing
  else: no lookup of which ids are ambiguous or expired); the
  EOSE is noted when the library delivers it. `t_end = max(EOSE, last accepted event)`.
  The main goroutine waits until EOSE and either every event a correct library can
  deliver (valid + ambiguous) has arrived or 1 s passed with nothing new (untimed), or
  until `--timeout-ms` (an error if no EOSE came; the child then exits without
  teardown, since a wedged library may never return from it).
- **CPU.** `getrusage(RUSAGE_SELF)` user+system (all threads) read right before `t0`
  and again when the EOSE is delivered and at every accepted event after it, so
  `cpu_ms` covers `t0 .. t_end` and not the untimed wait. `peak_rss_mb` is `ru_maxrss`
  at the end of the workload (warm-ups and every run).
- **Memory.** `base_rss_mb` is `VmRSS` from `/proc/self/status`, read in the child after
  `runtime.GC()` at the end of the first setup of each workload (client connected, before
  the first REQ; the child runs every workload of a client, so later workloads see the
  heap the earlier ones left). `alloc_bytes` is the growth of `runtime.MemStats.TotalAlloc`
  (heap bytes, all goroutines), read with `ReadMemStats` (stop-the-world) right before
  `t0` and right after the wait ends (immediately when every deliverable event arrived,
  else after the 1 s quiet wait); the row reports the median run's value, the mean of the
  two middle runs (by ms) when the number of runs is even. C allocations of the cgo
  libsecp256k1 builds are not counted (libsecp256k1 does not allocate per event).
- **Teardown (untimed).** Unsubscribe/cancel, close the client, then `runtime.GC()` so
  every run starts from a collected heap.
- **Correctness.** `accepted_ok` per HARNESS.md "Correctness" (expired events optional,
  ambiguous optional), decided after the run: the (count, XOR) must equal one of the
  correct outcomes (expired all in or all out, each ambiguous event either way), and that
  outcome gives `ambiguous_accepted` / `expired_accepted`. When it matches none, one more
  run (untimed, not reported) records the delivered ids to count those two. Every run must deliver the same count and id XOR as the first;
  a run that doesn't makes the row an error (goNDK's does).
- **Runtime.** Default `GOGC`, no `GOMEMLIMIT`, `GOMAXPROCS` = cores, `GOAMD64=v1`; the
  environment can override them and `runtime` records them.

## Clients

| client | library | API | verify | crypto | websocket |
|---|---|---|---|---|---|
| `go-nostr-relay` | github.com/nbd-wtf/go-nostr | `RelayConnect` + `Relay.Subscribe` (Events / EndOfStoredEvents channels) | library + harness `CheckID()` | btcec/v2 on dcrd secp256k1/v4 (pure Go) | coder/websocket |
| `go-nostr-relay-libsecp256k1` (variant) | same, `-tags libsecp256k1` | same | same | libsecp256k1 C (vendored, cgo) | coder/websocket |
| `go-nostr-pool` (variant) | same | `SimplePool.SubscribeManyNotifyEOSE` | same | btcec | coder/websocket |
| `go-nostr-fetchmany` (variant) | same | `SimplePool.FetchMany` (channel closes after EOSE) | same | btcec | coder/websocket |
| `fiatjaf-nostr-relay` | fiatjaf.com/nostr | `RelayConnect` + `Relay.Subscribe` | library + harness `CheckID()` | btcec/v2 on dcrd secp256k1/v4 | coder/websocket |
| `fiatjaf-nostr-relay-libsecp256k1` (variant) | same, `-tags libsecp256k1` | same | same | libsecp256k1 C (vendored, cgo) | coder/websocket |
| `fiatjaf-nostr-pool` (variant) | same | `Pool.SubscribeManyNotifyEOSE` | same | btcec | coder/websocket |
| `fiatjaf-nostr-fetchmany` (variant) | same | `Pool.FetchMany` | same | btcec | coder/websocket |
| `orly-ws` | git.smesh.lol/orly/pkg/nostr (mleku's ORLY) | `ws.RelayConnect` + `Client.Subscribe` | library + harness id check (`GetIDBytes()`) | in-tree p256k1 (pure Go + amd64 asm) | gorilla/websocket |
| `nmilat-read` | github.com/ohstr/nmilat | `client.Connect` + `SubscribeWithID` + `Read()` | explicit `nip01.Event.Verify(WithoutPowCheck())` | flokicoin crypto/schnorr (btcec fork) on dcrd secp256k1/v4 | gorilla/websocket |
| `nmilat-subscribe` (variant) | same | `client.Connect` + `Connection.Subscribe` | same | same | gorilla/websocket |
| `gondk-relaymanager` | github.com/niallyoung/goNDK | `RelayManager.Subscribe` + `Subscription.Receive` / `EOSE()` | explicit `ValidateSignature()` + harness id check | btcec/v2 | nhooyr.io/websocket |

Versions come from the binary's build info at run time; licenses (SPDX, from each
module's LICENSE) are in `licenses.go`. Each row's `notes` repeats the caveats below.

### go-nostr (github.com/nbd-wtf/go-nostr, MIT)

- Verifies every event by default (`Relay.AssumeValid` is false) in the read loop,
  before dispatch. `CheckSignature()` hashes the event body and verifies the signature
  against that hash, but **never compares it with the `id` field**: an event with a
  forged id and a valid signature over its body passes. The harness also calls the
  library's `Event.CheckID()` on each delivered event.
- Default crypto is btcec/v2 (pure Go); the `libsecp256k1` build tag switches to the
  libsecp256k1 C sources vendored in the module (cgo), about 3x faster here.
- JSON: gjson splits the envelope, easyjson decodes the event (a `sonic` build tag
  swaps in a bytedance/sonic envelope parser; not benchmarked, see below).
- Accepts the ambiguous U+0000 event (its serializer escapes control characters as
  `\u00XX`) and delivers expired events. `"sig":""` events fail hex/sig parsing and are
  dropped quietly.
- Each event is dispatched on its own goroutine (`dispatchEvent`), the EOSE waits for
  those, so events arrive out of order but all before the EOSE.
- Pool rows: a new pool per run, `EnsureRelay` untimed; the pool deduplicates by id.

### fiatjaf.com/nostr (Unlicense)

The successor module of go-nostr (by the same author), same design.

- Verifies by default (`RelayOptions.AssumeValid` false); `VerifySignature()` recomputes
  the id into a copy of the event and checks the signature against it, never comparing
  with the received id: the harness also calls `Event.CheckID()`.
- **Fake EOSE after 7 s by default**: `SubscriptionOptions.MaxWaitForEOSE` defaults to
  7 s, after which it dispatches an EOSE and drops stored events still queued. A full
  download here takes ~8 s with btcec on this (loaded) machine, so an app with the
  defaults would lose events. The harness disables it (`math.MaxInt64`, as the library
  documents); notes say so.
- `InfoLogger` writes to stderr by default (one line per rejected event); the harness
  sends it to `io.Discard`.
- **Rejects the ambiguous event**: its serializer escapes only `"`, `\`, `\n`, `\r`,
  `\t` and writes U+0000 verbatim (the letter of NIP-01), so the signature does not
  verify. That is an allowed outcome.

### orly (git.smesh.lol/orly/pkg/nostr, AGPL-3.0-or-later)

mleku's ORLY relay project, whose `pkg/nostr` is a full client library (`ws` client,
binary-field event type, its own JSON codec, its own pure-Go secp256k1 `p256k1` with
amd64 assembly).

- Verifies by default (`Client.AssumeValid` false) with `event.E.Verify()`, which
  checks the signature against the **id as received** and recomputes the id only when
  the signature fails. So the harness also compares the library's `GetIDBytes()`
  (canonical hash) with the id.
- That check has a blind spot: when the signature fails, `Verify` recomputes the id,
  **overwrites `ev.ID`** with it and returns valid if the signature matches the computed
  id (`pkg/nostr/encoders/event/verify.go:23-34`; `ws.Client` reads only the bool). So an
  event with a wrong `id` field but a signature over its true id is delivered under the
  corrected id, and `GetIDBytes() == ev.ID` passes. No corpus event has that shape (the
  accepted XOR would show it); it is the library's behaviour, named in `notes`.
- **Its JSON decoder does not decode `\uXXXX` escapes**: a content of
  `"... 🙄"` on the wire is delivered as those 12 literal characters, not the
  emoji. 2,381 valid events of the corpus carry escaped emoji (some clients send them
  that way); their canonical hash then differs from the id, so with the id check they
  are dropped: `accepted` 27,233 of 29,613, `accepted_ok: false`. Without the id check
  orly would deliver them, with mangled text.
- Accepts the ambiguous event (it keeps `\u0000` verbatim too, so the hash matches).
- Logs at `info` to stderr by default (one line per bad signature); the harness sets
  `lol.SetLogLevel("off")`.

### nmilat (github.com/ohstr/nmilat, Unlicense)

A 2026 Go SDK (relay engine + `relay/client`).

- The client never verifies; its docs say to call `Verify()` on every event. The
  harness does (`verify: explicit`) with `Verify(nip01.WithoutPowCheck())`: format, id
  recomputed and compared, signature. Plain `Verify()` also runs a NIP-13 proof-of-work
  check (a second id hash) on events with a `nonce` tag; that is outside the job and the
  documented option turns it off.
- **`Connection.Subscribe` deadlocks on a large download**: the read loop forwards every
  message both to the subscription's channel and to the connection-wide `incoming`
  channel (buffer 10,240) that only `Read()` drains, and its docs say not to mix the two
  styles. After 10,240 messages the read loop blocks forever and the EOSE never comes
  (`nmilat-subscribe`, a variant row, times out after ~9,000 events). The headline
  `nmilat-read` uses the other documented style, `SubscribeWithID` + `Read()`.
- The read loop also blocks on an unbuffered `Errors()` channel, so the harness drains
  it from setup on.
- gorilla/websocket with `EnableCompression: true` (the relay does not negotiate it);
  encoding/json via `Conn.ReadJSON`.

### goNDK (github.com/niallyoung/goNDK, MIT)

Self-described "VERY EARLY R&D". Included because it has a relay client and verify.

- Delivers unverified; `ValidateSignature()` verifies against `sha256(Serialize())`
  without comparing the id, so the harness also compares that hash with the id.
- **Drops events**: the read loop hands each event to the subscription with a
  non-blocking send on an unbuffered channel, so every event that arrives while the
  app's callback is busy is lost. It delivers ~1,500 of 29,613 events, a different set
  each run, so the row is an error.

## Not included

- **github.com/shota3506/go-nostr** (v0.0.1, May 2023): unmaintained minimal client
  (goNDK's client follows its design).
- **github.com/stackerstan/go-nostr, studiokaiji/go-nostr, MuseTechnology/go-nostr**:
  old forks of nbd-wtf/go-nostr.
- **realy.lol, orly.dev, next.orly.dev** (mleku): earlier homes of the code now in
  git.smesh.lol/orly (benchmarked as `orly-ws`).
- **github.com/nostr-net/rely**: a relay framework, no client.
- **rust-nostr / nostr-sdk Go bindings**: none exist (its bindings are Python, Kotlin,
  Swift, JavaScript).
- **go-nostr `sonic` build tag** (bytedance/sonic envelope parser): an optional parser
  of the same library, not added as a variant.
