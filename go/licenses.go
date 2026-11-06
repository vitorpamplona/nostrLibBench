package main

// licenses maps each benchmarked module to the SPDX id of its own LICENSE file (or
// the license its README names), read from the module cache
// (go list -m -f '{{.Dir}}' <module>). Versions come from the binary's build info.
// Re-check this table when bumping a module in go.mod.
var licenses = map[string]string{
	"github.com/nbd-wtf/go-nostr": "MIT",
	"fiatjaf.com/nostr":           "Unlicense",
	"git.smesh.lol/orly":          "AGPL-3.0-or-later",
	"github.com/ohstr/nmilat":     "Unlicense",
	"github.com/niallyoung/goNDK": "MIT",
}
