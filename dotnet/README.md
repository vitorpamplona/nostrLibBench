# nostrLibBench: .NET harness

The C#/.NET side of [nostrLibBench](../HARNESS.md): which .NET Nostr client library gets a
relay's events through its own WebSocket client, JSON parser and signature verification
fastest.

```bash
./dotnet/run.sh --quick --workloads smoke --relay ws://127.0.0.1:7807
./dotnet/run.sh --clients nnostr,nostr-sdk --workloads all
./dotnet/run.sh --list
```

`run.sh` installs the pinned .NET SDK (10.0.403, the current LTS; runtime 10.0.14) into
`.tools/dotnet/` with the official `dotnet-install.sh` when it is missing, restores every
project in locked mode from its `packages.lock.json`, builds Release into `dotnet/out/`, and
runs the orchestrator from the repo root. It takes every HARNESS.md flag.

## Layout

- `Common/Harness.cs`: the shared driver (one run, warm-ups, measured runs, the accepted-set
  check, the result row). Compiled into every client binary.
- `Clients/<Library>/`: one project per library, each with its own `packages.lock.json`, so
  every library resolves its dependencies (NBitcoin.Secp256k1, Newtonsoft.Json,
  Websocket.Client …) as an app that uses only it would. In one shared project NuGet would
  unify them (NostrNet needs NBitcoin.Secp256k1 4.0, the others pin 3.1.x).
- `Bench/`: the orchestrator. It asks each client binary for its clients (`--list-json`),
  then runs every client on every workload in a **fresh process** (`--child <client>`), one
  after another, and writes `results/dotnet.json`. A child that crashes or hangs still gets
  a row with `error` set.

## How it measures

- **A run** (HARNESS.md "A run"): setup, untimed: a new client object, connected and the
  connection awaited where the API allows. Timed: `t0` (`Stopwatch`) right before the
  subscription call with the filter `{"limit": <events>}`; each delivered event is counted
  and its id XORed into the accepted set (after the library's own verify for `explicit`
  rows); `t_end = max(EOSE time, last accepted event)`. The driver waits until EOSE and
  either the accepted set is complete or no event came for 1 s. Teardown, untimed.
- **CPU**: `Environment.CpuUsage.TotalTime` (getrusage: user + system, all threads, µs
  resolution; the same counter as `Process.TotalProcessorTime` without its 10 ms ticks),
  from `t0` to the moment the run completed (read in the callback that completes it). A run
  whose set never completes (it ends after 1 s without events) takes the CPU read at EOSE,
  or, if events came after the EOSE, the one read at the last of them, so the idle second
  is never counted.
- **Memory**: `peak_rss_mb` is `VmHWM` from `/proc/self/status` at the end of the child.
- **Runtime**: .NET defaults, recorded in `runtime`: Workstation GC, concurrent GC,
  tiered compilation with dynamic PGO, Release builds, framework-dependent apphost.
- Library console output goes to the orchestrator's stderr, never into the results.

## Clients

