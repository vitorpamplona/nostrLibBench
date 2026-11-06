// Command libbench is the Go harness of nostrLibBench (see ../HARNESS.md).
//
// The parent process runs every client in a fresh child process: it re-executes
// itself (or, for clients that need a build tag such as libsecp256k1, the sibling
// binary built with that tag) with --child, one client at a time, never in parallel.
// The child writes its rows to a file the parent names, so nothing a library prints
// on stdout can corrupt them, and a child that crashes or hangs still gets rows with
// `error` set.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

type settings struct {
	WarmupRuns int `json:"warmup_runs"`
	MinRuns    int `json:"min_runs"`
	MinTimeMs  int `json:"min_time_ms"`
	MaxRuns    int `json:"max_runs"`
	TimeoutMs  int `json:"timeout_ms"`
}

type workload struct {
	Name         string   `json:"name"`
	File         string   `json:"file"`
	Events       int      `json:"events"`
	Bytes        int64    `json:"bytes"`
	ValidEvents  int      `json:"valid_events"`
	ValidIDXor   string   `json:"valid_id_xor"`
	AmbiguousIDs []string `json:"ambiguous_ids"`
	ExpiredIDs   []string `json:"expired_ids"`
}

type manifest struct {
	Fingerprint string     `json:"fingerprint"`
	Workloads   []workload `json:"workloads"`
}

type row struct {
	Client            string    `json:"client"`
	Library           string    `json:"library"`
	Version           string    `json:"version"`
	License           string    `json:"license"`
	API               string    `json:"api"`
	Websocket         string    `json:"websocket"`
	Crypto            string    `json:"crypto"`
	Verify            string    `json:"verify"`
	Notes             string    `json:"notes"`
	Variant           bool      `json:"variant"`
	Workload          string    `json:"workload"`
	Events            int       `json:"events"`
	Bytes             int64     `json:"bytes"`
	Accepted          *int      `json:"accepted"`
	AcceptedXor       *string   `json:"accepted_xor"`
	AmbiguousAccepted *int      `json:"ambiguous_accepted"`
	ExpiredAccepted   *int      `json:"expired_accepted"`
	AcceptedOK        bool      `json:"accepted_ok"`
	Errors            int       `json:"errors"`
	Error             *string   `json:"error"`
	WarmupRuns        int       `json:"warmup_runs"`
	Runs              int       `json:"runs"`
	FirstRunMs        *float64  `json:"first_run_ms"`
	MedianMs          *float64  `json:"median_ms"`
	MinMs             *float64  `json:"min_ms"`
	P90Ms             *float64  `json:"p90_ms"`
	RunMs             []float64 `json:"run_ms"`
	EventsPerS        *float64  `json:"events_per_s"`
	UsPerEvent        *float64  `json:"us_per_event"`
	CPUMs             *float64  `json:"cpu_ms"`
	PeakRssMb         *float64  `json:"peak_rss_mb"`
	BaseRssMb         *float64  `json:"base_rss_mb"`
	AllocBytes        *int64    `json:"alloc_bytes"`
}

type output struct {
	Harness           string         `json:"harness"`
	Language          string         `json:"language"`
	Runtime           string         `json:"runtime"`
	Host              map[string]any `json:"host"`
	Settings          settings       `json:"settings"`
	Relay             string         `json:"relay"`
	CorpusFingerprint string         `json:"corpus_fingerprint"`
	Results           []row          `json:"results"`
}

type opts struct {
	relay, corpus, out string
	workloads, clients []string
	set                settings
	list, quick, child bool
	childOut           string
}

func splitList(s string) []string {
	var r []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			r = append(r, p)
		}
	}
	return r
}

