//go:build !libsecp256k1 || secp_fiatjaf

package main

import (
	"context"
	"errors"
	"io"
	"math"
	"time"

	fnostr "fiatjaf.com/nostr"
)

// fiatjaf.com/nostr (go-nostr's successor): Relay verifies every event's signature
// unless RelayOptions.AssumeValid is set (it is not). VerifySignature recomputes the
// id into a copy of the event and verifies the signature against it, but never
// compares it with the id field, so the harness also calls Event.CheckID().
//
// Two library defaults are changed, both named in the rows' notes:
//   - SubscriptionOptions.MaxWaitForEOSE defaults to 7 s: a fake EOSE is dispatched
//     then and stored events still queued are dropped. A long download (a slow
//     machine, the btcec build under load) would be cut short, so it is disabled
//     (math.MaxInt64, as the library documents).
//   - InfoLogger writes to stderr by default and prints one line per rejected event;
//     it is sent to io.Discard, as an app that doesn't want console spam would.

var fiatjafSubOpts = fnostr.SubscriptionOptions{MaxWaitForEOSE: time.Duration(math.MaxInt64)}

func init() {
	fnostr.InfoLogger.SetOutput(io.Discard)
	opens["fiatjaf-nostr-relay"] = openFiatjafRelay
	opens["fiatjaf-nostr-relay-libsecp256k1"] = openFiatjafRelay
	opens["fiatjaf-nostr-pool"] = openFiatjafPool(false)
	opens["fiatjaf-nostr-fetchmany"] = openFiatjafPool(true)
}

type fiatjafRelay struct {
	r      *fnostr.Relay
	sub    *fnostr.Subscription
	cancel context.CancelFunc
}

func openFiatjafRelay(ctx context.Context, url string) (session, error) {
	r, err := fnostr.RelayConnect(ctx, url, fnostr.RelayOptions{})
	if err != nil {
		return nil, err
	}
	return &fiatjafRelay{r: r}, nil
}

func (s *fiatjafRelay) subscribe(h *collector, limit int) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	sub, err := s.r.Subscribe(ctx, fnostr.Filter{Limit: limit}, fiatjafSubOpts)
	if err != nil {
		return err
	}
	s.sub = sub
	go func() {
		eose := sub.EndOfStoredEvents
		for {
			select {
			case ev, ok := <-sub.Events:
				if !ok {
					return
				}
				if !ev.CheckID() {
					continue
				}
				h.event(ev.ID)
			case <-eose:
				h.endOfStored()
				eose = nil
			case reason := <-sub.ClosedReason:
				h.fail(errors.New("CLOSED: " + reason))
				return
			}
		}
	}()
	return nil
}

func (s *fiatjafRelay) close() {
	if s.sub != nil {
		s.sub.Unsub()
	}
	if s.cancel != nil {
		s.cancel()
	}
	_ = s.r.Close()
}

type fiatjafPool struct {
	pool   *fnostr.Pool
	url    string
	fetch  bool
	cancel context.CancelFunc
}

func openFiatjafPool(fetch bool) func(context.Context, string) (session, error) {
	return func(ctx context.Context, url string) (session, error) {
		pool := fnostr.NewPool()
		if _, err := pool.EnsureRelay(url); err != nil {
			pool.Close("setup failed")
			return nil, err
		}
		return &fiatjafPool{pool: pool, url: url, fetch: fetch}, nil
	}
}

func (s *fiatjafPool) subscribe(h *collector, limit int) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	filter := fnostr.Filter{Limit: limit}
	if s.fetch {
		ch := s.pool.FetchMany(ctx, []string{s.url}, filter, fiatjafSubOpts)
		go func() {
			for ie := range ch {
				if !ie.Event.CheckID() {
					continue
				}
				h.event(ie.Event.ID)
			}
			h.endOfStored()
		}()
		return nil
	}
	ch, eoseCh := s.pool.SubscribeManyNotifyEOSE(ctx, []string{s.url}, filter, fiatjafSubOpts)
	go func() {
		eose := eoseCh
		for {
			select {
			case ie, ok := <-ch:
				if !ok {
					return
				}
				if !ie.Event.CheckID() {
					continue
				}
				h.event(ie.Event.ID)
			case <-eose:
				h.endOfStored()
				eose = nil
			}
		}
	}()
	return nil
}

func (s *fiatjafPool) close() {
	if s.cancel != nil {
		s.cancel()
	}
	s.pool.Close("done")
}