| client | library | API | verify | crypto | websocket |
|---|---|---|---|---|---|
| `nostr-client` | Nostr.Client 2.1.0 (Marfusios) | `NostrWebsocketClient.Streams.EventStream/EoseStream` (Rx) | explicit | NBitcoin.Secp256k1 3.1.6 (pure C#) | Websocket.Client 5.3 |
| `nnostr` | NNostr.Client 0.0.55 (Kukks) | `NostrClient.CreateSubscription` + `EventsReceived`/`EoseReceived` | library | NBitcoin.Secp256k1 3.1.6 | ClientWebSocket |
| `nnostr-subscribeforevents` (variant) | NNostr.Client | `SubscribeForEvents(filters, stopWhenEoseSent: true)` (IAsyncEnumerable) | library | same | same |
| `nostrnet` | NostrNet 0.1.0-preview8 (Galaxoid-Labs) | `RelayClient.SubscribeAsync` (IAsyncEnumerable) | library | NBitcoin.Secp256k1 4.0.0 | ClientWebSocket |
| `nostrnet-pool` (variant) | NostrNet | `RelayPool.SubscribeAsync` | library | same | same |
| `nostr-sdk` | Nostr.Sdk 0.45.1 (rust-nostr via UniFFI) | `Client.StreamEvents(…, ExitOnEose)` + `Next()` | library | libsecp256k1 (C, rust secp256k1 0.30) | tokio-tungstenite 0.28 (Rust) |
| `blockcore-nostr-client` | Blockcore.Nostr.Client 2.0.2 | same as Nostr.Client (a fork) | explicit | NBitcoin.Secp256k1 3.1.1 | Websocket.Client 4.6.1 |
| `nostra` | Nostra 0.0.5 (F#, lontivero) | `Client.ConnectToRelayAsync` + `StartListening` + `Subscribe` | library | NBitcoin.Secp256k1 3.1.0 | ClientWebSocket |
| `nostrsharp` | NostrSharp 1.0.1 | `NSRelay` + `OnEvent`/`OnEose` + `SendFilter` | explicit | NBitcoin.Secp256k1 3.1.1 | ClientWebSocket |

Per library (each row's `notes` has the details):

- **Nostr.Client** does not verify. The harness calls `NostrEvent.ComputeId()` (re-serializes
  the event with Newtonsoft.Json) against `Id`, then `IsSignatureValid()` (BIP-340 over
  `Id`; it does not check the id itself). Websocket.Client's reconnects and its 1-minute
  "no message" reconnect timer are turned off. Kind-specific subclasses parse their content
  (metadata JSON) during deserialization. Correct on smoke.
- **Blockcore.Nostr.Client** is a fork of Nostr.Client with the same receive path, its own
  (older) dependency pins. Correct on smoke.
- **NNostr** verifies every event before raising it (`Verify()`: id from its own string-built
  serialization, then BIP-340), parsing frames with System.Text.Json on one processing task.
  Correct. Its `SubscribeForEvents(…, stopWhenEoseSent: true)` helper is **buggy**: when the
  EOSE arrives it races `Task.WhenAny(eose, read)` and drops the events still buffered in its
  channel, so each run loses a different handful (981–983 of 995 on smoke): reported as an
  error row.
- **NostrNet** verifies every event in `RelayClient` (id + BIP-340) and drops failures. Its
  id serializer is `Utf8JsonWriter` with `JavaScriptEncoder.UnsafeRelaxedJsonEscaping`, which
  still escapes characters outside the BMP (emoji) as `🚀`, so every valid event
  whose content or tags hold an emoji gets a wrong id and is **dropped** (82 of 995 on smoke,
  2,395 of 29,614 on all): `accepted_ok: false`. Its top-level `NostrClient.SubscribeAsync`
  hides the EOSE, so the harness uses `RelayClient` (headline) and `RelayPool` (variant).
- **Nostr.Sdk** is rust-nostr's nostr-sdk 0.45.2 (nostr 0.45.3) behind UniFFI bindings:
  parsing (serde_json), verification (libsecp256k1) and the WebSocket all run in Rust on a
  tokio runtime; each event crosses the FFI as an async `Next()` call and an object handle.
  It verifies every event, drops the NIP-40-expired events (allowed) and accepts the
  ambiguous U+0000 event (serde_json writes it as `\u0000`). Correct. `AddRelay` takes the
  capabilities explicitly in C#; the harness passes `RelayCapabilities.Read()` (the Rust
  default is read + write; `ReqTarget.Auto` sends the REQ to read relays either way).
  `StreamEvents` runs through rust-nostr's fixed internal channels (the relay's notification
  broadcast, then the stream's own channel), whose sizes the bindings do not expose.
- **Nostra** (F#) verifies every event in its receive loop and hands the callback a
  `Result`: `Error` for invalid or undecodable events. Correct. License file: GPL-2.0.
- **NostrSharp** (last release 2023) does not verify. `NEvent.IsVerified()` checks BIP-340
  over an id it recomputes (`GetId`) but never compares that id with `Id`. The harness hashes
  once with the library's id function (the private `NEvent.GetId`, by reflection), compares
  it with `Id`, then checks the signature over `Id` with the library's
  `NPub.FromHex(pubkey).IsHexSignatureValid(sig, id)`, the call `IsVerified` makes. One id
  computation per event is also the only one that works: `GetId` serializes a temporary
  `NEventSign` that shares the event's `Tags` list and disposes it, which **clears the
  event's tags**, so any later `GetId` (or `IsVerified`) hashes an empty tag list (the
  harness used to call both and accepted only the 18 tagless events of smoke). `NTag` holds a
  key and at most 4 values, so a valid event with a longer tag (zap-request `relays` tags,
  ...) gets a wrong id and is **rejected** (31 of 995 on smoke, 964 accepted):
  `accepted_ok: false`. Its relay replaces the REQ's subscription id with its own
  Guid, its dispatch loop sleeps 200 ms whenever its queue is empty, and it splits every
  frame on `,` to find the message type.

## Not included

- **NostrLib** (NuSocial, `0.1.33-alpha`, last published January 2023): an alpha package of
  an abandoned app, never released as stable.
- **Nostra.CSharp**: a thin C# wrapper over Nostra; Nostra itself is benchmarked.
- **NostrNet.Client** (`NostrClient`): its `SubscribeAsync` does not expose the EOSE, so a run
  cannot end; the layers below it (`RelayClient`, `RelayPool`) are benchmarked.
- **NostrServices.Client**, **DotNut.Nostr**, **LightningEnable.\***, **Nostrfi.\***: HTTP API
  wrappers, payment tools or relay internals, not relay clients.
