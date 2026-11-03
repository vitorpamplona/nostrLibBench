package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"

	"github.com/niallyoung/goNDK/client"
	"github.com/niallyoung/goNDK/event"
)

// github.com/niallyoung/goNDK: the RelayManager delivers events unverified. The
// harness calls event.Event.ValidateSignature(), which hashes Serialize() and
// verifies the signature against that hash without comparing it to the id field,
// so the harness also compares sha256(Serialize()) (the library's own
// serialization) with the id.

func init() {
	opens["gondk-relaymanager"] = openGondk
}

type gondkSession struct {
	rm      *client.RelayManager
	cancel  context.CancelFunc
	rcancel context.CancelFunc
}

func openGondk(ctx context.Context, url string) (session, error) {
	rm := client.NewRelayManager(url)
	// The context given to Connect is used by the read loop for as long as it runs.
	cctx, cancel := context.WithCancel(context.Background())
	if err := rm.Connect(cctx); err != nil {
		cancel()
		return nil, err
	}
	return &gondkSession{rm: rm, cancel: cancel}, nil
}

func gondkIDOK(e *event.Event) bool {
	if e.ID == nil || len(*e.ID) != 64 {
		return false
	}
	sum := sha256.Sum256(e.Serialize())
	var buf [64]byte
	hex.Encode(buf[:], sum[:])
	return string(buf[:]) == *e.ID
}

func (s *gondkSession) subscribe(h *collector, limit int) error {
	sub, err := s.rm.Subscribe(context.Background(), []client.Filter{{Limit: limit}})
	if err != nil {
		return err
	}
	go func() {
		<-sub.EOSE()
		h.endOfStored()
	}()
	// Receive sends the REQ and calls back for every event until its ctx is done.
	rctx, rcancel := context.WithCancel(context.Background())
	s.rcancel = rcancel
	go func() {
		_ = sub.Receive(rctx, func(_ context.Context, e *event.Event) {
			if e == nil {
				return
			}
			if ok, err := e.ValidateSignature(); !ok || err != nil {
				return
			}
			if !gondkIDOK(e) {
				return
			}
			h.eventHex(*e.ID)
		})
	}()
	return nil
}

func (s *gondkSession) close() {
	if s.rcancel != nil {
		s.rcancel() // Receive sends CLOSE
	}
	_ = s.rm.Close()
	s.cancel()
}
