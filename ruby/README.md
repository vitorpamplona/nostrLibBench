# nostrLibBench: Ruby harness

`bench.rb` follows [`../HARNESS.md`](../HARNESS.md): same flags, timing, accepted-set check
and output schema. Output goes to `results/ruby.json`.

```bash
ruby/run.sh --relay ws://127.0.0.1:7777 --quick
ruby/run.sh --clients nostrb-rbsecp256k1 --workloads all,notes
ruby/run.sh --list
```

`run.sh` installs the gems pinned in `Gemfile.lock` into `ruby/vendor` (git-ignored) with
Bundler, again whenever the lockfile changes, then runs `bench.rb` from the repo root.
The `fast` group (`rbsecp256k1`, used by one variant row) builds against the system
libsecp256k1 (Debian/Ubuntu: `libsecp256k1-dev`; the gem's own build downloads the C
library from GitHub, which may be blocked); if it doesn't build, `run.sh` installs the
rest and that row reports the missing gem as its error.

Runtime: CRuby 3.3 as installed (this one is built without YJIT, so it runs interpreted).

## How it measures

The orchestrator starts `bench.rb --child <client> --workload <w>` in a fresh `ruby`
process per client and workload. The child calls `Bundler.setup(:default, <groups>)` with
only that client's Gemfile group, so only its library is on the load path (`nostr` and
`nostr_ruby` both define `Nostr::Client`, and `nostr_ruby` ships a top-level `bech32.rb`
that shadows the `bech32` gem). The child reports one JSON line per run; the orchestrator
waits at most `--timeout-ms` + 60 s for each line and kills a child that stops making
progress, so a hung library still gets a row.

Per run (HARNESS.md "A run"):

1. Setup, untimed: a new client object; connected where the API connects explicitly.
2. Timed: `t0 = CLOCK_MONOTONIC` right before the subscription call with the filter
   `{"limit": <events>}`. Every event the library delivers is verified as the client's
   `verify` says, then counted and its id XORed into `accepted_xor` (Integer XOR of the
   hex ids). EOSE is timestamped when it reaches the app.
3. End: `t_end = max(EOSE, last accepted event)`; the harness waits for EOSE and then for
   a complete set or 1 s without events (untimed).
4. Teardown, untimed: unsubscribe, close / stop the reactor.

`cpu_ms` is `CLOCK_PROCESS_CPUTIME_ID` (all threads) over t0..end. `peak_rss_mb` is
`VmHWM` from `/proc/self/status` at the end of the child.

A run that sees no EOSE within `--timeout-ms` (default 300 s) ends the client: the row
gets `error: "timeout: …"` with how many events had been accepted and the time per
accepted event so far, so the cost of a full run can still be read off. The pure-Ruby
verifiers need 13-70 ms per event, i.e. 7-35 minutes for the 31,161-event `all` workload,
so with the default timeout only `nostrb-rbsecp256k1` finishes `all`. To get their
timings, raise the timeout (`--timeout-ms 3000000`) and expect hours with the default run
counts, or use a small workload (`--workloads metadata` is 268 events).

## Clients

