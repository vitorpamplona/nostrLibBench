package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// session is one client instance connected to the relay (setup is untimed).
type session interface {
	// subscribe is called right after t0. It asks the library for the subscription
	// with one filter {"limit": limit} and arranges for every event the library
	// delivers (verified first if the client's verify is "explicit") to reach
	// h.event / h.eventHex and for the EOSE to reach h.eose. Delivery may happen on
	// other goroutines after subscribe returns.
	subscribe(h *collector, limit int) error
	// close tears the subscription and the client down (untimed).
	close()
}

// collector is what the library delivers to: the app side of a run. Per event it
// only counts, XORs the id and notes the time (HARNESS.md "Fairness" 5); which of the
// ambiguous and expired events were delivered is worked out after the run from the
// count and XOR (expect.classify), or, when they match no correct outcome, from the
// ids an extra untimed diagnostic run records.
type collector struct {
	mu       sync.Mutex
	accepted int
	xor      [32]byte
	last     time.Time // time of the last accepted event
	eoseAt   time.Time
	eose     bool
	cpuEnd   time.Duration // process CPU time at max(EOSE, last accepted event)
	err      error
	full     int // valid + every ambiguous: the most a correct library can deliver
	done     chan struct{}
	doneOnce sync.Once
	record   [][32]byte // the accepted ids, kept only in the untimed diagnostic run
	keep     bool
}

