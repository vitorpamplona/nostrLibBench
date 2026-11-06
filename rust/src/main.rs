//! nostrLibBench Rust harness. Follows HARNESS.md: per client and workload it re-executes
//! itself (`--child`) so every library runs in a fresh process; the child times warm-up and
//! measured runs (a new client instance per run, one subscription to EOSE each) and prints its
//! result as one JSON line, which the parent turns into a row of `results/rust.json`. A
//! client whose library is built with another cargo feature set runs in a sibling binary
//! (`Meta::binary`) that speaks the same child protocol.

mod clients;
mod harness;
mod sink;

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};

use harness::{Args, expected_of, load_manifest, round1, workload};

mod crates {
    include!(concat!(env!("OUT_DIR"), "/crates.rs"));
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
// ---------------------------------------------------------------------------------------------
// Parent.

fn median(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = s.len();
    if n % 2 == 1 { s[n / 2] } else { (s[n / 2 - 1] + s[n / 2]) / 2.0 }
}

/// `alloc_bytes` of the median run: with an odd number of runs, the run whose time is the
/// median; with an even number (where `median_ms` averages the two middle runs), the median
/// of the alloc values (mean of the two middle ones).
fn median_alloc(runs: &[f64], allocs: &[u64]) -> Option<u64> {
    let n = runs.len();
    if n == 0 || allocs.len() != n {
        return None;
    }
    if n % 2 == 1 {
        let mut idx: Vec<usize> = (0..n).collect();
        idx.sort_by(|&a, &b| runs[a].partial_cmp(&runs[b]).unwrap());
        Some(allocs[idx[n / 2]])
    } else {
        let mut s = allocs.to_vec();
        s.sort_unstable();
        Some((s[n / 2 - 1] + s[n / 2]) / 2)
    }
}

fn p90(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = s.len();
    s[((n as f64 * 0.9).ceil() as usize).clamp(1, n) - 1]
}

/// Runs one child process and returns its result line (or an error object).
fn spawn_child(a: &Args, m: &harness::Meta, wname: &str) -> Value {
    let id = m.id;
    let mut exe = std::env::current_exe().expect("current_exe");
    if let Some(bin) = m.binary {
        exe.set_file_name(bin);
    }
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
    let a = harness::parse_args();
    let all = clients::all();
    if let Some(id) = &a.child {
        harness::run_child(&a, id, clients::make);
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
            let r = spawn_child(&a, m, wname);
            let (version, license) = crate_info(m.library);
            let runs: Vec<f64> =
                r["run_ms"].as_array().map(|v| v.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
            let cpus: Vec<f64> =
                r["run_cpu_ms"].as_array().map(|v| v.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
            let allocs: Vec<u64> = r["run_alloc_bytes"]
                .as_array()
                .map(|v| v.iter().filter_map(Value::as_u64).collect())
                .unwrap_or_default();
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
                "base_rss_mb": r.get("base_rss_mb").cloned().unwrap_or(Value::Null),
                "alloc_bytes": if timed { median_alloc(&runs, &allocs) } else { None },
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
