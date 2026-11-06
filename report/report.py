#!/usr/bin/env python3
"""
Merges results/<harness>.json files into one Markdown report.

    python3 report/report.py                    # results/*.json -> results/report.md
    python3 report/report.py --results DIR --out FILE

A row is ranked only when the events it delivered are exactly the valid events of the
workload (checked here again against the corpus manifest, not taken from the harness),
the library verified them itself (`verify` library or explicit), and it is the library's
fastest such row. Everything else is listed below the ranking with the reason.
"""
import argparse
import glob
import itertools
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
RUNTIME_HARNESSES = ("node", "bun", "deno")


def load(results_dir):
    runs = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
        try:
            with open(path) as f:
                run = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(run, dict) and "results" in run and "harness" in run:
            runs.append(run)
    return runs


def fmt(v, digits=0):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "–"
    return f"{v:,.{digits}f}"


def xor_hex(a, b):
    return "%064x" % (int(a, 16) ^ int(b, 16))


def check_accepted(r, w):
    """(ok, why) for a row against its manifest workload."""
    if r.get("error"):
        return False, r["error"]
    acc, axor = r.get("accepted"), r.get("accepted_xor")
    if acc is None or axor is None:
        return False, "no accepted set reported"
    if w is not None and w.get("genuine_first_xor") and acc == w["genuine_first_events"] \
            and axor.lower() == w["genuine_first_xor"]:
        return False, (f"delivered only the {acc} genuine events sent before their forged copy: it marks "
                       "an id seen before verifying the event, so a forged copy censors the genuine one")
    if w is None:
        return bool(r.get("accepted_ok")), "workload not in manifest"
    amb = w.get("ambiguous_ids", [])
    exp = w.get("expired_ids", [])
    # Expired events: all delivered or all dropped. Ambiguous events: any subset.
    for exp_kept in ([True, False] if exp else [True]):
        base = w["valid_events"] - (0 if exp_kept else len(exp))
        base_xor = w["valid_id_xor"]
        if not exp_kept:
            for i in exp:
                base_xor = xor_hex(base_xor, i)
        for k in range(len(amb) + 1):
            if acc != base + k:
                continue
            for subset in itertools.combinations(amb, k):
                x = base_xor
                for i in subset:
                    x = xor_hex(x, i)
                if x == axor.lower():
                    return True, ""
    if exp and r.get("expired_accepted") not in (None, 0, len(exp)):
        return False, f"delivered {r['expired_accepted']} of the {len(exp)} expired events (all or none)"
    # What the row should have delivered, given its own choices on the optional events.
    expected = w["valid_events"] - len(exp) + (r.get("expired_accepted") if r.get("expired_accepted") is not None else len(exp))
    expected += r.get("ambiguous_accepted") or 0
    diff = acc - expected
    if diff > 0:
        return False, f"accepted {acc:,}, expected {expected:,}: {diff:,} invalid events delivered (or duplicates)"
    if diff < 0:
        return False, f"accepted {acc:,}, expected {expected:,}: {-diff:,} valid events missing"
    return False, f"accepted {acc:,} (the expected count) but not the expected set"


def cpu_us(r):
    """CPU time per event sent, all threads of the client process."""
    if r.get("cpu_ms") is None or not r.get("events"):
        return None
    return r["cpu_ms"] * 1000 / r["events"]


def rss_growth(r):
    """MB the process grew from the end of its first setup to its peak: the run's own memory."""
    if r.get("peak_rss_mb") is None or r.get("base_rss_mb") is None:
        return None
    return max(r["peak_rss_mb"] - r["base_rss_mb"], 0.0)


def alloc_per_event(r):
    """Heap bytes allocated per event sent over the median run (null where the runtime has no counter)."""
    if r.get("alloc_bytes") is None or not r.get("events"):
        return None
    return r["alloc_bytes"] / r["events"]