| client | library | verify | crypto | websocket |
|---|---|---|---|---|
| `nostr-client` | [nostr](https://github.com/wilsonsilva/nostr) 0.7.0 (MIT) | explicit | bip-schnorr 0.8 + ecdsa_ext (pure Ruby) | faye-websocket 0.12 on EventMachine 1.2 |
| `nostr_ruby-client` | [nostr_ruby](https://github.com/dtonon/nostr-ruby) 0.3.1 (MIT) | harness | bip-schnorr 0.8 + ecdsa_ext (pure Ruby) | faye-websocket 0.12 on EventMachine 1.2 |
| `nostrb-client` | [nostrb](https://github.com/rickhull/nostrb) 0.2.0.1 (LGPL-2.1-only) | explicit | schnorr_sig 1.2 pure (ecdsa_ext / ecdsa, pure Ruby) | async-websocket 0.30 (async 2, fibers) |
| `nostrb-rbsecp256k1` (variant) | nostrb 0.2.0.1 | explicit | libsecp256k1 (C, system lib) via rbsecp256k1 6.0 | async-websocket 0.30 |

Licenses come from each gem's LICENSE file (nostr, nostr_ruby) or gemspec (nostrb).

### `nostr-client` (wilsonsilva/nostr)

`Nostr::Client.new(logger: nil)`, `connect(Nostr::Relay.new(url:, name:))` (waits for
`:connect`), then `subscribe(filter: Nostr::Filter.new(limit:))`. The client runs an
EventMachine reactor on its own thread and emits every text frame as a raw String on
`:message`; it parses nothing. The app parses the frame (`JSON.parse`), builds a
`Nostr::Event` and, since nothing is verified by default, the harness calls
`Event#verify_signature` (signature only, bip-schnorr) and checks the id with the
library's own `Nostr::Crypto#hash_event` (a private method: SHA-256 of
`JSON.dump(event.serialize)`).

- `verify_signature` raises `Schnorr::InvalidSignatureError` on `"sig":""` (it decodes
  the signature before calling the rescuing `valid_sig?`) instead of returning false.
  The harness counts the exception as a rejection.
- `JSON.dump` writes U+0000 as `\u0000`, so the ambiguous event is accepted. Expired
  events are delivered (no NIP-40 handling).
- `Client` has no disconnect or close. Teardown unsubscribes and stops the
  process-global EventMachine reactor; the next run's `connect` starts a new one.
- event_emitter `instance_exec`s listeners on the client, so a listener's `@ivars` are
  the client's, not the caller's (a trap for apps).

### `nostr_ruby-client` (dtonon/nostr-ruby)

`Nostr::Client.new(relay: url)`, `connect` (blocks until open), `on(:event)`,
`on(:eose)`, `subscribe(filter: Nostr::Filter.new(limit:))`. The client parses frames
into `Nostr::Event` (`Event.from_message` checks field types only), but the library has
no verify function: it signs with bip-schnorr and never verifies. So `verify: harness`:
the harness checks the id as SHA-256 of `JSON.dump(event.serialize)` (the library's
serialize) and the signature with `Schnorr.valid_sig?` from bip-schnorr, the library's
own crypto dependency. `on(:event)` fires for every subscription (the event object does
not carry its subscription id). Teardown: `unsubscribe` + `close` (stops the reactor).

### `nostrb-client` and `nostrb-rbsecp256k1` (rickhull/nostrb)

`Nostrb::Client.new(url).subscribe(filter) { |hash| … }` opens a connection
(async-websocket, lazily: the handshake is inside the timed part), sends the REQ, yields
each event as a plain Hash and returns at EOSE (so EOSE reaches the app when `subscribe`
returns). Nothing is verified by default; the harness calls the library's
`Nostrb::SignedEvent.validate!` and `SignedEvent.verify(check_id: true)` (signature, then
id), the order nostrb's own relay uses, and drops events that raise.

- `validate!` caps a tag at 99 values, so it drops one **valid** event of the corpus
  (`eff6ff2f…`, a kind 9734 zap request with a 104-value relays tag): both rows are
  `accepted_ok: false` (29,613 accepted, one short).
- nostrb's JSON uses Oj when it is installed; it is not, so stdlib `json` runs.
- The gem does not declare its runtime dependency on `async-websocket` (the Gemfile adds
  it).
- async-pool logs a harmless `Attempt to unlock a mutex which is not locked` warning from
  its gardener task on every connection close; children set `CONSOLE_LEVEL=error`.
- schnorr_sig uses libsecp256k1 (via `rbsecp256k1`) whenever that gem can be required,
  else its pure-Ruby BIP-340 on ecdsa_ext/ecdsa (affine point math, ~70 ms per verify).
  `nostrb-client` runs without the `fast` group on the load path (and checks it got the
  pure implementation); `nostrb-rbsecp256k1` (variant) runs with it.

## Not included

- `nostr-zap` (sashazykov): a NIP-57 toolkit whose relay client only publishes (EVENT +
  OK), no subscriptions.
- `nwc-ruby`: a Nostr Wallet Connect client. Its `RelayConnection` (async-websocket) and
  `Event#valid_signature?` (rbsecp256k1) are generic, but it never surfaces EOSE to the app
  (it only logs it), so a subscription cannot end the way HARNESS.md needs.
- `nineteen_ninetynine`: a terminal app; its `Subscriber` is an empty stub.
- `nostrbase`: event signing/validation only, no relay client.
