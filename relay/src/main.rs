//! nostrLibBench relay: a WebSocket server that answers every `REQ` with the whole corpus
//! workload, `["EVENT",<sub>,<event>]` frame after frame, then `["EOSE",<sub>]`, as fast as
//! the client's socket takes it.
//!
//! It is not a relay in any other sense: it stores nothing, ignores filters (every REQ gets
//! every event of the workload, in file order) and answers `EVENT` with an accepting `OK`.
//! The point is to never be the bottleneck. Events are kept as the exact bytes of the
//! corpus line; a REQ assembles the frames into a 1 MiB buffer and hands that to the
//! kernel with one `write`, so the server spends ~1 ms of CPU per 27 MB stream and the
//! rest of the time blocked on a full socket buffer, waiting for the client.
//!
//!     blast-relay --corpus .corpus --port 7777
//!
//! The workload is the URL path: `ws://127.0.0.1:7777/notes` streams `notes.ndjson`;
//! `/` streams `all`. One thread per connection; any number of REQs per connection, each
//! answered in full before the next frame is read.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::time::Instant;

use base64::Engine;

const CHUNK: usize = 1 << 20;

struct Workload {
    events: Vec<Box<[u8]>>,
}

struct Config {
    workloads: HashMap<String, Workload>,
    default: String,
    verbose: bool,
}

fn main() {
    let mut corpus = String::from(".corpus");
    let mut host = String::from("127.0.0.1");
    let mut port: u16 = 7777;
    let mut default = String::from("all");
    let mut verbose = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--corpus" => corpus = args.next().expect("--corpus DIR"),
            "--host" => host = args.next().expect("--host ADDR"),
            "--port" => port = args.next().expect("--port N").parse().expect("port"),
            "--workload" => default = args.next().expect("--workload NAME"),
            "--verbose" | "-v" => verbose = true,
            "--help" | "-h" => {
                eprintln!("blast-relay [--corpus .corpus] [--host 127.0.0.1] [--port 7777] [--workload all] [--verbose]");
                return;
            }
            other => panic!("unknown flag {other}"),
        }
    }

    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(format!("{corpus}/manifest.json")).expect("read manifest.json (run corpus/prepare.py)"),
    )
    .expect("manifest.json");
    let mut workloads = HashMap::new();
    for w in manifest["workloads"].as_array().expect("workloads") {
        let name = w["name"].as_str().unwrap().to_string();
        let file = w["file"].as_str().unwrap();
        let data = std::fs::read(format!("{corpus}/{file}")).expect("workload file");
        let events: Vec<Box<[u8]>> = data
            .split(|&b| b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| l.to_vec().into_boxed_slice())
            .collect();
        workloads.insert(name, Workload { events });
    }
    assert!(workloads.contains_key(&default), "no workload {default}");
    let cfg = Arc::new(Config { workloads, default, verbose });

    let listener = TcpListener::bind((host.as_str(), port)).expect("bind");
    // The launchers wait for this line.
    println!("blast-relay listening on ws://{host}:{port}");
    std::io::stdout().flush().ok();

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let cfg = cfg.clone();
        std::thread::spawn(move || {
            if let Err(e) = serve(stream, &cfg) {
                if cfg.verbose {
                    eprintln!("connection ended: {e}");
                }
            }
        });
    }
}

type Res<T> = Result<T, Box<dyn std::error::Error>>;

