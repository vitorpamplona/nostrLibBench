# nostrLibBench: Python harness

`bench.py` follows [`../HARNESS.md`](../HARNESS.md): same flags, run definition, accepted-set
check and output schema. Output goes to `results/python.json`.

```bash
python/run.sh --relay ws://127.0.0.1:7777            # full run (the top-level run.sh passes --relay)
python/run.sh --quick                                 # smoke test
python/run.sh --clients nostr-sdk-stream,monstr-subscribe --workloads all,notes
python/run.sh --list
```

`run.sh` creates `.venv` (git-ignored) with `python3.13` (override with `PYTHON=`) and installs
`requirements.txt`, a `pip freeze` of the whole environment (every library and every
transitive dependency pinned). It reinstalls when that file changes. Some pins are sdists
(electrum-aionostr 0.1.0, nostrclient, monstr, ...), so it does not insist on wheels.

`nostrj` installs a top-level `nostr` package, the same name as python-nostr (PyPI `nostr`).
It goes into its own overlay, `pip install --no-deps --target .venv/overlays/nostrj` from
`requirements-nostrj.txt`, and only the nostrj client's process puts that overlay first on
`sys.path`. Its dependencies are pinned in `requirements.txt`.

## How it measures

The orchestrator re-executes `bench.py --child <client>` once per client (a fresh CPython per
library, HARNESS.md "Isolation"), clients one after another; the child prints its rows as one
`@@ROWS` JSON line. A child that crashes still gets a row (`error`), and a child that wedges is
killed after a budget of every run's timeout.

Each client is one `run(ctx)` function, sync or async (async ones get a new event loop per run
with `asyncio.run`, so library state bound to a loop never leaks between runs):

1. **Setup, untimed.** A new client object; where the API connects explicitly, connect and
   wait for the connection.
2. **Timed.** `ctx.begin()` reads `time.perf_counter()` and the process CPU time
   (`resource.getrusage(RUSAGE_SELF)`, user + system of every thread) right before the
   library's subscription call, with one filter `{"limit": <events>}`. The app callback /
   loop calls `ctx.event(id)` for each delivered event (after the explicit verify for
   `verify: explicit` rows), taking the id from the library's own event object, and
   `ctx.eose()` when the app learns of the EOSE. Ids are appended to a list; the XOR is
   computed after the run.
3. **End.** `t_end = max(EOSE time, last event time)`. The run is complete when EOSE has
   been seen and the accepted count is either `valid + ambiguous` or (with no expired event
   delivered so far) `valid - expired + ambiguous`; CPU time is read at that moment.
   Otherwise the harness waits for 1 s without events after EOSE; then CPU is the reading
   taken at EOSE (every Python client here delivers everything before or at EOSE, so the
   idle second is not counted). A run with no EOSE within `--timeout-ms` is an error and
   ends that client.
4. **Teardown, untimed.** Close the subscription and the client.

`first_run_ms` is the first warm-up run; `cpu_ms` the median CPU time of the measured runs;
`peak_rss_mb` is `ru_maxrss` at the end of the child (over warm-up and every run). Every
measured run must deliver the same id set as the first, else the row gets an error.

Library logging is left at Python's defaults (records at WARNING and above are formatted),
but logging's last-resort handler writes to `/dev/null`, so nostr-tools' traceback per invalid
event costs what it costs without flooding the output.

## Clients

`verify` as in HARNESS.md. Licenses come from each package's metadata / LICENSE file.
secp256k1 bindings: `secp256k1` 0.14.0 (rustyrussell/secp256k1-py, cffi, bundled libsecp256k1),
`coincurve` 21.0.0 (cffi, bundled libsecp256k1 at 1ad5185), `electrum-ecc` 0.0.8 (ctypes,
bundled `libsecp256k1.so`), and libsecp256k1 through the Rust `secp256k1` crate inside
nostr-sdk's UniFFI library. No Python Nostr library here verifies in pure Python.

