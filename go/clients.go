package main

import (
	"context"
	"regexp"
)

// clientDef is one row family: a library driven through one of its APIs.
type clientDef struct {
	ID        string
	Library   string
	Module    string // Go module whose resolved version is reported
	API       string
	Websocket string // "{module}" is replaced with that module's resolved version
	Crypto    string // same
	Verify    string // library | explicit | harness
	Notes     string
	Variant   bool
	Tag       string // binary the client runs in: "" = libbench, else libbench-<Tag>
}

// opens holds each client's setup function, registered by the lib_*.go files that
// this build includes (a libsecp256k1 build holds only one of the two libraries).
var opens = map[string]func(ctx context.Context, url string) (session, error){}

const (
	gonostrMod = "github.com/nbd-wtf/go-nostr"
	fiatjafMod = "fiatjaf.com/nostr"
	orlyMod    = "git.smesh.lol/orly"
	nmilatMod  = "github.com/ohstr/nmilat"
	gondkMod   = "github.com/niallyoung/goNDK"

	btcecCrypto  = "btcec/v2 {github.com/btcsuite/btcd/btcec/v2} on dcrd secp256k1/v4 {github.com/decred/dcrd/dcrec/secp256k1/v4} (pure Go)"
	coderWS      = "coder/websocket {github.com/coder/websocket}"
	gorillaWS    = "gorilla/websocket {github.com/gorilla/websocket}"
	secpVendored = "libsecp256k1 (C, 0.5-era sources vendored in the module, compiled in with cgo; build tag libsecp256k1)"

	gonostrIDNote = "Verification is the library's default (Relay.AssumeValid=false): CheckSignature hashes the event body and verifies the signature, but never compares that hash with the id field, so the harness also calls the library's Event.CheckID() on every delivered event. JSON: gjson envelope split + easyjson event decoder"
	fiatjafNote   = "Verification is the library's default (RelayOptions.AssumeValid=false): VerifySignature recomputes the id into a copy of the event and verifies the signature against it, never comparing it with the id field, so the harness also calls the library's Event.CheckID() on every delivered event. SubscriptionOptions.MaxWaitForEOSE is disabled (math.MaxInt64): its 7 s default dispatches a fake EOSE and drops the stored events still queued. InfoLogger (stderr by default, one line per rejected event) is sent to io.Discard. JSON: gjson envelope split + easyjson event decoder"
	poolNote      = "A new pool per run, connected untimed with EnsureRelay; the pool deduplicates by id (a map per subscription)"
)