func parseFlags() opts {
	var o opts
	var wl, cl string
	fs := flag.NewFlagSet("libbench", flag.ExitOnError)
	fs.StringVar(&o.relay, "relay", "ws://127.0.0.1:7777", "relay base URL (the harness appends /<workload>)")
	fs.StringVar(&o.corpus, "corpus", ".corpus", "corpus directory")
	fs.StringVar(&o.out, "out", "results/go.json", "output JSON file")
	fs.StringVar(&wl, "workloads", "all", "comma-separated workloads")
	fs.StringVar(&cl, "clients", "", "comma-separated client ids (default: every client)")
	fs.IntVar(&o.set.WarmupRuns, "warmup-runs", 2, "warm-up runs per client and workload")
	fs.IntVar(&o.set.MinRuns, "min-runs", 5, "minimum measured runs")
	fs.IntVar(&o.set.MinTimeMs, "min-time-ms", 10000, "minimum measured time")
	fs.IntVar(&o.set.MaxRuns, "max-runs", 30, "maximum measured runs")
	fs.IntVar(&o.set.TimeoutMs, "timeout-ms", 300000, "per-run timeout")
	fs.BoolVar(&o.quick, "quick", false, "smoke test: warmup-runs 1, min-runs 2, min-time-ms 0")
	fs.BoolVar(&o.list, "list", false, "print client ids and exit")
	fs.BoolVar(&o.child, "child", false, "internal: run one client in this process")
	fs.StringVar(&o.childOut, "child-out", "", "internal: where the child writes its rows")
	_ = fs.Parse(os.Args[1:])
	if fs.NArg() > 0 {
		fatal(fmt.Errorf("unexpected arguments: %v", fs.Args()))
	}
	explicit := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	if o.quick {
		if !explicit["warmup-runs"] {
			o.set.WarmupRuns = 1
		}
		if !explicit["min-runs"] {
			o.set.MinRuns = 2
		}
		if !explicit["min-time-ms"] {
			o.set.MinTimeMs = 0
		}
	}
	if o.set.MinRuns < 1 {
		o.set.MinRuns = 1
	}
	if o.set.MaxRuns < o.set.MinRuns {
		o.set.MaxRuns = o.set.MinRuns
	}
	if o.set.WarmupRuns < 0 {
		o.set.WarmupRuns = 0
	}
	o.relay = strings.TrimRight(o.relay, "/")
	o.workloads = splitList(wl)
	o.clients = splitList(cl)
	return o
}

func main() {
	o := parseFlags()
	if o.list {
		for _, c := range clients {
			fmt.Println(c.ID)
		}
		return
	}
	man, err := loadManifest(o.corpus)
	if err != nil {
		fatal(err)
	}
	wls, err := selectWorkloads(man, o.workloads)
	if err != nil {
		fatal(err)
	}
	sel, err := selectClients(o.clients)
	if err != nil {
		fatal(err)
	}
	if o.child {
		if len(sel) != 1 {
			fatal(errors.New("--child needs exactly one client"))
		}
		runChild(sel[0], o, wls)
		return
	}
	runParent(o, man, wls, sel)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "libbench:", err)
	os.Exit(2)
}

func loadManifest(dir string) (*manifest, error) {
	b, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("%w (build the corpus with: python3 corpus/prepare.py)", err)
	}
	var m manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func selectWorkloads(m *manifest, names []string) ([]workload, error) {
	if len(names) == 0 {
		names = []string{"all"}
	}
	var r []workload
	for _, n := range names {
		found := false
		for _, w := range m.Workloads {
			if w.Name == n {
				r = append(r, w)
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("unknown workload %q", n)
		}
	}
	return r, nil
}

func selectClients(ids []string) ([]*clientDef, error) {
	if len(ids) == 0 {
		return clients, nil
	}
	var r []*clientDef
	for _, id := range ids {
		found := false
		for _, c := range clients {
			if c.ID == id {
				r = append(r, c)
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("unknown client %q (see --list)", id)
		}
	}
	return r, nil
}

// ---- parent ----

// binaryFor returns the binary that runs client c: this one, or the sibling built
// with the client's build tag (run.sh builds both into the same directory).
func binaryFor(c *clientDef) (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	if c.Tag == buildTag {
		return self, nil
	}
	name := "libbench"
	if c.Tag != "" {
		name += "-" + c.Tag
	}
	p := filepath.Join(filepath.Dir(self), name)
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("binary %s not found (built by run.sh): %w", name, err)
	}
	return p, nil
}

// tailWriter keeps the last few KB written to it (the child's stderr) while passing
// everything through, so a crash's panic message can go into the row's error.
type tailWriter struct {
	mu  sync.Mutex
	w   io.Writer
	buf []byte
}

func (t *tailWriter) Write(p []byte) (int, error) {
	t.mu.Lock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > 4096 {
		t.buf = t.buf[len(t.buf)-4096:]
	}
	t.mu.Unlock()
	return t.w.Write(p)
}

func (t *tailWriter) tail() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	lines := strings.Split(strings.TrimSpace(string(t.buf)), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); strings.HasPrefix(l, "panic:") || strings.HasPrefix(l, "fatal error:") {
			return l
		}
	}
	if len(lines) > 0 {
		return strings.TrimSpace(lines[len(lines)-1])
	}
	return ""
}

