//! nostrLibBench Rust harness. Follows HARNESS.md: per client and workload it re-executes
//! itself (`--child`) so every library runs in a fresh process; the child times warm-up and
//! measured runs (a new client instance per run, one subscription to EOSE each) and prints its
//! result as one JSON line, which the parent turns into a row of `results/rust.json`.

mod clients;
mod sink;

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use sink::{Expected, Sink};

mod crates {
    include!(concat!(env!("OUT_DIR"), "/crates.rs"));
}

#[derive(Clone)]
struct Args {
    relay: String,
    corpus: PathBuf,
    out: PathBuf,
    workloads: Option<Vec<String>>,
    clients: Option<Vec<String>>,
    warmup_runs: usize,
    min_runs: usize,
    min_time_ms: u64,
    max_runs: usize,
    timeout_ms: u64,
    list: bool,
    child: Option<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: libbench-rust [--relay URL] [--corpus DIR] [--out FILE] [--workloads a,b] [--clients x,y]\n\
         \x20                    [--warmup-runs N] [--min-runs N] [--min-time-ms N] [--max-runs N]\n\
         \x20                    [--timeout-ms N] [--quick] [--list]"
    );
    std::process::exit(2)
}

fn parse_args() -> Args {
    let mut a = Args {
        relay: "ws://127.0.0.1:7777".into(),
        corpus: PathBuf::from(".corpus"),
        out: PathBuf::from("results/rust.json"),
        workloads: None,
        clients: None,
        warmup_runs: 2,
        min_runs: 5,
        min_time_ms: 10_000,
        max_runs: 30,
        timeout_ms: 300_000,
        list: false,
        child: None,
    };
    let mut it = std::env::args().skip(1);
    let csv = |s: String| -> Vec<String> {
        s.split(',').map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect()
    };
    while let Some(flag) = it.next() {
        let mut val = || it.next().unwrap_or_else(|| usage());
        match flag.as_str() {
            "--relay" => a.relay = val().trim_end_matches('/').to_string(),
            "--corpus" => a.corpus = val().into(),
            "--out" => a.out = val().into(),
            "--workloads" => a.workloads = Some(csv(val())),
            "--clients" => a.clients = Some(csv(val())),
            "--warmup-runs" => a.warmup_runs = val().parse().unwrap_or_else(|_| usage()),
            "--min-runs" => a.min_runs = val().parse().unwrap_or_else(|_| usage()),
            "--min-time-ms" => a.min_time_ms = val().parse().unwrap_or_else(|_| usage()),
            "--max-runs" => a.max_runs = val().parse().unwrap_or_else(|_| usage()),
            "--timeout-ms" => a.timeout_ms = val().parse().unwrap_or_else(|_| usage()),
            "--quick" => {
                a.warmup_runs = 1;
                a.min_runs = 2;
                a.min_time_ms = 0;
            }
            "--list" => a.list = true,
            "--child" => a.child = Some(val()),
            "-h" | "--help" => usage(),
            other => {
                eprintln!("unknown flag {other}");
                usage()
            }
        }
    }
    a.max_runs = a.max_runs.max(a.min_runs).max(1);
    a
}

pub fn crate_info(name: &str) -> (String, String) {
    crates::CRATES
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, v, l)| (v.to_string(), l.to_string()))
        .unwrap_or_else(|| ("unknown".into(), "unknown".into()))
}

fn host() -> Value {
    let cpu = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
        })
        .unwrap_or_else(|| std::env::consts::ARCH.to_string());
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    let release = std::fs::read_to_string("/proc/sys/kernel/osrelease")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let os = if std::env::consts::OS == "linux" { "Linux" } else { std::env::consts::OS };
    json!({ "cpu": cpu, "cores": cores, "os": format!("{os} {release}").trim() })
}

fn load_manifest(corpus: &Path) -> Value {
    let p = corpus.join("manifest.json");
    serde_json::from_slice(
        &std::fs::read(&p)
            .unwrap_or_else(|e| panic!("{}: {e} (build it with python3 corpus/prepare.py)", p.display())),
    )
    .expect("manifest.json")
}

fn workload<'a>(manifest: &'a Value, name: &str) -> Option<&'a Value> {
    manifest["workloads"].as_array()?.iter().find(|w| w["name"] == name)
}

