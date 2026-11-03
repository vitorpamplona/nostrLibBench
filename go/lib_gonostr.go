//go:build !libsecp256k1 || secp_gonostr

package main

import (
	"context"
	"errors"

	gonostr "github.com/nbd-wtf/go-nostr"
)

// github.com/nbd-wtf/go-nostr: Relay verifies every event's signature unless
// Relay.AssumeValid is set (it is not). CheckSignature recomputes the hash from the
// event body and verifies the signature against it, but never compares that hash
// with the id field, so the harness also calls the library's Event.CheckID().

func init() {
	opens["go-nostr-relay"] = openGonostrRelay
	opens["go-nostr-relay-libsecp256k1"] = openGonostrRelay
	opens["go-nostr-pool"] = openGonostrPool(false)
	opens["go-nostr-fetchmany"] = openGonostrPool(true)
}

type gonostrRelay struct {
	r      *gonostr.Relay
	sub    *gonostr.Subscription
	cancel context.CancelFunc
}

func openGonostrRelay(ctx context.Context, url string) (session, error) {
	r, err := gonostr.RelayConnect(ctx, url)
	if err != nil {
		return nil, err
	}
	return &gonostrRelay{r: r}, nil
}

func (s *gonostrRelay) subscribe(h *collector, limit int) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	sub, err := s.r.Subscribe(ctx, gonostr.Filters{{Limit: limit}})
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
				h.eventHex(ev.ID)
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

func (s *gonostrRelay) close() {
	if s.sub != nil {
		s.sub.Unsub()
	}
	if s.cancel != nil {
		s.cancel()
	}
	_ = s.r.Close()
}

// SimplePool: a new pool per run, connected untimed with EnsureRelay.

type gonostrPool struct {
	pool   *gonostr.SimplePool
	url    string
	fetch  bool
	cancel context.CancelFunc
}

func openGonostrPool(fetch bool) func(context.Context, string) (session, error) {
	return func(ctx context.Context, url string) (session, error) {
		pool := gonostr.NewSimplePool(context.Background())
		if _, err := pool.EnsureRelay(url); err != nil {
			pool.Close("setup failed")
			return nil, err
		}
		return &gonostrPool{pool: pool, url: url, fetch: fetch}, nil
	}
}

func (s *gonostrPool) subscribe(h *collector, limit int) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	filter := gonostr.Filter{Limit: limit}
	if s.fetch {
		// FetchMany: the channel closes once every relay sent EOSE.
		ch := s.pool.FetchMany(ctx, []string{s.url}, filter)
		go func() {
			for ie := range ch {
				if !ie.Event.CheckID() {
					continue
				}
				h.eventHex(ie.Event.ID)
			}
			h.endOfStored()
		}()
		return nil
	}
	eoseCh := make(chan struct{})
	ch := s.pool.SubscribeManyNotifyEOSE(ctx, []string{s.url}, filter, eoseCh)
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
				h.eventHex(ie.Event.ID)
			case <-eose:
				h.endOfStored()
				eose = nil
			}
		}
	}()
	return nil
}

func (s *gonostrPool) close() {
	if s.cancel != nil {
		s.cancel()
	}
	s.pool.Close("done")
}