| client | package | version | license | verify | crypto | websocket |
|---|---|---|---|---|---|---|
| `nostr-sdk-notifications` | nostr-sdk (rust-nostr) | 0.45.1 | MIT | library | libsecp256k1 via Rust secp256k1 | tokio-tungstenite (Rust) |
| `nostr-sdk-stream` (variant) | nostr-sdk | 0.45.1 | MIT | library | same | same |
| `nostr-sdk-fetch` (variant) | nostr-sdk | 0.45.1 | MIT | library | same | same |
| `pynostr-callback` | pynostr | 0.7.0 | MIT | library | coincurve | tornado 6.6 |
| `pynostr-pool` (variant) | pynostr | 0.7.0 | MIT | library | coincurve | tornado 6.6 |
| `python-nostr` | nostr (jeffthibault) | 0.0.2 | MIT | library | secp256k1-py | websocket-client 1.9 (thread) |
| `nostrj` | nostrj (python-nostr fork) | 0.1.2 | MIT | library | secp256k1-py | websocket-client 1.9 (thread) |
| `monstr-subscribe` | monstr | 0.1.9 | MIT | explicit | secp256k1-py | aiohttp 3.14 |
| `monstr-query` (variant) | monstr | 0.1.9 | MIT | explicit | secp256k1-py | aiohttp 3.14 |
| `aionostr` | aionostr | 0.20.0 | BSD-3-Clause | explicit | coincurve | websockets 17 |
| `electrum-aionostr` | electrum-aionostr | 0.1.0 | BSD-3-Clause | library | electrum-ecc | aiohttp 3.14 |
| `nostr-tools` | nostr-tools (bigbrotr) | 1.4.1 | MIT | library | secp256k1-py | aiohttp 3.14 |
| `nostrclient` | nostrclient | 1.0.5 | Unlicense | explicit | secp256k1-py | websocket-client 1.9 (thread) |
| `basic-nostr` | basic-nostr | 1.1.0 | MIT | harness | coincurve | websockets 17 |

