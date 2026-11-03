package main

import (
	"context"
	"errors"

	"git.smesh.lol/orly/pkg/lol"
	"git.smesh.lol/orly/pkg/nostr/encoders/filter"
	"git.smesh.lol/orly/pkg/nostr/utils"
	"git.smesh.lol/orly/pkg/nostr/ws"
)

// git.smesh.lol/orly/pkg/nostr (mleku's ORLY): ws.Client verifies every event with
// event.E.Verify unless Client.AssumeValid is set (it is not). Verify checks the
// signature against the id field as received and only recomputes the id when the
// signature fails, so an event whose id does not match its body but whose signature
// is valid for that id is accepted: the harness also compares GetIDBytes() (the
// library's canonical hash) with the id.
//
// The library logs at level "info" to stderr by default, one line per rejected
// event; the harness sets lol's level to "off" (an app's logging choice).

func init() {
	lol.SetLogLevel("off")
	opens["orly-ws"] = openOrly
}

type orlySession struct {
	c      *ws.Client
	sub    *ws.Subscription
	cancel context.CancelFunc
}

func openOrly(ctx context.Context, url string) (session, error) {
	c, err := ws.RelayConnect(ctx, url)
	if err != nil {
		return nil, err
	}
	return &orlySession{c: c}, nil
}

func (s *orlySession) subscribe(h *collector, limit int) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	f := filter.New()
	lim := uint(limit)
	f.Limit = &lim
	sub, err := s.c.Subscribe(ctx, filter.NewS(f))
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
				if len(ev.ID) != 32 || !utils.FastEqual(ev.GetIDBytes(), ev.ID) {
					continue
				}
				h.event([32]byte(ev.ID))
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

func (s *orlySession) close() {
	if s.sub != nil {
		s.sub.Unsub()
	}
	if s.cancel != nil {
		s.cancel()
	}
	_ = s.c.Close()
}