func runParent(o opts, man *manifest, wls []workload, sel []*clientDef) {
	wlNames := make([]string, len(wls))
	for i, w := range wls {
		wlNames[i] = w.Name
	}
	tmp, err := os.MkdirTemp("", "libbench-go-")
	if err != nil {
		fatal(err)
	}
	defer os.RemoveAll(tmp)

	var rows []row
	for _, c := range sel {
		fmt.Fprintf(os.Stderr, "== %s\n", c.ID)
		got, runErr := runChildProcess(c, o, wlNames, filepath.Join(tmp, c.ID+".json"))
		if runErr != nil {
			fmt.Fprintf(os.Stderr, "   %s: %v\n", c.ID, runErr)
			// The child died (panic, crash, hang): every workload it did not report fails.
			done := map[string]bool{}
			for _, r := range got {
				done[r.Workload] = true
			}
			for _, w := range wls {
				if !done[w.Name] {
					r := baseRow(c, w)
					r.Errors = 1
					r.Error = strp(runErr.Error())
					got = append(got, r)
				}
			}
		}
		rows = append(rows, got...)
	}

	out := output{
		Harness:           "go",
		Language:          "Go",
		Runtime:           runtimeDescription(),
		Host:              hostInfo(),
		Settings:          o.set,
		Relay:             o.relay,
		CorpusFingerprint: man.Fingerprint,
		Results:           rows,
	}
	if dir := filepath.Dir(o.out); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fatal(err)
		}
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		fatal(err)
	}
	if err := os.WriteFile(o.out, append(b, '\n'), 0o644); err != nil {
		fatal(err)
	}
	printSummary(rows)
	fmt.Fprintf(os.Stderr, "wrote %s\n", o.out)
}

func runChildProcess(c *clientDef, o opts, wlNames []string, outFile string) ([]row, error) {
	bin, err := binaryFor(c)
	if err != nil {
		return nil, err
	}
	args := []string{
		"--child", "--clients", c.ID, "--child-out", outFile,
		"--relay", o.relay, "--corpus", o.corpus,
		"--workloads", strings.Join(wlNames, ","),
		"--warmup-runs", fmt.Sprint(o.set.WarmupRuns),
		"--min-runs", fmt.Sprint(o.set.MinRuns),
		"--min-time-ms", fmt.Sprint(o.set.MinTimeMs),
		"--max-runs", fmt.Sprint(o.set.MaxRuns),
		"--timeout-ms", fmt.Sprint(o.set.TimeoutMs),
	}
	cmd := exec.Command(bin, args...)
	tw := &tailWriter{w: os.Stderr}
	cmd.Stderr = tw
	cmd.Stdout = os.Stderr // nothing a library prints may reach our stdout
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// Watchdog: the child enforces --timeout-ms per run itself; this only catches a
	// child stuck outside a run (connect, teardown).
	perRun := time.Duration(o.set.TimeoutMs)*time.Millisecond + 30*time.Second
	limit := time.Duration(len(wlNames)*(o.set.WarmupRuns+o.set.MaxRuns+1)) * perRun
	waitErr := make(chan error, 1)
	go func() { waitErr <- cmd.Wait() }()
	var runErr error
	select {
	case runErr = <-waitErr:
	case <-time.After(limit):
		_ = cmd.Process.Kill()
		<-waitErr
		runErr = fmt.Errorf("child process killed after %s", limit)
	}
	var got []row
	if b, err := os.ReadFile(outFile); err == nil {
		_ = json.Unmarshal(b, &got)
	}
	if runErr != nil {
		msg := fmt.Sprintf("child process failed: %v", runErr)
		if t := tw.tail(); t != "" {
			msg += ": " + t
		}
		return got, errors.New(msg)
	}
	if len(got) == 0 {
		return nil, errors.New("child process wrote no rows")
	}
	return got, nil
}

