#!/usr/bin/env python3
"""
Builds the nostrLibBench corpus: one NDJSON file per workload plus manifest.json.

The events are the same 31,161 real events as nostrJsonBench (an Amethyst startup session
in 2024, one event per line, byte-for-byte as a relay sent them). The relay (`relay/`)
streams these lines to every client; every harness must accept exactly the events this
script finds valid, and reject the rest.

    python3 corpus/prepare.py                       # the bundled events
    python3 corpus/prepare.py --source dump.ndjson  # any NDJSON of events, .gz or plain

An event is valid when its `id` is the SHA-256 of its NIP-01 serialization and `sig` is a
valid BIP-340 signature of that id by `pubkey`. Verification uses coincurve when it is
installed and a pure-Python BIP-340 implementation otherwise (a few minutes, once; the
result is cached in the manifest and reused while the source is unchanged).
"""
import argparse
import gzip
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_SOURCE = os.path.join(HERE, "nostr-2024-startup.ndjson.gz")
DEFAULT_OUT = os.path.join(ROOT, ".corpus")

# Same workloads as nostrJsonBench, so the two benchmarks can be read side by side.
LIST_KINDS = {3, 10000, 10001, 10002, 10003, 10004, 10005, 10006, 10007, 10015, 10030, 30000, 30001, 30002, 30003}
WORKLOADS = [
    ("all", "every event in the corpus: the real kind mix a client downloads", lambda e: True),
    ("notes", "kind 1 text notes: short UTF-8 content, a few e/p tags", lambda e: e["kind"] == 1),
    ("reactions", "kind 7 reactions: tiny events, 3 tags, 1-char content", lambda e: e["kind"] == 7),
    ("dms", "kind 4 NIP-04 DMs: base64 ciphertext content", lambda e: e["kind"] == 4),
    ("giftwraps", "kind 1059 NIP-59 gift wraps: one long base64 NIP-44 payload", lambda e: e["kind"] == 1059),
    ("metadata", "kind 0 profiles: content is an escaped JSON object", lambda e: e["kind"] == 0),
    ("zaps", "kind 9735 zap receipts: escaped JSON zap request inside a tag", lambda e: e["kind"] == 9735),
    ("lists", "contact/mute/relay/bookmark lists (3, 1000x, 3000x): tag-heavy", lambda e: e["kind"] in LIST_KINDS),
]

# ------------------------------------------------------------------ NIP-01 id

_ESC = {0x0A: "\\n", 0x22: '\\"', 0x5C: "\\\\", 0x0D: "\\r", 0x09: "\\t", 0x08: "\\b", 0x0C: "\\f"}


def nip01_string(s):
    """NIP-01: escape only \\n \\" \\\\ \\r \\t \\b \\f; every other character verbatim."""
    return '"' + "".join(_ESC.get(ord(c), c) for c in s) + '"'


def nip01_serialize(e):
    tags = "[" + ",".join("[" + ",".join(nip01_string(v) for v in t) + "]" for t in e["tags"]) + "]"
    return "[0,%s,%d,%d,%s,%s]" % (nip01_string(e["pubkey"]), e["created_at"], e["kind"], tags, nip01_string(e["content"]))


def event_hash(e):
    return hashlib.sha256(nip01_serialize(e).encode("utf-8")).hexdigest()


def json_escaped_hash(e):
    """The id most libraries compute: JSON.stringify / serde_json escaping, which also
    writes the other control characters (U+0000-U+001F) as \\u00XX. NIP-01 says to write
    them verbatim; an event whose id only matches this form is "ambiguous"."""
    def js(s):
        return '"' + "".join(_ESC.get(ord(c)) or ("\\u%04x" % ord(c) if ord(c) < 0x20 else c) for c in s) + '"'

    tags = "[" + ",".join("[" + ",".join(js(v) for v in t) + "]" for t in e["tags"]) + "]"
    ser = "[0,%s,%d,%d,%s,%s]" % (js(e["pubkey"]), e["created_at"], e["kind"], tags, js(e["content"]))
    return hashlib.sha256(ser.encode("utf-8")).hexdigest()


