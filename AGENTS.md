# nostrLibBench

Which Nostr client library, in any language, gets a relay's events through its own WebSocket
client, JSON parser and signature verification fastest. A local relay (`relay/`, Rust)
streams the nostrJsonBench corpus to every `REQ` as fast as the socket takes it; one native
harness per language (`rust/`, `go/`, `jvm/`, `node/`, `python/`, …) drives each library
through its public API. `HARNESS.md` is the contract every harness keeps. See `README.md`.

## Build and test

```bash
./run.sh --quick                 # smoke run of every harness whose toolchain is installed
./run.sh --only rust,go          # a subset
```

`run.sh` builds the corpus (`corpus/prepare.py`, ~1 min the first time: it verifies every
event in pure Python), builds and starts the relay, runs the harnesses one after another and
writes `results/report.md`. There is no CI: a `--quick` run of the harnesses you touched is the
check before a push.

## Remotes and pull requests

The repo is on GitHub, `github.com/vitorpamplona/nostrLibBench`. Open a PR only when the human
you work for asks.