func printSummary(rows []row) {
	fmt.Fprintf(os.Stderr, "\n%-9s %-34s %-8s %8s %4s %4s %5s %10s %10s %8s %s\n",
		"workload", "client", "verify", "accepted", "amb", "exp", "ok", "median_ms", "cpu_ms", "rss_mb", "error")
	for _, r := range rows {
		fmt.Fprintf(os.Stderr, "%-9s %-34s %-8s %8s %4s %4s %5v %10s %10s %8s %s\n",
			r.Workload, r.Client, r.Verify, fmtI(r.Accepted), fmtI(r.AmbiguousAccepted), fmtI(r.ExpiredAccepted),
			r.AcceptedOK, fmtF(r.MedianMs), fmtF(r.CPUMs), fmtF(r.PeakRssMb), deref(r.Error))
	}
}

func fmtF(p *float64) string {
	if p == nil {
		return "-"
	}
	return fmt.Sprintf("%.1f", *p)
}

func fmtI(p *int) string {
	if p == nil {
		return "-"
	}
	return fmt.Sprint(*p)
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func strp(s string) *string { return &s }

func envOr(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

func runtimeDescription() string {
	goamd64 := ""
	flags := ""
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			switch s.Key {
			case "GOAMD64", "GOARM64":
				goamd64 = s.Key + "=" + s.Value
			case "-gcflags", "-ldflags", "-trimpath":
				flags += ", " + s.Key + "=" + s.Value
			}
		}
	}
	if goamd64 == "" && runtime.GOARCH == "amd64" {
		goamd64 = "GOAMD64=v1"
	}
	return fmt.Sprintf("%s %s/%s, %s, GOGC=%s, GOMEMLIMIT=%s, GOMAXPROCS=%d%s, one child process per client",
		runtime.Version(), runtime.GOOS, runtime.GOARCH, goamd64, envOr("GOGC", "100 (default)"),
		envOr("GOMEMLIMIT", "off (default)"), runtime.GOMAXPROCS(0), flags)
}

func hostInfo() map[string]any {
	cpu := ""
	if f, err := os.Open("/proc/cpuinfo"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if k, v, ok := strings.Cut(sc.Text(), ":"); ok && strings.TrimSpace(k) == "model name" {
				cpu = strings.TrimSpace(v)
				break
			}
		}
		f.Close()
	}
	osName := runtime.GOOS
	if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		osName = "Linux " + strings.TrimSpace(string(b))
	}
	return map[string]any{"cpu": cpu, "cores": runtime.NumCPU(), "os": osName}
}

// moduleVersion is the resolved version of a module, from the binary's build info.
func moduleVersion(mod string) string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			if d.Path == mod {
				if d.Replace != nil {
					return d.Replace.Version
				}
				return d.Version
			}
		}
	}
	return "unknown"
}

func baseRow(c *clientDef, w workload) row {
	return row{
		Client: c.ID, Library: c.Library, Version: moduleVersion(c.Module), License: licenses[c.Module],
		API: c.API, Websocket: c.Websocket, Crypto: c.Crypto, Verify: c.Verify, Notes: c.Notes,
		Variant: c.Variant, Workload: w.Name, Events: w.Events, Bytes: w.Bytes,
		WarmupRuns: 0, RunMs: []float64{},
	}
}