# ------------------------------------------------------------------ BIP-340

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _jadd(p, q):
    # Jacobian coordinates; None is the point at infinity.
    if p is None:
        return q
    if q is None:
        return p
    x1, y1, z1 = p
    x2, y2, z2 = q
    z1z1 = z1 * z1 % P
    z2z2 = z2 * z2 % P
    u1 = x1 * z2z2 % P
    u2 = x2 * z1z1 % P
    s1 = y1 * z2 * z2z2 % P
    s2 = y2 * z1 * z1z1 % P
    if u1 == u2:
        if s1 != s2:
            return None
        return _jdbl(p)
    h = (u2 - u1) % P
    r = (s2 - s1) % P
    hh = h * h % P
    hhh = h * hh % P
    v = u1 * hh % P
    x3 = (r * r - hhh - 2 * v) % P
    y3 = (r * (v - x3) - s1 * hhh) % P
    z3 = h * z1 * z2 % P
    return (x3, y3, z3)


def _jdbl(p):
    if p is None:
        return None
    x, y, z = p
    if y == 0:
        return None
    yy = y * y % P
    s = 4 * x * yy % P
    m = 3 * x * x % P
    x3 = (m * m - 2 * s) % P
    y3 = (m * (s - x3) - 8 * yy * yy) % P
    z3 = 2 * y * z % P
    return (x3, y3, z3)


def _jmul2(a, pa, b, pb):
    """a*pa + b*pb (Shamir's trick), affine inputs, Jacobian output."""
    ja = (pa[0], pa[1], 1)
    jb = (pb[0], pb[1], 1)
    jab = _jadd(ja, jb)
    r = None
    for i in range(max(a.bit_length(), b.bit_length()) - 1, -1, -1):
        r = _jdbl(r)
        ba, bb = (a >> i) & 1, (b >> i) & 1
        if ba and bb:
            r = _jadd(r, jab)
        elif ba:
            r = _jadd(r, ja)
        elif bb:
            r = _jadd(r, jb)
    return r


def _tagged(tag, msg):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + msg).digest()


def _lift_x(x):
    if x >= P:
        return None
    c = (pow(x, 3, P) + 7) % P
    y = pow(c, (P + 1) // 4, P)
    if y * y % P != c:
        return None
    return (x, y if y % 2 == 0 else P - y)


def schnorr_verify_py(msg, pub, sig):
    if len(pub) != 32 or len(sig) != 64 or len(msg) != 32:
        return False
    pt = _lift_x(int.from_bytes(pub, "big"))
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:], "big")
    if pt is None or r >= P or s >= N:
        return False
    e = int.from_bytes(_tagged("BIP0340/challenge", sig[:32] + pub + msg), "big") % N
    R = _jmul2(s, G, N - e, pt)
    if R is None:
        return False
    x, y, z = R
    zi = pow(z, P - 2, P)
    zi2 = zi * zi % P
    ry = y * zi2 * zi % P
    return ry % 2 == 0 and x * zi2 % P == r


try:
    import coincurve  # noqa: E402

    def schnorr_verify(msg, pub, sig):
        try:
            return coincurve.PublicKeyXOnly(pub).verify(sig, msg)
        except Exception:
            return False

    VERIFIER = "coincurve " + getattr(coincurve, "__version__", "")
except ImportError:
    schnorr_verify = schnorr_verify_py
    VERIFIER = "pure-Python BIP-340 (corpus/prepare.py)"


def check(e):
    """Returns None when the event is valid, else the reason."""
    try:
        id_b = bytes.fromhex(e["id"])
        pub = bytes.fromhex(e["pubkey"])
        sig = bytes.fromhex(e["sig"])
    except ValueError:
        return "bad hex"
    if len(id_b) != 32 or len(pub) != 32 or len(sig) != 64:
        return "bad length"
    if e["id"] != e["id"].lower():
        return "id mismatch"
    ambiguous = False
    if event_hash(e) != e["id"]:
        if json_escaped_hash(e) != e["id"]:
            return "id mismatch"
        ambiguous = True
    if not schnorr_verify(id_b, pub, sig):
        return "bad signature"
    return AMBIGUOUS if ambiguous else None


AMBIGUOUS = "ambiguous: id matches only with control characters escaped as \\u00XX"


