package main

import (
	"context"
	"net/url"

	"github.com/ohstr/nmilat/nip01"
	"github.com/ohstr/nmilat/relay/client"
	"github.com/ohstr/nmilat/wire"
)

// github.com/ohstr/nmilat: relay/client delivers events unverified (its docs: "Relay
// input is untrusted, so always call Verify() before acting on an event"). The
// harness calls nip01.Event.Verify() on every delivered event: format, id
// (recomputed and compared) and BIP-340 signature, plus a NIP-13 proof-of-work check
// when the event has a nonce tag.
//
// The connection's read loop needs the app to drain Errors() (unbuffered), so the
// session does that from setup on.

func init() {
	opens["nmilat-subscribe"] = openNmilat(false)
	opens["nmilat-read"] = openNmilat(true)
}

type nmilatSession struct {
	conn   *client.Connection
	cancel context.CancelFunc
	read   bool // SubscribeWithID + Read() instead of Subscribe
}

func openNmilat(read bool) func(context.Context, string) (session, error) {
	return func(ctx context.Context, rawURL string) (session, error) {
		u, err := url.Parse(rawURL)
		if err != nil {
			return nil, err
		}
		// The context given to Connect lives as long as the connection.
		cctx, cancel := context.WithCancel(context.Background())
		conn, err := client.Connect(cctx, u)
		if err != nil {
			cancel()
			return nil, err
		}
		go func() {
			for {
				select {
				case <-conn.Errors():
				case <-conn.Closed():
					return
				}
			}
		}()
		return &nmilatSession{conn: conn, cancel: cancel, read: read}, nil
	}
}

func (s *nmilatSession) subscribe(h *collector, limit int) error {
	f := nip01.NewFilter()
	f.Limit = limit
	group := nip01.NewSubscriptionFilterGroup(f)
	if s.read {
		// The "advanced" style its docs give for long-lived subscriptions: pick the
		// id, then consume every message of the connection from Read().
		const subID = "libbench"
		in := s.conn.Read()
		go func() {
			for msg := range in {
				switch m := msg.(type) {
				case *wire.EventSubscriptionResponse:
					if m.SubscriptionID != subID || m.Event == nil || m.Event.Verify() != nil {
						continue
					}
					h.eventHex(m.Event.ID)
				case *wire.EOSESubscriptionResponse:
					if m.SubscriptionID == subID {
						h.endOfStored()
					}
				}
			}
		}()
		s.conn.SubscribeWithID(subID, group)
		return nil
	}
	// Subscribe: the common path its docs give; the events channel closes at EOSE
	// (or CLOSED, or when the connection closes).
	_, events, _ := s.conn.Subscribe(group)
	go func() {
		for ev := range events {
			if ev.Event == nil || ev.Event.Verify() != nil {
				continue
			}
			h.eventHex(ev.Event.ID)
		}
		h.endOfStored()
	}()
	return nil
}

func (s *nmilatSession) close() {
	s.conn.Close()
	s.cancel()
}