func cpuTime() time.Duration {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

func peakRSSMb() float64 {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return float64(ru.Maxrss) / 1024 // Linux: KiB
}

func (c *collector) event(id [32]byte) {
	now := time.Now()
	c.mu.Lock()
	c.accepted++
	for i := range c.xor {
		c.xor[i] ^= id[i]
	}
	if c.keep {
		c.record = append(c.record, id)
	}
	c.last = now
	if c.eose {
		// Delivered after the EOSE (e.g. verified on another goroutine): the run
		// now ends here, and so does its CPU time.
		c.cpuEnd = cpuTime()
	}
	complete := c.eose && c.accepted >= c.full
	c.mu.Unlock()
	if complete {
		c.doneOnce.Do(func() { close(c.done) })
	}
}

// eventHex takes the id as the library holds it, a hex string.
func (c *collector) eventHex(id string) {
	var b [32]byte
	if len(id) != 64 {
		c.event(b) // counted, and the XOR will not match
		return
	}
	_, _ = hex.Decode(b[:], []byte(id))
	c.event(b)
}

func (c *collector) endOfStored() {
	now := time.Now()
	cpu := cpuTime()
	c.mu.Lock()
	if c.eose {
		c.mu.Unlock()
		return
	}
	c.eose = true
	c.eoseAt = now
	c.cpuEnd = cpu
	complete := c.accepted >= c.full
	c.mu.Unlock()
	if complete {
		c.doneOnce.Do(func() { close(c.done) })
	}
}

func (c *collector) fail(err error) {
	c.mu.Lock()
	if c.err == nil {
		c.err = err
	}
	c.mu.Unlock()
	c.doneOnce.Do(func() { close(c.done) })
}

type runResult struct {
	ms, cpuMs float64
	accepted  int
	xor       [32]byte
	ids       [][32]byte // diagnostic run only
}

type expect struct {
	valid    int
	validXor [32]byte
	ambSet   map[[32]byte]struct{}
	expSet   map[[32]byte]struct{}
	expXor   [32]byte
}

func hex32(s string) ([32]byte, error) {
	var b [32]byte
	if len(s) != 64 {
		return b, fmt.Errorf("bad id %q", s)
	}
	_, err := hex.Decode(b[:], []byte(s))
	return b, err
}

func newExpect(w workload) (*expect, error) {
	e := &expect{valid: w.ValidEvents, ambSet: map[[32]byte]struct{}{}, expSet: map[[32]byte]struct{}{}}
	var err error
	if e.validXor, err = hex32(w.ValidIDXor); err != nil {
		return nil, err
	}
	for _, s := range w.AmbiguousIDs {
		b, err := hex32(s)
		if err != nil {
			return nil, err
		}
		e.ambSet[b] = struct{}{}
	}
	for _, s := range w.ExpiredIDs {
		b, err := hex32(s)
		if err != nil {
			return nil, err
		}
		e.expSet[b] = struct{}{}
		for i := range e.expXor {
			e.expXor[i] ^= b[i]
		}
	}
	return e, nil
}

// classify applies HARNESS.md "Correctness: the accepted set": the run's (count, XOR)
// must equal one of the correct outcomes (the expired events all delivered or all
// dropped, each ambiguous event either way). ok reports whether it does, and amb / exp
// say how many ambiguous and expired events that outcome holds.
func (e *expect) classify(r runResult) (amb, exp int, ok bool) {
	ambs := make([][32]byte, 0, len(e.ambSet))
	for id := range e.ambSet {
		ambs = append(ambs, id)
	}
	if len(ambs) > 8 {
		ambs = ambs[:8]
	}
	nExp := len(e.expSet)
	for mask := 0; mask < 1<<len(ambs); mask++ {
		var ambXor [32]byte
		n := 0
		for i, id := range ambs {
			if mask&(1<<i) == 0 {
				continue
			}
			n++
			for j := range ambXor {
				ambXor[j] ^= id[j]
			}
		}
		for _, expIn := range []bool{true, false} {
			want, count := e.validXor, e.valid+n
			if !expIn {
				count -= nExp
				for j := range want {
					want[j] ^= e.expXor[j]
				}
			}
			for j := range want {
				want[j] ^= ambXor[j]
			}
			if count == r.accepted && want == r.xor {
				if expIn {
					return n, nExp, true
				}
				return n, 0, true
			}
		}
	}
	return 0, 0, false
}

// countIn counts how many of ids are in set (diagnostic run).
func countIn(ids [][32]byte, set map[[32]byte]struct{}) int {
	n := 0
	for _, id := range ids {
		if _, ok := set[id]; ok {
			n++
		}
	}
	return n
}

const quietWait = time.Second

// oneRun is one subscription, end to end (HARNESS.md "A run").
// keepIDs makes it the untimed diagnostic run, which also records the accepted ids.
func oneRun(c *clientDef, url string, w workload, e *expect, timeout time.Duration, keepIDs bool) (res runResult, err error) {
	// 1. setup, untimed
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	s, err := opens[c.ID](ctx, url)
	cancel()
	if err != nil {
		return res, fmt.Errorf("setup: %w", err)
	}

	h := &collector{
		full: e.valid + len(e.ambSet),
		done: make(chan struct{}),
		keep: keepIDs,
	}

	// 2. timed
	cpu0 := cpuTime()
	t0 := time.Now()
	if err := s.subscribe(h, w.Events); err != nil {
		closeWithin(s, 5*time.Second)
		return res, fmt.Errorf("subscribe: %w", err)
	}

	// 3. end: EOSE seen and either every event a correct library can deliver has
	// arrived, or nothing arrived for quietWait.
	deadline := t0.Add(timeout)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
wait:
	for {
		select {
		case <-h.done:
			break wait
		case now := <-tick.C:
			h.mu.Lock()
			eose, lastAt := h.eose, h.eoseAt
			if h.last.After(lastAt) {
				lastAt = h.last
			}
			h.mu.Unlock()
			if eose && now.Sub(lastAt) >= quietWait {
				break wait
			}
			if now.After(deadline) {
				if !eose {
					h.mu.Lock()
					n := h.accepted
					h.mu.Unlock()
					// No teardown: a library stuck here may never return from it.
					return res, fmt.Errorf("timeout: no EOSE within %s (%d events delivered)", timeout, n)
				}
				break wait
			}
		}
	}

	h.mu.Lock()
	if h.err != nil {
		err = h.err
	}
	end := h.eoseAt
	if h.last.After(end) {
		end = h.last
	}
	res = runResult{
		ms:       float64(end.Sub(t0).Nanoseconds()) / 1e6,
		cpuMs:    float64((h.cpuEnd - cpu0).Nanoseconds()) / 1e6,
		accepted: h.accepted,
		xor:      h.xor,
		ids:      h.record,
	}
	h.mu.Unlock()

	// 4. teardown, untimed
	closeWithin(s, 5*time.Second)
	runtime.GC()
	return res, err
}

func closeWithin(s session, d time.Duration) {
	done := make(chan struct{})
	go func() {
		defer func() { _ = recover() }()
		s.close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(d):
		fmt.Fprintln(os.Stderr, "   teardown did not finish in", d)
	}
}

func f64(v float64) *float64 { return &v }
func intp(v int) *int        { return &v }

func runChild(c *clientDef, o opts, wls []workload) {
	if c.Tag != buildTag || opens[c.ID] == nil {
		fatal(fmt.Errorf("client %s runs in libbench-%s, this binary is built as %q", c.ID, c.Tag, buildTag))
	}
	var rows []row
	write := func() {
		b, err := json.Marshal(rows)
		if err != nil {
			fatal(err)
		}
		if o.childOut == "" {
			os.Stdout.Write(append(b, '\n'))
			return
		}
		if err := os.WriteFile(o.childOut, b, 0o644); err != nil {
			fatal(err)
		}
	}
	for _, w := range wls {
		r, fatalRun := runWorkload(c, o, w)
		rows = append(rows, r)
		write()
		if fatalRun {
			// A timed-out run may leave the library wedged: stop this process here,
			// the parent reports the remaining workloads as failed.
			os.Exit(0)
		}
	}
}

func runWorkload(c *clientDef, o opts, w workload) (r row, fatalRun bool) {
	r = baseRow(c, w)
	defer func() {
		if p := recover(); p != nil {
			r.Errors++
			r.Error = strp(fmt.Sprintf("panic: %v", p))
			nullTimings(&r)
		}
	}()
	e, err := newExpect(w)
	if err != nil {
		r.Errors++
		r.Error = strp(err.Error())
		return r, false
	}
	url := o.relay + "/" + w.Name
	timeout := time.Duration(o.set.TimeoutMs) * time.Millisecond

	var first *runResult
	var measured []runResult
	runs := 0
	var mStart time.Time
	for {
		warm := runs < o.set.WarmupRuns
		if !warm && len(measured) == 0 {
			mStart = time.Now()
		}
		res, err := oneRun(c, url, w, e, timeout, false)
		runs++
		if err != nil {
			r.Errors++
			r.Error = strp(fmt.Sprintf("run %d: %v", runs, err))
			nullTimings(&r)
			fmt.Fprintf(os.Stderr, "   %-9s run %d: %v\n", w.Name, runs, err)
			return r, isTimeout(err)
		}
		fmt.Fprintf(os.Stderr, "   %-9s run %-2d %s %9.1f ms  cpu %9.1f ms  accepted %d\n",
			w.Name, runs, map[bool]string{true: "warm", false: "    "}[warm], res.ms, res.cpuMs, res.accepted)
		if first == nil {
			rr := res
			first = &rr
			setAccepted(&r, e, res)
			r.FirstRunMs = f64(res.ms)
		} else if res.accepted != first.accepted || res.xor != first.xor {
			r.Errors++
			r.Error = strp(fmt.Sprintf("run %d delivered a different set than the first run (%d events, xor %x; first: %d, %x)",
				runs, res.accepted, res.xor, first.accepted, first.xor))
			nullTimings(&r)
			return r, false
		}
		if warm {
			r.WarmupRuns++
			continue
		}
		measured = append(measured, res)
		n := len(measured)
		if n >= o.set.MaxRuns || (n >= o.set.MinRuns && time.Since(mStart) >= time.Duration(o.set.MinTimeMs)*time.Millisecond) {
			break
		}
	}

	// The timed runs only count and XOR. When the set matches no correct outcome, one
	// more run (untimed, not reported) records the ids to tell how many of the
	// ambiguous and expired events the library delivered.
	diagTimeout := false
	if !r.AcceptedOK {
		d, derr := oneRun(c, url, w, e, timeout, true)
		if derr == nil {
			r.AmbiguousAccepted = intp(countIn(d.ids, e.ambSet))
			r.ExpiredAccepted = intp(countIn(d.ids, e.expSet))
		} else {
			fmt.Fprintf(os.Stderr, "   %-9s diagnostic run: %v\n", w.Name, derr)
		}
		diagTimeout = isTimeout(derr)
	}

	r.Runs = len(measured)
	ms := make([]float64, len(measured))
	cpus := make([]float64, len(measured))
	for i, m := range measured {
		ms[i] = round1(m.ms)
		cpus[i] = m.cpuMs
	}
	r.RunMs = ms
	sorted := append([]float64(nil), ms...)
	sort.Float64s(sorted)
	sort.Float64s(cpus)
	med := median(sorted)
	r.MedianMs = f64(round1(med))
	r.MinMs = f64(sorted[0])
	r.P90Ms = f64(round1(nearestRank(sorted, 0.9)))
	r.EventsPerS = f64(round1(float64(w.Events) / (med / 1000)))
	r.UsPerEvent = f64(round3(med * 1000 / float64(w.Events)))
	r.CPUMs = f64(round1(median(cpus)))
	r.PeakRssMb = f64(round1(peakRSSMb()))
	r.FirstRunMs = f64(round1(*r.FirstRunMs))
	return r, diagTimeout
}

func isTimeout(err error) bool {
	return err != nil && strings.HasPrefix(err.Error(), "timeout")
}

// setAccepted fills the accepted-set fields from the first run. When the set matches
// no correct outcome, ambiguous_accepted / expired_accepted stay null (runWorkload
// fills them from a diagnostic run).
func setAccepted(r *row, e *expect, res runResult) {
	r.Accepted = intp(res.accepted)
	r.AcceptedXor = strp(hex.EncodeToString(res.xor[:]))
	amb, exp, ok := e.classify(res)
	r.AcceptedOK = ok
	r.AmbiguousAccepted, r.ExpiredAccepted = nil, nil
	if ok {
		r.AmbiguousAccepted = intp(amb)
		r.ExpiredAccepted = intp(exp)
	}
}

func nullTimings(r *row) {
	r.FirstRunMs, r.MedianMs, r.MinMs, r.P90Ms = nil, nil, nil, nil
	r.EventsPerS, r.UsPerEvent, r.CPUMs = nil, nil, nil
	r.RunMs = []float64{}
	r.Runs = 0
	r.AcceptedOK = false
	r.PeakRssMb = f64(round1(peakRSSMb()))
}

func median(s []float64) float64 {
	n := len(s)
	if n == 0 {
		return 0
	}
	if n%2 == 0 {
		return (s[n/2-1] + s[n/2]) / 2
	}
	return s[n/2]
}

func nearestRank(s []float64, q float64) float64 {
	i := int(q*float64(len(s))+0.999999) - 1
	if i < 0 {
		i = 0
	}
	if i >= len(s) {
		i = len(s) - 1
	}
	return s[i]
}

func round1(v float64) float64 { return float64(int64(v*10+0.5)) / 10 }
func round3(v float64) float64 { return float64(int64(v*1000+0.5)) / 1000 }