def is_expired(e):
    """NIP-40: an `expiration` tag whose timestamp has passed (every one in the bundled
    corpus expired in 2024, so the set doesn't change with the date of the run)."""
    for t in e["tags"]:
        if len(t) >= 2 and t[0] == "expiration":
            try:
                return int(t[1]) < time.time()
            except ValueError:
                return False
    return False


# ------------------------------------------------------------------ main


def open_text(path):
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic == b"\x1f\x8b":
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "rt", encoding="utf-8")


def xor_ids(ids):
    acc = 0
    for i in ids:
        acc ^= int(i, 16)
    return "%064x" % acc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    lines = []
    with open_text(args.source) as f:
        for line in f:
            line = line.strip()
            if line:
                lines.append(line)
    fingerprint = hashlib.sha256()
    for line in lines:
        fingerprint.update(line.encode("utf-8"))
        fingerprint.update(b"\n")
    fp = fingerprint.hexdigest()

    # Reuse the verification of a previous run of the same source: it is the slow part.
    cache = {}
    old_manifest = os.path.join(args.out, "manifest.json")
    if os.path.exists(old_manifest):
        with open(old_manifest) as f:
            old = json.load(f)
        if old.get("fingerprint") == fp and "invalid" in old:
            cache = {"invalid": {x["id"]: x["reason"] for x in old["invalid"]}, "verifier": old.get("verifier")}

    events = []
    seen = set()
    for line in lines:
        e = json.loads(line)
        if e["id"] in seen:
            continue
        seen.add(e["id"])
        events.append((line.encode("utf-8"), e))

    if cache:
        invalid = cache["invalid"]
        verifier = cache["verifier"]
        print(f"verification cached ({verifier})")
    else:
        print(f"verifying {len(events)} events with {VERIFIER} ...", flush=True)
        invalid = {}
        for n, (_, e) in enumerate(events):
            reason = check(e)
            if reason:
                invalid[e["id"]] = reason
            if n % 2000 == 1999:
                print(f"  {n + 1}/{len(events)}", flush=True)
        verifier = VERIFIER

    os.makedirs(args.out, exist_ok=True)
    workloads = []
    for name, desc, pred in WORKLOADS:
        chosen = [(raw, e) for raw, e in events if pred(e)]
        if not chosen:
            continue
        file = f"{name}.ndjson"
        size = 0
        with open(os.path.join(args.out, file), "wb") as f:
            for raw, e in chosen:
                f.write(raw)
                f.write(b"\n")
                size += len(raw)
        valid_ids = [e["id"] for _, e in chosen if e["id"] not in invalid]
        ambiguous = [e["id"] for _, e in chosen if invalid.get(e["id"]) == AMBIGUOUS]
        expired = [e["id"] for _, e in chosen if e["id"] not in invalid and is_expired(e)]
        workloads.append(
            {
                "name": name,
                "file": file,
                "description": desc,
                "events": len(chosen),
                "bytes": size,
                "avg_bytes": round(size / len(chosen)),
                "valid_events": len(valid_ids),
                "valid_id_xor": xor_ids(valid_ids),
                # Either outcome is correct for these: a client may accept or reject them.
                "ambiguous_ids": ambiguous,
                # Valid, but their NIP-40 expiration has passed: a client may drop them all or
                # deliver them all. These are included in valid_events and valid_id_xor.
                "expired_ids": expired,
            }
        )
        print(f"{name:10s} {len(chosen):6d} events {size / 1e6:7.2f} MB  {len(chosen) - len(valid_ids) - len(ambiguous)} invalid, {len(ambiguous)} ambiguous, {len(expired)} expired")

    manifest = {
        "version": 1,
        "source": os.path.relpath(os.path.abspath(args.source), ROOT),
        "fingerprint": fp,
        "events": len(events),
        "verifier": verifier,
        "invalid": [{"id": i, "reason": r} for i, r in sorted(invalid.items())],
        "workloads": workloads,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    n_amb = sum(1 for r in invalid.values() if r == AMBIGUOUS)
    print(f"{len(events)} events, {len(invalid) - n_amb} invalid, {n_amb} ambiguous -> {args.out}")


if __name__ == "__main__":
    sys.exit(main())