fn hex32(s: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).expect("hex id in manifest");
    }
    out
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn expected_of(w: &Value) -> Expected {
    let ids = |k: &str| -> Vec<[u8; 32]> {
        w[k].as_array().map(|a| a.iter().map(|v| hex32(v.as_str().unwrap())).collect()).unwrap_or_default()
    };
    Expected {
        events: w["events"].as_u64().unwrap() as usize,
        valid: w["valid_events"].as_u64().unwrap() as usize,
        valid_xor: hex32(w["valid_id_xor"].as_str().unwrap()),
        ambiguous: ids("ambiguous_ids"),
        expired: ids("expired_ids"),
    }
}

// ---------------------------------------------------------------------------------------------
// Child: one client, one workload, fresh process.

/// Process CPU time (user + system, all threads) in ms.
pub fn cpu_ms() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 * 1e3 + t.tv_usec as f64 / 1e3;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

fn peak_rss_mb() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    ru.ru_maxrss as f64 / 1024.0 // kB on Linux
}

fn emit(v: &Value) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

fn run_child(a: &Args, id: &str) {
    let wname = a.workloads.as_ref().and_then(|w| w.first()).expect("--child needs --workloads").clone();
    let manifest = load_manifest(&a.corpus);
    let w = workload(&manifest, &wname).unwrap_or_else(|| panic!("unknown workload {wname}"));
    let expected = Arc::new(expected_of(w));
    let url = format!("{}/{}", a.relay, wname);

    // Watchdog: a run that does not finish within --timeout-ms ends the process with an error
    // line (the library may be stuck in a blocking call we cannot interrupt).
    let deadline = Arc::new(AtomicU64::new(u64::MAX));
    let started = Instant::now();
    {
        let deadline = deadline.clone();
        let timeout_ms = a.timeout_ms;
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(50));
                let d = deadline.load(Ordering::Relaxed);
                if d != u64::MAX && started.elapsed().as_millis() as u64 > d {
                    emit(&json!({ "error": format!("timeout: no EOSE within {timeout_ms} ms") }));
                    std::process::exit(3);
                }
            }
        });
    }

    let mut client = match clients::make(id) {
        Ok(c) => c,
        Err(e) => {
            emit(&json!({ "error": format!("setup: {e}") }));
            return;
        }
    };

    let mut first: Option<(usize, [u8; 32])> = None;
    let mut first_run_ms: Option<f64> = None;
    let mut run_ms = Vec::new();
    let mut run_cpu = Vec::new();
    let mut result = json!({});
    let mut error: Option<String> = None;
    let mut errors = 0usize;
    let mut measured_start: Option<Instant> = None;
    let mut i = 0usize;
    loop {
        let warm = i < a.warmup_runs;
        if !warm {
            let n = run_ms.len();
            let start = *measured_start.get_or_insert_with(Instant::now);
            let enough = n >= a.min_runs && start.elapsed() >= Duration::from_millis(a.min_time_ms);
            if enough || n >= a.max_runs {
                break;
            }
        }
        let mut sink = Sink::new(expected.clone());
        deadline.store(started.elapsed().as_millis() as u64 + a.timeout_ms, Ordering::Relaxed);
        let r = client.run(&url, expected.events, &mut sink);
        deadline.store(u64::MAX, Ordering::Relaxed);
        if let Err(e) = r {
            error = Some(format!("run {}: {e}", i + 1));
            errors += 1;
            break;
        }
        let Some((ms, cpu)) = sink.finish() else {
            error = Some(format!("run {}: no EOSE", i + 1));
            errors += 1;
            break;
        };
        sink.dump();
        let set = (sink.accepted, sink.xor);
        match first {
            None => {
                first = Some(set);
                result = sink.summary();
            }
            Some(f) if f != set => {
                error = Some(format!(
                    "run {} delivered a different set ({} events, xor {}) than run 1 ({} events, xor {})",
                    i + 1,
                    set.0,
                    hex(&set.1),
                    f.0,
                    hex(&f.1)
                ));
                errors += 1;
                break;
            }
            _ => {}
        }
        if i == 0 {
            first_run_ms = Some(ms);
        }
        if !warm {
            run_ms.push(ms);
            run_cpu.push(cpu);
        }
        eprintln!(
            "  {id:<28} {wname:<9} {} {:>3}: {ms:>9.1} ms  cpu {cpu:>9.1} ms  accepted {}",
            if warm { "warm" } else { "run " },
            i + 1,
            sink.accepted
        );
        i += 1;
    }
    drop(client);
    let mut o = result;
    let m = o.as_object_mut().unwrap();
    m.insert("error".into(), json!(error));
    m.insert("errors".into(), json!(errors));
    m.insert("warmup_runs".into(), json!(a.warmup_runs.min(i)));
    m.insert("first_run_ms".into(), json!(first_run_ms));
    m.insert("run_ms".into(), json!(run_ms));
    m.insert("run_cpu_ms".into(), json!(run_cpu));
    m.insert("peak_rss_mb".into(), json!(round1(peak_rss_mb())));
    emit(&o);
}