**nostr-sdk** (rust-nostr's UniFFI bindings). Headline: `subscribe(ReqTarget.single(url,
[filter]))` and `notifications().next()` (the stream `handle_notifications` wraps) until the
`MESSAGE` notification carrying the EOSE; events come as `NEW_EVENT`. Relay I/O, JSON, id and
signature checks run in Rust on tokio threads; every notification crosses the FFI (a
`NEW_EVENT` and a `MESSAGE` per EVENT frame) and the id is read with `Event.id().to_hex()`, so
per-event cost is mostly the FFI round-trip. The EOSE only arrives as a `MESSAGE`, so the app
calls `as_enum()` (another FFI call) on every `MESSAGE` notification to spot it. One
`asyncio.timeout` bounds the whole loop (not a timer per notification). The client's notification channel is a broadcast
channel that drops what a slow consumer has not read, so it is sized at twice the workload.
Verifies every event (new `Client` and in-memory state per run), drops expired (NIP-40) events,
accepts the ambiguous one.

Variants: `stream_events` + `ClientEventStream.next()` (the documented short-lived streaming
API) **silently loses events** with a Python consumer: when the consumer falls behind the Rust
reader, the stream ends (no error item, no EOSE distinction) after a few thousand events. A
0.1 ms sleep per event gives 2,558 of 29,548; under machine load with no sleep, runs delivered
12,979, 9,073 or 18,704. `notification_channel_size` does not change it, so it looks like the
relay's internal notification broadcast channel lagging. Hence it is a diagnostic row, and the
row errors when a run's set differs from the first. `fetch_events` (fetch-all, collected in
Rust, so it does not lag) needs `max_events` raised to the workload size: its default cap fails
`all` with `too many fetched events`.

**pynostr.** `RelayManager.add_relay(message_callback=...)`, `add_subscription_on_all_relays`,
`run_sync()` (tornado). Verifies every event's signature (coincurve) against an id it recomputes:
`Event.from_dict` drops the wire id ("id is ignore, as it will be computed") and nothing compares
the two. In `pynostr-callback` the callback gets the JSON list, so the harness recomputes the id
with pynostr's own `Event.from_dict(...).id` (a second hash), drops a mismatch and counts the
wire id. In `pynostr-pool` the wire id is not reachable (the pool's `EventMessage` holds only the
rebuilt `Event`), so the id counted is the recomputed one and notes say so. It does not survive the corpus: coincurve raises
`Signature must be 64 bytes long` on the first `"sig":""` event, the exception escapes
`_on_message`, and `Relay.connect` logs it and drops the connection before EOSE. Both rows
report that error. Also: the default `RelayManager(timeout=2)` wraps the whole read loop, not
just the connect, so the harness uses `timeout=0`; the connect is lazy (inside the timed part);
each frame is `json.loads`-ed three times.

**python-nostr** (PyPI `nostr` 0.0.2, January 2023, unmaintained but the most-installed
name). README idiom: `add_relay`, `add_subscription`, `open_connections`, `publish_message`
of the REQ, then the `message_pool` queues, read from the main thread (5 ms poll when empty;
events and EOSE come from one websocket thread in order). The relay thread verifies every
event (signature checked with secp256k1-py against a recomputed id) and matches filters; a
`"sig":""` raises inside the callback and websocket-client swallows it. `verify()` never compares
the recomputed id with the wire id the `Event` keeps, so the harness does, with the library's own
`Event.compute_id` (a second hash, as `verify()` returns only a bool). **Bug:** `Event()`
does `created_at or int(time.time())`, so the valid event with `created_at: 0` gets a wrong
id and is rejected: `accepted_ok: false`.

**nostrj** (fork of python-nostr, 2026). Same structure; `add_relay` sleeps 1 s (untimed), the
REQ is sent by a queue-worker thread, verification is wrapped in a try/except that rejects
anything that raises. Each run leaves a daemon queue-worker thread polling every 0.1 s
(library design). Its `Event` has no id field (the `id` property recomputes it on every access)
and `Relay` builds it without the wire id, which the delivered message does not carry: the wire
id is never compared and cannot be (named in `notes`). Correct on the corpus.

**monstr.** `Client.run()` (aiohttp) and `subscribe(filters, eose_func=...)`: monstr buffers a
subscription's stored events and hands them to `eose_func` as one list at EOSE (per-event
handlers only see events after EOSE). It does not verify received events; the harness calls
`Event.is_valid()` (signature against the event's id field, secp256k1-py) and checks the id with
monstr's own `Event.serialize()` + sha256. `Client(eose_timeout=None)` (the default fakes an EOSE
after 10 s). `Client.run()` GETs the relay's NIP-11 document over HTTP before the websocket
connect, in the untimed setup (no option turns it off). Variant `monstr-query`: `await
client.query(filter)`, which polls for completion every 100 ms; its timeout (`query_timeout`,
default 10 s, raises `QueryTimeoutException`) is raised to the run timeout.

**aionostr.** `Manager([url]).get_events(filter)` async generator (websockets), with dedup. No
verification on receive; `Event.verify()` recomputes the id and checks the signature against
it (coincurve) but never compares it with the event's id field, so the harness compares
`Event.compute_id(...)` too: two hashes per event, as `verify()` keeps its id to itself. **Bug:** the same `created_at or int(time.time())` as
python-nostr, so the `created_at: 0` event is rejected: `accepted_ok: false`.

**electrum-aionostr** (Electrum's fork of aionostr). `Manager([url]).get_events(filter)`
(aiohttp), `Manager(connect_timeout=10)` (default 5 s); `Event()` recomputes the id and verifies
the signature on construction (electrum-ecc). `Event.from_json` drops the wire id ("we don't
validate the original self.id, just always overwrite it"), so it is never compared and is not
reachable from the delivered `Event` (named in `notes`). `Relay._receive_messages` sleeps 5 ms before each message (a CPU-DOS
mitigation, ~150 s for the `all` workload) and 5 s after any exception, and an event without a
valid signature raises (`ValueError: missing sig`): the 1,547 unsigned events cost 5 s each,
so a run of `all` exceeds any sane timeout (error row). `notes` (4 invalid events) takes ~36 s.

**nostr-tools** (bigbrotr, PyPI `nostr-tools`, not the JS library). `Client(Relay(url))`,
`stream_events(client, Filter(limit=...))` (aiohttp), ending at EOSE. `Event.from_dict`
validates on construction: formats, recomputed id, signature (secp256k1-py). On failure it
"unescapes" `\n`, `\"`, ... in content and tags and validates again (a second verify for every
invalid event), and `stream_events` logs each failure with a traceback. **Bug:** it rejects any
content or tag containing the six characters `\u0000` (meant to catch NUL, but it tests the
escaped text): the real U+0000 of the ambiguous event passes, and a valid kind 4550 event whose
content is escaped JSON containing `\u0000` is rejected: `accepted_ok: false`. It also rejects
empty tags (`[]`), which this corpus does not contain.