var clients = []*clientDef{
	{
		ID: "go-nostr-relay", Library: "go-nostr", Module: gonostrMod,
		API:       "RelayConnect + Relay.Subscribe (Events / EndOfStoredEvents channels)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: gonostrIDNote,
	},
	{
		ID: "go-nostr-relay-libsecp256k1", Library: "go-nostr", Module: gonostrMod,
		API:       "RelayConnect + Relay.Subscribe (Events / EndOfStoredEvents channels)",
		Websocket: coderWS, Crypto: secpVendored, Verify: "library",
		Notes: "Built with the library's libsecp256k1 build tag. " + gonostrIDNote,
		Tag:   "secp-gonostr",
	},
	{
		ID: "go-nostr-pool", Library: "go-nostr", Module: gonostrMod,
		API:       "SimplePool.SubscribeManyNotifyEOSE (one relay; events channel + EOSE channel)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: poolNote + ". " + gonostrIDNote, Variant: true,
	},
	{
		ID: "go-nostr-fetchmany", Library: "go-nostr", Module: gonostrMod,
		API:       "SimplePool.FetchMany (one relay; channel closes after EOSE)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: poolNote + "; EOSE = the channel closing. " + gonostrIDNote, Variant: true,
	},
	{
		ID: "fiatjaf-nostr-relay", Library: "fiatjaf.com/nostr", Module: fiatjafMod,
		API:       "RelayConnect + Relay.Subscribe (Events / EndOfStoredEvents channels)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: fiatjafNote,
	},
	{
		ID: "fiatjaf-nostr-relay-libsecp256k1", Library: "fiatjaf.com/nostr", Module: fiatjafMod,
		API:       "RelayConnect + Relay.Subscribe (Events / EndOfStoredEvents channels)",
		Websocket: coderWS, Crypto: secpVendored, Verify: "library",
		Notes: "Built with the library's libsecp256k1 build tag. " + fiatjafNote,
		Tag:   "secp-fiatjaf",
	},
	{
		ID: "fiatjaf-nostr-pool", Library: "fiatjaf.com/nostr", Module: fiatjafMod,
		API:       "Pool.SubscribeManyNotifyEOSE (one relay; events channel + EOSE channel)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: poolNote + ". " + fiatjafNote, Variant: true,
	},
	{
		ID: "fiatjaf-nostr-fetchmany", Library: "fiatjaf.com/nostr", Module: fiatjafMod,
		API:       "Pool.FetchMany (one relay; channel closes after EOSE)",
		Websocket: coderWS, Crypto: btcecCrypto, Verify: "library",
		Notes: poolNote + "; EOSE = the channel closing. " + fiatjafNote, Variant: true,
	},
	{
		ID: "orly-ws", Library: "orly (git.smesh.lol/orly/pkg/nostr)", Module: orlyMod,
		API:       "ws.RelayConnect + Client.Subscribe (Events / EndOfStoredEvents channels)",
		Websocket: gorillaWS, Crypto: "orly's in-tree p256k1 (mleku's p256k1.mleku.dev: pure Go + amd64 assembly)",
		Verify: "library",
		Notes: "Verification is the library's default (Client.AssumeValid=false): event.E.Verify checks the signature against the id as received and recomputes the id only when the signature fails, so the harness also compares the library's GetIDBytes() (canonical hash) with the id of every delivered event. Its JSON decoder keeps \\uXXXX escapes verbatim in content and tags (a corpus event whose content holds \\uD83D\\uDE44 is delivered with those 12 characters, not the emoji), so for the ~2,400 events sent with escaped emoji the canonical hash does not match the id and the harness drops them; without that id check the library would deliver them, with their text mangled. " +
			"lol log level set to \"off\" (default \"info\" prints one stderr line per rejected event). JSON: the library's own envelope and event decoders (binary id/pubkey/sig fields)",
	},
	{
		ID: "nmilat-subscribe", Library: "nmilat", Module: nmilatMod,
		API:       "client.Connect + Connection.Subscribe (typed events channel, closed at EOSE)",
		Websocket: gorillaWS, Crypto: "flokicoin crypto/schnorr {github.com/flokiorg/go-flokicoin} (btcec fork) on dcrd secp256k1/v4 {github.com/decred/dcrd/dcrec/secp256k1/v4} (pure Go)",
		Verify:  "explicit",
		Notes:   "Diagnostic: the common path its docs give. Its read loop also pushes every message onto the connection's shared incoming channel (buffer 10240), which nobody reads in this style (its docs say not to mix it with Read()), so after 10240 messages the read loop blocks for good and EOSE never arrives. The client delivers events unverified; the harness calls nip01.Event.Verify() (format, id recomputed and compared, BIP-340 signature, NIP-13 proof of work when a nonce tag is present) on each. The harness drains Connection.Errors() (unbuffered; the read loop blocks on it otherwise). EOSE = the events channel closing. JSON: encoding/json (Conn.ReadJSON)",
		Variant: true,
	},
	{
		ID: "nmilat-read", Library: "nmilat", Module: nmilatMod,
		API:       "client.Connect + Connection.SubscribeWithID + Read() (every message of the connection)",
		Websocket: gorillaWS, Crypto: "flokicoin crypto/schnorr {github.com/flokiorg/go-flokicoin} (btcec fork) on dcrd secp256k1/v4 {github.com/decred/dcrd/dcrec/secp256k1/v4} (pure Go)",
		Verify: "explicit",
		Notes:  "The style its docs give for long-lived subscriptions, and the one that works for a large download (Connection.Subscribe deadlocks after 10240 messages, see nmilat-subscribe). The client delivers events unverified; the harness calls nip01.Event.Verify() (format, id recomputed and compared, BIP-340 signature, NIP-13 proof of work when a nonce tag is present) on each. The connection's read loop blocks on an unbuffered Errors() channel, so the harness drains it. JSON: encoding/json (Conn.ReadJSON)",
	},
	{
		ID: "gondk-relaymanager", Library: "goNDK", Module: gondkMod,
		API:       "client.NewRelayManager + Connect + Subscribe + Subscription.Receive (callback) / EOSE() channel",
		Websocket: "nhooyr.io/websocket {nhooyr.io/websocket}", Crypto: btcecCrypto, Verify: "explicit",
		Notes: "R&D-stage library. Its read loop hands each event to the subscription with a non-blocking send on an unbuffered channel, so every event that arrives while the app is still busy with the previous one is dropped: it delivers a different, small subset on every run. The client delivers events unverified; the harness calls Event.ValidateSignature() (signature over sha256(Serialize()), id field not compared) and compares sha256(Serialize()) with the id on each. JSON: encoding/json envelope + easyjson event decoder",
	},
}

var versionRef = regexp.MustCompile(`\{([^}]+)\}`)

func init() {
	for _, c := range clients {
		expand := func(s string) string {
			return versionRef.ReplaceAllStringFunc(s, func(m string) string { return moduleVersion(m[1 : len(m)-1]) })
		}
		c.Websocket = expand(c.Websocket)
		c.Crypto = expand(c.Crypto)
	}
}