// ---------------------------------------------------------------------------------------------
// Parent.

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = s.len();
    if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
}

fn p90(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = s.len();
    s[((n as f64 * 0.9).ceil() as usize).clamp(1, n) - 1]
}

/// Runs one child process and returns its result line (or an error object).
fn spawn_child(a: &Args, id: &str, wname: &str) -> Value {
    let exe = std::env::current_exe().expect("current_exe");
    let mut cmd = Command::new(exe);
    cmd.arg("--child")
        .arg(id)
        .args(["--workloads", wname, "--relay", &a.relay])
        .arg("--corpus")
        .arg(&a.corpus)
        .args(["--warmup-runs", &a.warmup_runs.to_string()])
        .args(["--min-runs", &a.min_runs.to_string()])
        .args(["--min-time-ms", &a.min_time_ms.to_string()])
        .args(["--max-runs", &a.max_runs.to_string()])
        .args(["--timeout-ms", &a.timeout_ms.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return json!({ "error": format!("spawn: {e}") }),
    };
    // Forward the child's stderr, keeping its tail for the error message of a crash.
    let stderr = child.stderr.take().unwrap();
    let tail = std::thread::spawn(move || {
        let mut tail: Vec<String> = Vec::new();
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            eprintln!("{line}");
            tail.push(line);
            if tail.len() > 8 {
                tail.remove(0);
            }
        }
        tail
    });
    let mut stdout = String::new();
    let _ = child.stdout.take().unwrap().read_to_string(&mut stdout);
    let status = child.wait();
    let tail = tail.join().unwrap_or_default();
    let last = stdout.lines().rev().find(|l| l.trim_start().starts_with('{'));
    match last.and_then(|l| serde_json::from_str::<Value>(l).ok()) {
        Some(v) => v,
        None => {
            let how = match status {
                Ok(s) => {
                    use std::os::unix::process::ExitStatusExt;
                    match s.signal() {
                        Some(sig) => format!("killed by signal {sig}"),
                        None => format!("exit status {}", s.code().unwrap_or(-1)),
                    }
                }
                Err(e) => e.to_string(),
            };
            let msg = tail.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_default();
            json!({ "error": format!("crashed ({how}): {msg}") })
        }
    }
}

fn write_out(path: &Path, doc: &Value) {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).unwrap_or_else(|e| panic!("mkdir {}: {e}", dir.display()));
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(doc).unwrap())
        .unwrap_or_else(|e| panic!("write {}: {e}", tmp.display()));
    std::fs::rename(&tmp, path).unwrap_or_else(|e| panic!("rename {}: {e}", path.display()));
}