fn serve(stream: TcpStream, cfg: &Config) -> Res<()> {
    stream.set_nodelay(true)?;
    let mut out = stream.try_clone()?;
    let mut rd = BufReader::with_capacity(64 * 1024, stream);

    // ---- HTTP upgrade
    let mut request_line = String::new();
    rd.read_line(&mut request_line)?;
    let path = request_line.split_whitespace().nth(1).unwrap_or("/").to_string();
    let mut headers = HashMap::new();
    loop {
        let mut line = String::new();
        if rd.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let workload_name = {
        let p = path.split('?').next().unwrap_or("/").trim_matches('/');
        if p.is_empty() { cfg.default.clone() } else { p.to_string() }
    };
    let Some(workload) = cfg.workloads.get(&workload_name) else {
        out.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")?;
        return Ok(());
    };
    let Some(key) = headers.get("sec-websocket-key") else {
        // NIP-11 for clients that ask for it; anything else gets the same document.
        let body = br#"{"name":"nostrLibBench blast-relay","description":"streams a fixed corpus to every REQ","supported_nips":[1,11,15,20],"software":"https://github.com/vitorpamplona/nostrLibBench","version":"0.1.0"}"#;
        let head = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/nostr+json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        out.write_all(head.as_bytes())?;
        out.write_all(body)?;
        return Ok(());
    };
    let mut sha = sha1_smol::Sha1::new();
    sha.update(key.as_bytes());
    sha.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    let accept = base64::engine::general_purpose::STANDARD.encode(sha.digest().bytes());
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    out.write_all(resp.as_bytes())?;
    if cfg.verbose {
        eprintln!("connected {path} -> {workload_name}");
    }

    // ---- frames
    let mut buf: Vec<u8> = Vec::with_capacity(CHUNK + 64 * 1024);
    loop {
        let (opcode, payload) = match read_message(&mut rd)? {
            Some(m) => m,
            None => return Ok(()),
        };
        match opcode {
            0x1 => handle_text(&payload, workload, &mut out, &mut buf, cfg)?,
            0x8 => {
                // Echo the status code, then close.
                let code = if payload.len() >= 2 { &payload[..2] } else { &[0x03, 0xE8][..] };
                let mut f = Vec::new();
                frame_header(&mut f, 0x8, code.len());
                f.extend_from_slice(code);
                let _ = out.write_all(&f);
                return Ok(());
            }
            0x9 => {
                let mut f = Vec::new();
                frame_header(&mut f, 0xA, payload.len());
                f.extend_from_slice(&payload);
                out.write_all(&f)?;
            }
            _ => {} // binary, pong: ignored
        }
    }
}

fn handle_text(payload: &[u8], workload: &Workload, out: &mut TcpStream, buf: &mut Vec<u8>, cfg: &Config) -> Res<()> {
    let msg: serde_json::Value = match serde_json::from_slice(payload) {
        Ok(v) => v,
        Err(_) => return send_text(out, br#"["NOTICE","invalid JSON"]"#),
    };
    let arr = msg.as_array().map(|a| a.as_slice()).unwrap_or(&[]);
    match arr.first().and_then(|v| v.as_str()) {
        Some("REQ") => {
            let sub = arr.get(1).cloned().unwrap_or(serde_json::Value::String(String::new()));
            let sub_json = serde_json::to_vec(&sub)?;
            let start = Instant::now();
            let bytes = stream_workload(workload, &sub_json, out, buf)?;
            if cfg.verbose {
                let s = start.elapsed().as_secs_f64();
                eprintln!(
                    "REQ {}: {} events, {:.1} MB in {:.3} s ({:.0} events/s)",
                    String::from_utf8_lossy(&sub_json),
                    workload.events.len(),
                    bytes as f64 / 1e6,
                    s,
                    workload.events.len() as f64 / s
                );
            }
            Ok(())
        }
        Some("EVENT") => {
            let id = arr.get(1).and_then(|e| e.get("id")).cloned().unwrap_or_default();
            let reply = serde_json::to_vec(&serde_json::json!(["OK", id, true, ""]))?;
            send_text(out, &reply)
        }
        Some("CLOSE") | Some("AUTH") => Ok(()),
        _ => send_text(out, br#"["NOTICE","unsupported message"]"#),
    }
}

/// Writes every event of the workload and the EOSE. Returns the bytes written.
fn stream_workload(w: &Workload, sub_json: &[u8], out: &mut TcpStream, buf: &mut Vec<u8>) -> Res<usize> {
    const PRE: &[u8] = b"[\"EVENT\",";
    let mut total = 0;
    buf.clear();
    for ev in &w.events {
        let len = PRE.len() + sub_json.len() + 1 + ev.len() + 1;
        frame_header(buf, 0x1, len);
        buf.extend_from_slice(PRE);
        buf.extend_from_slice(sub_json);
        buf.push(b',');
        buf.extend_from_slice(ev);
        buf.push(b']');
        if buf.len() >= CHUNK {
            out.write_all(buf)?;
            total += buf.len();
            buf.clear();
        }
    }
    let mut eose = Vec::with_capacity(16 + sub_json.len());
    eose.extend_from_slice(b"[\"EOSE\",");
    eose.extend_from_slice(sub_json);
    eose.push(b']');
    frame_header(buf, 0x1, eose.len());
    buf.extend_from_slice(&eose);
    out.write_all(buf)?;
    total += buf.len();
    buf.clear();
    Ok(total)
}

fn send_text(out: &mut TcpStream, payload: &[u8]) -> Res<()> {
    let mut f = Vec::with_capacity(payload.len() + 10);
    frame_header(&mut f, 0x1, payload.len());
    f.extend_from_slice(payload);
    out.write_all(&f)?;
    Ok(())
}

/// Server frames are never masked and never fragmented.
fn frame_header(buf: &mut Vec<u8>, opcode: u8, len: usize) {
    buf.push(0x80 | opcode);
    if len < 126 {
        buf.push(len as u8);
    } else if len <= 0xFFFF {
        buf.push(126);
        buf.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        buf.push(127);
        buf.extend_from_slice(&(len as u64).to_be_bytes());
    }
}

/// Reads one message (reassembling fragments; control frames returned as they come).
fn read_message(rd: &mut impl Read) -> Res<Option<(u8, Vec<u8>)>> {
    let mut message_opcode = 0u8;
    let mut message = Vec::new();
    loop {
        let mut h = [0u8; 2];
        if let Err(e) = rd.read_exact(&mut h) {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                return Ok(None);
            }
            return Err(e.into());
        }
        let fin = h[0] & 0x80 != 0;
        let opcode = h[0] & 0x0F;
        let masked = h[1] & 0x80 != 0;
        let mut len = (h[1] & 0x7F) as u64;
        if len == 126 {
            let mut b = [0u8; 2];
            rd.read_exact(&mut b)?;
            len = u16::from_be_bytes(b) as u64;
        } else if len == 127 {
            let mut b = [0u8; 8];
            rd.read_exact(&mut b)?;
            len = u64::from_be_bytes(b);
        }
        let mut mask = [0u8; 4];
        if masked {
            rd.read_exact(&mut mask)?;
        }
        let mut payload = vec![0u8; len as usize];
        rd.read_exact(&mut payload)?;
        if masked {
            for (i, b) in payload.iter_mut().enumerate() {
                *b ^= mask[i & 3];
            }
        }
        if opcode >= 0x8 {
            return Ok(Some((opcode, payload)));
        }
        if opcode != 0 {
            message_opcode = opcode;
        }
        message.extend_from_slice(&payload);
        if fin {
            return Ok(Some((message_opcode, message)));
        }
    }
}