**nostrclient** (PyPI `nostrclient` 1.0.5). `Relay(url).connect()`, then a `Subscription` made
with the id `relay.subscribe` would give it, `sub.on("EVENT", ...)` and `relay.on("EOSE" +
subid, ...)`, then `relay.subscribe(filter, sub=sub)`: the emitter thread (0.1 s queue poll)
drops events that have no listener yet, so the listeners go on before the REQ. No verification
on receive; the harness builds `nostrclient.event.Event` from the dict, compares its id with
the event's and calls `verify()` (signature against the id): two hashes per event, as `Event.id`
is a property that recomputes on every access. Subscription dedup keeps ids in a list (linear
scan, reset at 10,000), which makes it slow. Each `Relay` starts a non-daemon emitter thread
(`while True`) that nothing stops, so one more is left polling after every run.

**basic-nostr** ("intentionally tiny", 2026). Fetch-only: `read_events_from_relays(relays,
limit)` returns a deduplicated list sorted by `created_at` after EOSE. Its `connect_to_relays`
always passes an SSL context, which `websockets` rejects for `ws://` URLs, so the harness opens
the `websockets` connection itself (as `connect_to_relays` does, minus `ssl`) and passes the
`(url, websocket)` pair. No verification of fetched events (its private signature check is
sig-only and used for NIP-17 seals): `verify: harness`, id via `json.dumps` (compact,
`ensure_ascii=False`) + sha256 and signature via coincurve.

## Not included

- **nostrkey** 0.3.5 (identity SDK for "OpenClaw AI entities"): its `RelayClient` refuses
  loopback and private addresses (SSRF guard in `validate_relay_url`), so it cannot reach the
  local relay; it also pins `websockets<17`, which conflicts with the other clients' venv.
- **nostr-protocol** 0.35.0 (2024): rust-nostr's old protocol-only bindings, no relay client;
  superseded by nostr-sdk.
- **nostr-r3drun3**, **nostrfastr**, **nostrmq**, **nostr-mirror**, **nostr-bots**,
  **nostr-bot**, **edwh-nostr-messagebus**, **nostr-dvm**, **nostr-dev**, **bluenostr**:
  forks of, or apps/frameworks on top of, libraries above (python-nostr, pynostr, monstr,
  aionostr, nostr-sdk), not separate client cores.
- **nostrpy** (a CLI), **nostr-relay** / **nostrd** (relays), **bitchat-nostr** (a BitChat
  transport), **plume-nostr** (file signing on electrum-aionostr): not general client libraries.