def lang_label(run):
    lang = run.get("language", run["harness"])
    if run["harness"] in RUNTIME_HARNESSES:
        return f"{lang} ({run['harness'].capitalize()})"
    return lang


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=os.path.join(BENCH, "results"))
    ap.add_argument("--manifest", default=os.path.join(BENCH, ".corpus", "manifest.json"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    out = args.out or os.path.join(args.results, "report.md")

    runs = load(args.results)
    with open(args.manifest) as f:
        manifest = json.load(f)
    by_name = {w["name"]: w for w in manifest["workloads"]}

    rows = []
    for run in runs:
        for r in run["results"]:
            r = dict(r)
            r["harness"] = run["harness"]
            r["language"] = lang_label(run)
            w = by_name.get(r["workload"])
            r["ok"], r["why"] = check_accepted(r, w)
            # A table cell holds one line: an error message may carry a stack trace.
            r["why"] = " ".join(str(r["why"]).split())
            if r["ok"] and not r.get("median_ms"):
                r["ok"], r["why"] = False, "no timing"
            if r["ok"] and r.get("accepted_ok") is False:
                r["why"] = "harness and report disagree on the accepted set"
                r["ok"] = False
            rows.append(r)
    workloads = [w["name"] for w in manifest["workloads"] if any(r["workload"] == w["name"] for r in rows)]

    # The forged-* workloads check verification itself (forged ids, content, sigs). A client
    # that fails one is still ranked on speed, but every table flags it.
    forged_wls = [w["name"] for w in manifest["workloads"] if w.get("forged")]
    forged_fail = {}
    for r in rows:
        if r["workload"] in forged_wls and not r["ok"]:
            forged_fail.setdefault((r["harness"], r["client"]), []).append(f"{r['workload']}: {r['why']}")

    def rankable(r):
        return (
            r["ok"]
            and r.get("verify") in ("library", "explicit")
            and not r.get("variant")
        )

    forged_ran = {(r["harness"], r["client"]) for r in rows if r["workload"] in forged_wls}

    def forged_flag(r):
        """Short verdict of a client's forged-event checks for the speed tables."""
        key = (r["harness"], r["client"])
        if key not in forged_ran:
            return "not run"
        fails = forged_fail.get(key)
        if not fails:
            return "pass"
        if all("forged copy censors" in f for f in fails):
            return "**fails**: a forged copy censors the genuine event"
        if any("invalid events delivered" in f for f in fails):
            return "**fails**: delivers forged events"
        return "**fails**: " + ", ".join(f.split(":")[0] for f in fails)

    # The headline row of each library: its fastest rankable row on `all` (else its first workload).
    speed_wls = [w for w in workloads if w not in forged_wls]
    head_wl = "all" if "all" in speed_wls else (speed_wls[0] if speed_wls else None)
    headline = {}
    for r in rows:
        if r["workload"] != head_wl or not rankable(r):
            continue
        key = (r["harness"], r["library"])
        if key not in headline or r["median_ms"] < headline[key]["median_ms"]:
            headline[key] = r
    ranked = sorted(headline.values(), key=lambda r: r["median_ms"])
    head_ids = {(r["harness"], r["client"]) for r in ranked}

    L = []
    L.append("# nostrLibBench report\n")
    L.append(
        f"Corpus `{manifest['source']}`: {manifest['events']:,} events, fingerprint "
        f"`{manifest['fingerprint'][:16]}`. Every REQ gets every event of the workload from the "
        f"local blast-relay; a client must deliver exactly the valid ones.\n"
    )
    L.append("| workload | events | MB | valid | invalid | ambiguous |")
    L.append("|---|---:|---:|---:|---:|---:|")
    for name in workloads:
        w = by_name[name]
        amb = len(w.get("ambiguous_ids", []))
        L.append(
            f"| {name} | {w['events']:,} | {w['bytes'] / 1e6:.1f} | {w['valid_events']:,} | "
            f"{w['events'] - w['valid_events'] - amb:,} | {amb} |"
        )
    L.append("")
    L.append("| harness | runtime | host | settings |")
    L.append("|---|---|---|---|")
    for run in runs:
        h = run.get("host", {})
        s = run.get("settings", {})
        L.append(
            f"| {run['harness']} | {run.get('runtime', '')} | {h.get('cpu', '')}, {h.get('cores', '')} cores | "
            f"warmup {s.get('warmup_runs')}, min {s.get('min_runs')} runs / {s.get('min_time_ms')} ms |"
        )
    L.append("")

    if ranked:
        L.append(f"## Ranking (`{head_wl}` workload)\n")
        L.append(
            "One row per library and runtime: its fastest correct row. Time is one subscription, "
            "REQ to the last valid event and EOSE, over every event the relay sent. "
            "CPU is all threads of the client process.\n"
        )
        L.append(
            "| # | language | client | version | verify | crypto | websocket | events/s | µs/event | "
            "median ms | first run ms | CPU ms | CPU µs/event | cores used | accepted | peak RSS MB | base RSS MB | "
            "RSS growth MB | alloc B/event | ambiguous | expired | forged checks |"
        )
        L.append("|---:|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|")
        for i, r in enumerate(ranked, 1):
            util = r["cpu_ms"] / r["median_ms"] if r.get("cpu_ms") and r.get("median_ms") else None
            L.append(
                f"| {i} | {r['language']} | `{r['client']}` | {r.get('version', '')} | {r.get('verify', '')} | "
                f"{r.get('crypto', '')} | {r.get('websocket', '')} | {fmt(r.get('events_per_s'))} | "
                f"{fmt(r.get('us_per_event'), 1)} | {fmt(r.get('median_ms'))} | {fmt(r.get('first_run_ms'))} | "
                f"{fmt(r.get('cpu_ms'))} | {fmt(cpu_us(r), 1)} | {fmt(util, 2)} | {fmt(r.get('accepted'))} | {fmt(r.get('peak_rss_mb'))} | "
                f"{fmt(r.get('base_rss_mb'))} | {fmt(rss_growth(r))} | {fmt(alloc_per_event(r))} | "
                f"{'accepted' if r.get('ambiguous_accepted') else 'rejected'} | "
                f"{'dropped' if r.get('expired_accepted') == 0 else 'delivered'} | {forged_flag(r)} |"
            )
        L.append("")

        by_cpu = sorted((r for r in ranked if cpu_us(r)), key=cpu_us)
        if by_cpu:
            L.append("### By CPU time\n")
            L.append(
                "The same rows ranked by CPU time per event (all threads): the cost of the job "
                "regardless of how many cores a library spreads it over.\n"
            )
            L.append("| # | language | client | CPU µs/event | wall µs/event | cores used | forged checks |")
            L.append("|---:|---|---|---:|---:|---:|---|")
            for i, r in enumerate(by_cpu, 1):
                L.append(
                    f"| {i} | {r['language']} | `{r['client']}` | {fmt(cpu_us(r), 1)} | "
                    f"{fmt(r.get('us_per_event'), 1)} | {fmt(r['cpu_ms'] / r['median_ms'], 2)} | {forged_flag(r)} |"
                )
            L.append("")

    others = [r for r in rows if r["ok"] and (r["harness"], r["client"]) not in head_ids and r["workload"] == head_wl]
    if others:
        L.append(f"## Other correct rows (`{head_wl}`)\n")
        L.append(
            "Variants (another API, option or crypto backend of a ranked library), rows whose "
            "verification is the harness's rather than the library's, and slower rows of a ranked library.\n"
        )
        L.append("| language | client | version | verify | crypto | events/s | µs/event | median ms | CPU ms | peak RSS MB | RSS growth MB | alloc B/event | notes |")
        L.append("|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
        for r in sorted(others, key=lambda r: r["median_ms"]):
            L.append(
                f"| {r['language']} | `{r['client']}` | {r.get('version', '')} | {r.get('verify', '')} | "
                f"{r.get('crypto', '')} | {fmt(r.get('events_per_s'))} | {fmt(r.get('us_per_event'), 1)} | "
                f"{fmt(r.get('median_ms'))} | {fmt(r.get('cpu_ms'))} | {fmt(r.get('peak_rss_mb'))} | "
                f"{fmt(rss_growth(r))} | {fmt(alloc_per_event(r))} | "
                f"{('**Fails the forged-event checks.** ' if (r['harness'], r['client']) in forged_fail else '') + (r.get('notes') or '').replace('|', '/')} |"
            )
        L.append("")

    if any(r["workload"] in forged_wls for r in rows):
        L.append("## Verification checks (forged events)\n")
        L.append(
            "Each forged workload sends ~200 valid events, each with a forged copy: changed content "
            "(id and sig kept), a changed id field (content and sig kept), or another event's sig. "
            "The copy goes first for every other event, so a client that marks an id as seen before "
            "verifying it loses the genuine event. A client that fails one is still ranked on speed, "
            "with the failure flagged in the ranking tables.\n"
        )
        fw = [w for w in forged_wls if any(r["workload"] == w for r in rows)]
        L.append("| language | client | " + " | ".join(fw) + " |")
        L.append("|---|---|" + "---|" * len(fw))
        cell = {(r["language"], r["client"], r["workload"]): r for r in rows if r["workload"] in fw}
        for lang, client in sorted({(r["language"], r["client"]) for r in rows if r["workload"] in fw}):
            vals = []
            for w in fw:
                c = cell.get((lang, client, w))
                vals.append("–" if c is None else ("pass" if c["ok"] else "**fail**: " + str(c["why"]).replace("|", "/")[:120]))
            L.append(f"| {lang} | `{client}` | " + " | ".join(vals) + " |")
        L.append("")

    if len(speed_wls) > 1:
        L.append("## Per workload (µs/event, correct rows)\n")
        clients = sorted({(r["language"], r["client"]) for r in rows if r["ok"] and r["workload"] in speed_wls})
        L.append("| language | client | " + " | ".join(speed_wls) + " |")
        L.append("|---|---|" + "---:|" * len(speed_wls))
        cell = {(r["language"], r["client"], r["workload"]): r for r in rows if r["ok"]}
        for lang, client in clients:
            vals = [fmt(cell[(lang, client, w)]["us_per_event"], 1) if (lang, client, w) in cell else "–" for w in speed_wls]
            L.append(f"| {lang} | `{client}` | " + " | ".join(vals) + " |")
        L.append("")

    bad = [r for r in rows if not r["ok"] and r["workload"] not in forged_wls]
    if bad:
        L.append("## Not ranked: wrong events, errors\n")
        L.append("| language | client | workload | verify | accepted | median ms | why |")
        L.append("|---|---|---|---|---:|---:|---|")
        for r in sorted(bad, key=lambda r: (r["language"], r["client"], r["workload"])):
            L.append(
                f"| {r['language']} | `{r['client']}` | {r['workload']} | {r.get('verify', '')} | "
                f"{fmt(r.get('accepted'))} | {fmt(r.get('median_ms'))} | {str(r['why']).replace('|', '/')[:300]} |"
            )
        L.append("")

    notes = [r for r in rows if r.get("notes") and r["workload"] == head_wl and (r["harness"], r["client"]) in head_ids]
    if notes:
        L.append("## Notes on the ranked rows\n")
        for r in sorted(notes, key=lambda r: r["median_ms"]):
            L.append(f"- **{r['language']} `{r['client']}`** ({r.get('api', '')}): {r['notes']}")
        L.append("")

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("\n".join(L))
    print(f"report: {out} ({len(ranked)} ranked, {len(bad)} not ranked)")


if __name__ == "__main__":
    main()
