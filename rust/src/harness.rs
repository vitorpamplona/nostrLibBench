//! What every harness binary shares: the command line, the client interface, and the child
//! side of a measurement (one client, one workload, fresh process). Included by the main
//! binary and by the per-feature-set binaries (`nostro2-secp/`), which exist because some
//! libraries offer a speed option as a cargo feature that cannot share a build with their
//! default.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::sink::{Expected, Sink};

#[derive(Clone)]
pub struct Args {
    pub relay: String,
    pub corpus: PathBuf,
    pub out: PathBuf,
    pub workloads: Option<Vec<String>>,
    pub clients: Option<Vec<String>>,
    pub warmup_runs: usize,
    pub min_runs: usize,
    pub min_time_ms: u64,
    pub max_runs: usize,
    pub timeout_ms: u64,
    pub list: bool,
    pub child: Option<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: libbench-rust [--relay URL] [--corpus DIR] [--out FILE] [--workloads a,b] [--clients x,y]\n\
         \x20                    [--warmup-runs N] [--min-runs N] [--min-time-ms N] [--max-runs N]\n\
         \x20                    [--timeout-ms N] [--quick] [--list]"
    );
    std::process::exit(2)
}

pub fn parse_args() -> Args {
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

/// A client entry: what the row reports about it.
pub struct Meta {
    /// Row id, `<library>-<variant>`.
    pub id: &'static str,
    /// Crate name, for the resolved version and license.
    pub library: &'static str,
    /// Library name as reported.
    pub library_name: &'static str,
    pub api: &'static str,
    pub websocket: &'static str,
    pub crypto: &'static str,
    pub verify: &'static str,
    pub notes: &'static str,
    pub variant: bool,
    /// The binary that runs it: `None` for the main one, else a sibling executable built with
    /// another feature set of the library.
    pub binary: Option<&'static str>,
}

pub trait Client {
    /// One run: setup, subscribe with `{"limit": limit}`, deliver to `sink` until EOSE (and
    /// the post-EOSE wait), teardown.
    fn run(&mut self, url: &str, limit: usize, sink: &mut Sink) -> Result<(), String>;
}

pub type Make = fn(&str) -> Result<Box<dyn Client>, String>;

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

pub fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn hex32(s: &str) -> [u8; 32] {
    crate::sink::decode_hex32(s).expect("hex id in manifest")
}

pub fn load_manifest(corpus: &Path) -> Value {
    let p = corpus.join("manifest.json");
    serde_json::from_slice(
        &std::fs::read(&p)
            .unwrap_or_else(|e| panic!("{}: {e} (build it with python3 corpus/prepare.py)", p.display())),
    )
    .expect("manifest.json")
}

pub fn workload<'a>(manifest: &'a Value, name: &str) -> Option<&'a Value> {
    manifest["workloads"].as_array()?.iter().find(|w| w["name"] == name)
}

pub fn expected_of(w: &Value) -> Expected {
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

fn emit(v: &Value) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

/// The child side: warm-up and measured runs of one client on one workload, then one JSON
/// line on stdout for the parent.
pub fn run_child(a: &Args, id: &str, make: Make) {
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

    let mut client = match make(id) {
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
        let mut sink = Sink::new(expected.clone(), false);
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
    // The timed runs only count and XOR. When the set matches none of the correct outcomes,
    // one more run (untimed, not reported) records the ids to tell how many of the ambiguous
    // and expired events the library delivered.
    if first.is_some() && error.is_none() && result["ambiguous_accepted"].is_null() {
        let mut sink = Sink::new(expected.clone(), true);
        deadline.store(started.elapsed().as_millis() as u64 + a.timeout_ms, Ordering::Relaxed);
        if client.run(&url, expected.events, &mut sink).is_ok() {
            let s = sink.summary();
            for k in ["ambiguous_accepted", "expired_accepted"] {
                result[k] = s[k].clone();
            }
        }
        deadline.store(u64::MAX, Ordering::Relaxed);
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
