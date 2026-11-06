//go:build libsecp256k1 && secp_gonostr

package main

// Built with go-nostr's libsecp256k1 build tag: CheckSignature runs the libsecp256k1
// C sources vendored in the module (cgo). fiatjaf.com/nostr vendors the same C
// sources, so the two cannot be linked into one cgo binary: each gets its own.
const buildTag = "secp-gonostr"