fn main() {
    let a = parse_args();
    let all = clients::all();
    if let Some(id) = &a.child {
        run_child(&a, id);
        return;
    }
    if a.list {
        for m in &all {
            println!("{}", m.id);
        }
        return;
    }
    if let Some(sel) = &a.clients {
        for id in sel {
            if !all.iter().any(|m| m.id == id) {
                eprintln!("unknown client {id} (see --list)");
                std::process::exit(2);
            }
        }
    }
    let manifest = load_manifest(&a.corpus);
    let wnames: Vec<String> = match &a.workloads {
        Some(sel) => {
            for s in sel {
                if workload(&manifest, s).is_none() {
                    eprintln!("unknown workload {s}");
                    std::process::exit(2);
                }
            }
            sel.clone()
        }
        None => vec!["all".into()],
    };

    let flags = env!("LIBBENCH_RUSTFLAGS");
    let runtime = format!(
        "{}, {}, {} profile (lto=fat, codegen-units=1, opt-level=3)",
        env!("LIBBENCH_RUSTC"),
        if flags.is_empty() { "default RUSTFLAGS".to_string() } else { format!("RUSTFLAGS=\"{flags}\"") },
        env!("LIBBENCH_PROFILE")
    );
    let mut doc = json!({
        "harness": "rust",
        "language": "Rust",
        "runtime": runtime,
        "host": host(),
        "settings": {
            "warmup_runs": a.warmup_runs, "min_runs": a.min_runs,
            "min_time_ms": a.min_time_ms, "max_runs": a.max_runs, "timeout_ms": a.timeout_ms,
        },
        "relay": a.relay,
        "corpus_fingerprint": manifest["fingerprint"],
        "results": [],
    });

    for wname in &wnames {
        let w = workload(&manifest, wname).unwrap();
        let exp = expected_of(w);
        for m in &all {
            if a.clients.as_ref().is_some_and(|sel| !sel.iter().any(|s| s == m.id)) {
                continue;
            }
            eprintln!("== {} on {wname}", m.id);
            let r = spawn_child(&a, m.id, wname);
            let (version, license) = crate_info(m.library);
            let runs: Vec<f64> =
                r["run_ms"].as_array().map(|v| v.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
            let cpus: Vec<f64> =
                r["run_cpu_ms"].as_array().map(|v| v.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
            let error = r["error"].as_str().map(String::from);
            let timed = error.is_none() && !runs.is_empty();
            let med = timed.then(|| median(&runs));
            let mut row = json!({
                "client": m.id,
                "library": m.library_name,
                "version": version,
                "license": license,
                "api": m.api,
                "websocket": m.websocket,
                "crypto": m.crypto,
                "verify": m.verify,
                "notes": m.notes,
                "variant": m.variant,
                "workload": wname,
                "events": exp.events,
                "bytes": w["bytes"],
                "accepted": r.get("accepted").cloned().unwrap_or(Value::Null),
                "accepted_xor": r.get("accepted_xor").cloned().unwrap_or(Value::Null),
                "ambiguous_accepted": r.get("ambiguous_accepted").cloned().unwrap_or(Value::Null),
                "expired_accepted": r.get("expired_accepted").cloned().unwrap_or(Value::Null),
                "accepted_ok": r.get("accepted_ok").cloned().unwrap_or(json!(false)),
                "errors": r.get("errors").cloned().unwrap_or(json!(if error.is_some() { 1 } else { 0 })),
                "error": error,
                "warmup_runs": if timed { r["warmup_runs"].clone() } else { json!(0) },
                "runs": if timed { runs.len() } else { 0 },
                "first_run_ms": if timed { r["first_run_ms"].as_f64().map(round1) } else { None },
                "median_ms": med.map(round1),
                "min_ms": timed.then(|| round1(runs.iter().cloned().fold(f64::MAX, f64::min))),
                "p90_ms": timed.then(|| round1(p90(&runs))),
                "run_ms": if timed { runs.iter().map(|x| round1(*x)).collect::<Vec<_>>() } else { vec![] },
                "events_per_s": med.map(|m| round1(exp.events as f64 / (m / 1000.0))),
                "us_per_event": med.map(|m| (m * 1000.0 / exp.events as f64 * 100.0).round() / 100.0),
                "cpu_ms": (timed && !cpus.is_empty()).then(|| round1(median(&cpus))),
                "peak_rss_mb": r.get("peak_rss_mb").cloned().unwrap_or(Value::Null),
            });
            if let Some(e) = row["error"].as_str() {
                eprintln!("   {} on {wname}: ERROR {e}", m.id);
            } else {
                eprintln!(
                    "   {} on {wname}: median {} ms, cpu {} ms, accepted {} (ok: {})",
                    m.id, row["median_ms"], row["cpu_ms"], row["accepted"], row["accepted_ok"]
                );
            }
            if row["accepted"].is_null() {
                row["accepted_ok"] = json!(false);
            }
            doc["results"].as_array_mut().unwrap().push(row);
            write_out(&a.out, &doc);
        }
    }
    write_out(&a.out, &doc);
    eprintln!("wrote {}", a.out.display());
}
