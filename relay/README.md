# blast-relay

The relay every nostrLibBench harness connects to. It answers every `REQ` with every event of
a workload, in corpus order, as `["EVENT",<sub>,<event>]` text frames, then `["EOSE",<sub>]`.

```bash
cargo build --release
target/release/blast-relay --corpus ../.corpus --port 7777 [--workload all] [--verbose]
```

- The workload is the URL path: `ws://127.0.0.1:7777/notes` streams `.corpus/notes.ndjson`,
  `/` streams `--workload` (default `all`).
- Each event is the exact bytes of its corpus line. A REQ assembles the frames (header,
  `["EVENT",`, the subscription id as the client sent it, `,`, the event, `]`) into a 1 MiB
  buffer and hands it to the kernel with one `write`, so the relay uses about 1 ms of CPU per
  27 MB stream and is otherwise blocked on the client's socket.
- Filters are ignored, nothing is stored, no `permessage-deflate`. `EVENT` gets an accepting
  `OK`, `CLOSE`/`AUTH` are ignored, pings get pongs. A plain HTTP GET gets a NIP-11 document.
- One thread per connection; any number of REQs per connection, each answered in full before
  the next frame is read.
- `--verbose` logs each REQ's server-side time: how long the client took to drain the stream.

Dependencies: `sha1_smol` and `base64` for the handshake, `serde_json` for the manifest and
the client's messages.
