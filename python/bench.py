"""nostrLibBench Python harness. Contract: ../HARNESS.md. Run through ./run.sh.

Without --child the script is the orchestrator: it re-runs itself once per client in a fresh
interpreter (HARNESS.md "Isolation") and merges the rows. With --child <id> it runs one client
on every requested workload and prints its rows as one `@@ROWS <json>` line on stdout.

A client is a `run(ctx)` function (sync or async) that does one run of HARNESS.md "A run":
untimed setup (new client instance, connect), then `ctx.begin()` right before the library's
subscription call, `ctx.event(id_hex)` for every event the library delivers (after the
explicit verify for `verify: explicit` rows), `ctx.eose()` when the app learns of the EOSE,
`ctx.wait()` / `await ctx.wait_async()` until the run is over, then untimed teardown.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import resource
import subprocess
import sys
import threading
import time
from importlib.metadata import version as dist_version
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH = HERE.parent
# Libraries that install a top-level module another library also uses (nostrj ships `nostr`,
# like python-nostr) live in their own `pip install --target` overlay, put first on sys.path
# in that client's child process only.
OVERLAYS = HERE / ".venv" / "overlays"

perf = time.perf_counter
IDLE_S = 1.0  # HARNESS.md: no event for 1 s after EOSE ends a run that can't complete


def cpu_ms():
    r = resource.getrusage(resource.RUSAGE_SELF)
    return (r.ru_utime + r.ru_stime) * 1000.0


class RunTimeout(Exception):
    pass


class Ctx:
    """One run's bookkeeping. `event` and `eose` may be called from any thread."""

    def __init__(self, url, limit, timeout_s, targets):
        self.url = url
        self.limit = limit
        self.timeout_s = timeout_s
        self.full, self.low, self.expired = targets  # complete counts, expired id set
        self.ids = []
        self.n_exp = 0
        self.t0 = self.cpu0 = None
        self.t_last = None
        self.t_eose = None
        self.cpu_eose = None
        self.t_end = self.cpu_end = None
        self.done = threading.Event()
        self._loop = None
        self._aevent = None

    # -- timed part
    def begin(self):
        self.cpu0 = cpu_ms()
        self.t0 = perf()

    def event(self, eid):
        self.t_last = perf()
        self.ids.append(eid)
        if eid in self.expired:
            self.n_exp += 1
        if self.t_eose is not None:
            self._check()

    def eose(self):
        if self.t_eose is None:
            self.t_eose = perf()
            self.cpu_eose = cpu_ms()
            self._check()

    def _check(self):
        n = len(self.ids)
        if n == self.full or (n == self.low and self.n_exp == 0):
            self._finish(cpu_ms())

    def _finish(self, cpu):
        if self.t_end is not None:
            return
        t = self.t_eose if self.t_last is None else max(self.t_eose, self.t_last)
        self.t_end = t
        self.cpu_end = cpu
        self.done.set()
        if self._aevent is not None:
            try:
                self._loop.call_soon_threadsafe(self._aevent.set)
            except RuntimeError:
                pass

    # -- waiting (untimed: t_end was recorded when the run completed)
    def _idle_over(self):
        if self.t_eose is None:
            return False
        last = self.t_eose if self.t_last is None else max(self.t_eose, self.t_last)
        if perf() - last >= IDLE_S:
            # Incomplete set (e.g. a library that rejects the ambiguous event): t_end is the
            # later of EOSE and the last event. CPU is taken at EOSE when every event came
            # before it, else now (then it includes the idle second, see README).
            self._finish(self.cpu_eose if (self.t_last is None or self.t_last <= self.t_eose) else cpu_ms())
            return True
        return False

    def wait(self):
        """Blocks until the run is over (thread-based clients)."""
        while not self.done.wait(0.05):
            if self._idle_over():
                return
            if perf() - self.t0 > self.timeout_s:
                raise RunTimeout(f"no EOSE within {self.timeout_s * 1000:.0f} ms")

    async def wait_async(self):
        self._loop = asyncio.get_running_loop()
        self._aevent = asyncio.Event()
        if self.done.is_set():
            return
        while True:
            try:
                await asyncio.wait_for(self._aevent.wait(), 0.05)
                return
            except asyncio.TimeoutError:
                pass
            if self.done.is_set() or self._idle_over():
                return
            if perf() - self.t0 > self.timeout_s:
                raise RunTimeout(f"no EOSE within {self.timeout_s * 1000:.0f} ms")

    def check_timeout(self):
        if self.t0 is not None and perf() - self.t0 > self.timeout_s:
            raise RunTimeout(f"no EOSE within {self.timeout_s * 1000:.0f} ms")

    def finish_now(self):
        """For clients whose subscription call returns only after EOSE and every event."""
        if self.t_eose is None:
            self.eose()
        if self.t_end is None:
            self._finish(cpu_ms())


# ======================================================================== clients
#
# One function per client. Each imports its library itself, so a broken install only breaks
# its own row. Verification details per library are in README.md.

def _sdk_setup_client(nostr_sdk, ctx, notification_channel=None):
    from datetime import timedelta

    b = nostr_sdk.ClientBuilder()
    if notification_channel:
        b = b.notification_channel_size(notification_channel)
    client = b.build()
    return client, nostr_sdk.RelayUrl.parse(ctx.url), timedelta


async def run_nostr_sdk_stream(ctx):
    import nostr_sdk as ns

    client, url, td = _sdk_setup_client(ns, ctx)
    await client.add_relay(url)
    await client.connect(td(seconds=10))
    filt = ns.Filter().limit(ctx.limit)
    try:
        ctx.begin()
        stream = await client.stream_events(ns.ReqTarget.single(url, [filt]))
        while True:
            item = await stream.next()
            if item is None:
                break
            ev = item.event
            if ev is None:
                raise RuntimeError(f"stream error: {item.error}")
            ctx.event(ev.id().to_hex())
        ctx.eose()  # the stream ends at EOSE (ReqExitPolicy.EXIT_ON_EOSE, the default)
        await ctx.wait_async()
    finally:
        await client.shutdown()


async def run_nostr_sdk_fetch(ctx):
    import nostr_sdk as ns

    client, url, td = _sdk_setup_client(ns, ctx)
    await client.add_relay(url)
    await client.connect(td(seconds=10))
    filt = ns.Filter().limit(ctx.limit)
    try:
        ctx.begin()
        # max_events: the default cap is lower than a workload ("too many fetched events")
        events = await client.fetch_events(ns.ReqTarget.single(url, [filt]), td(seconds=ctx.timeout_s),
                                           max_events=ctx.limit)
        for ev in events:
            ctx.event(ev.id().to_hex())
        ctx.finish_now()
    finally:
        await client.shutdown()


async def run_nostr_sdk_notifications(ctx):
    import nostr_sdk as ns

    # The notification channel is a broadcast channel: a consumer slower than the relay
    # lags and loses notifications, so it is sized to hold every event of the workload.
    client, url, td = _sdk_setup_client(ns, ctx, notification_channel=max(4096, 2 * ctx.limit))
    await client.add_relay(url)
    await client.connect(td(seconds=10))
    filt = ns.Filter().limit(ctx.limit)
    notifications = client.notifications()
    try:
        ctx.begin()
        out = await client.subscribe(ns.ReqTarget.single(url, [filt]))
        sub_id = out.id
        while not ctx.done.is_set():
            n = await asyncio.wait_for(notifications.next(), ctx.timeout_s)
            if n is None:
                break
            if n.is_NEW_EVENT():
                if n.subscription_id == sub_id:
                    ctx.event(n.event.id().to_hex())
            elif n.is_MESSAGE():
                m = n.message.as_enum()
                if m.is_END_OF_STORED_EVENTS() and m.subscription_id == sub_id:
                    ctx.eose()
                    break
        await ctx.wait_async()
        await client.unsubscribe(sub_id)
    finally:
        await client.shutdown()


class _LastLog:
    """Keeps the last warning a library logged, for the row's error."""

    def __init__(self, name):
        import logging

        self.msg = None
        h = logging.Handler(logging.WARNING)
        h.emit = lambda rec: setattr(self, "msg", rec.getMessage())
        logging.getLogger(name).addHandler(h)


def _pynostr_no_eose(ctx, log):
    raise RuntimeError("connection closed before EOSE; pynostr logged: " + (log.msg or "nothing"))


def run_pynostr_callback(ctx):
    from pynostr.filters import Filters, FiltersList
    from pynostr.relay_manager import RelayManager

    # timeout=0: pynostr wraps the whole connection coroutine (connect AND reading every
    # message until EOSE) in its timeout, default 2 s, which a 27 MB subscription exceeds.
    rm = RelayManager(timeout=0)
    log = _LastLog("pynostr")

    def on_message(msg):  # called by pynostr only for messages that passed its checks
        if msg[0] == "EVENT":
            ctx.event(msg[2]["id"])
        elif msg[0] == "EOSE":
            ctx.eose()

    rm.add_relay(ctx.url, close_on_eose=True, message_callback=on_message)
    rm.add_subscription_on_all_relays("bench", FiltersList([Filters(limit=ctx.limit)]))
    ctx.begin()
    rm.run_sync()  # connects (lazily), sends the REQ, reads until EOSE closes the connection
    ctx.check_timeout()
    if ctx.t_eose is None:
        _pynostr_no_eose(ctx, log)
    ctx.wait()
    rm.close_connections()


def run_pynostr_pool(ctx):
    from pynostr.filters import Filters, FiltersList
    from pynostr.relay_manager import RelayManager

    rm = RelayManager(timeout=0)
    log = _LastLog("pynostr")
    rm.add_relay(ctx.url, close_on_eose=True)
    rm.add_subscription_on_all_relays("bench", FiltersList([Filters(limit=ctx.limit)]))
    ctx.begin()
    rm.run_sync()
    pool = rm.message_pool
    while pool.has_events():
        ctx.event(pool.get_event().event.id)
    if not pool.has_eose_notices():
        _pynostr_no_eose(ctx, log)
    ctx.finish_now()
    rm.close_connections()


def _drain_pool(ctx, pool):
    """App side of python-nostr / nostrj: reads MessagePool.events (a queue.Queue filled by the
    websocket thread) until the EOSE shows up in pool.eose_notices."""
    from queue import Empty

    events = pool.events
    while True:
        try:
            m = events.get(timeout=0.005)
        except Empty:
            ctx.check_timeout()
            if pool.has_eose_notices():
                # events and EOSE come from one websocket thread, in order: every event before
                # the EOSE is already queued
                pool.get_eose_notice()
                while True:
                    try:
                        m = events.get_nowait()
                    except Empty:
                        break
                    ctx.event(m.event.id)
                ctx.eose()
                break
            continue
        ctx.event(m.event.id)
    ctx.wait()


def run_python_nostr(ctx):
    from nostr.filter import Filter, Filters
    from nostr.message_type import ClientMessageType
    from nostr.relay_manager import RelayManager

    # python-nostr 0.0.2 README: add_relay, add_subscription, open_connections, then publish the
    # REQ yourself and read relay_manager.message_pool
    rm = RelayManager()
    rm.add_relay(ctx.url)
    filters = Filters([Filter(limit=ctx.limit)])
    rm.add_subscription("bench", filters)
    rm.open_connections()
    relay = rm.relays[ctx.url]
    t = perf()
    while not (relay.ws.sock is not None and relay.ws.sock.connected):
        if perf() - t > 10:
            raise RuntimeError("could not connect")
        time.sleep(0.01)
    try:
        req = json.dumps([ClientMessageType.REQUEST, "bench", *filters.to_json_array()])
        ctx.begin()
        rm.publish_message(req)
        _drain_pool(ctx, rm.message_pool)
    finally:
        rm.close_connections()


def run_nostrj(ctx):
    from nostr.filter import Filter, Filters
    from nostr.relay_manager import RelayManager

    rm = RelayManager()
    rm.add_relay(ctx.url)  # starts the websocket-client thread, then sleeps 1 s
    try:
        filters = Filters([Filter(limit=ctx.limit)])
        ctx.begin()
        rm.add_subscription_on_all_relays("bench", filters)  # REQ goes out from the queue-worker thread
        _drain_pool(ctx, rm.message_pool)
    finally:
        for r in rm.relays.values():
            r.reconnect = False  # Relay reconnects when its connection closes otherwise
        rm.close_all_relay_connections()


def _monstr_client(ctx, **kw):
    from monstr.client.client import Client

    # eose_timeout=None: no forced EOSE; query_timeout as the run timeout
    return Client(ctx.url, query_timeout=ctx.timeout_s, eose_timeout=None, **kw)


def _monstr_verify(ev):
    # Event.is_valid() checks only the signature against the event's id field, so the id is
    # checked too, with monstr's own serializer (Event.serialize) and hash (sha256).
    import hashlib

    try:
        return ev.is_valid() and hashlib.sha256(ev.serialize().encode("utf-8")).hexdigest() == ev.id
    except Exception:  # noqa: BLE001 - "sig": "" raises in bytes.fromhex / schnorr_verify
        return False


async def run_monstr_subscribe(ctx):
    client = _monstr_client(ctx)
    task = asyncio.create_task(client.run())
    try:
        await client.wait_connect(10)

        def on_eose(the_client, sub_id, events):
            # monstr buffers the stored events of a subscription that has an eose_func and
            # hands them over as one list at EOSE (handlers only see events after EOSE)
            for ev in events:
                if _monstr_verify(ev):
                    ctx.event(ev.id)
            ctx.eose()

        ctx.begin()
        client.subscribe(filters={"limit": ctx.limit}, eose_func=on_eose)
        await ctx.wait_async()
    finally:
        client.end()
        await asyncio.wait([task], timeout=5)


async def run_monstr_query(ctx):
    client = _monstr_client(ctx)
    task = asyncio.create_task(client.run())
    try:
        await client.wait_connect(10)
        ctx.begin()
        events = await client.query({"limit": ctx.limit}, timeout=ctx.timeout_s)
        for ev in events:
            if _monstr_verify(ev):
                ctx.event(ev.id)
        ctx.finish_now()
    finally:
        client.end()
        await asyncio.wait([task], timeout=5)


async def run_aionostr(ctx):
    from aionostr.event import Event
    from aionostr.relay import Manager

    mgr = Manager([ctx.url])
    await mgr.connect()
    try:
        ctx.begin()
        async for ev in mgr.get_events({"limit": ctx.limit}):
            # Event.verify() checks the signature against a recomputed id but never compares
            # that id with the event's own id field: the harness does, with Event.compute_id.
            try:
                ok = ev.verify() and Event.compute_id(ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content) == ev.id
            except Exception:  # noqa: BLE001 - "sig": "" raises
                ok = False
            if ok:
                ctx.event(ev.id)
        ctx.eose()  # get_events(only_stored=True) ends at EOSE
        await ctx.wait_async()
    finally:
        await mgr.close()


async def run_electrum_aionostr(ctx):
    from electrum_aionostr.relay import Manager

    mgr = Manager([ctx.url], connect_timeout=10)
    await mgr.connect()
    try:
        ctx.begin()
        async for ev in mgr.get_events({"limit": ctx.limit}, filter_future_events_sec=None):
            ctx.event(ev.id)
        ctx.eose()
        await ctx.wait_async()
    finally:
        await mgr.close()


async def run_nostr_tools(ctx):
    from nostr_tools import Client, Filter, Relay, stream_events

    client = Client(Relay(ctx.url))
    await client.connect()
    try:
        ctx.begin()
        async for ev in stream_events(client, Filter(limit=ctx.limit)):
            ctx.event(ev.id)
        ctx.eose()  # stream_events ends at EOSE (Client.listen_events)
        await ctx.wait_async()
    finally:
        await client.disconnect()


def run_nostrclient(ctx):
    from nostrclient.event import Event
    from nostrclient.relay import Relay

    relay = Relay(ctx.url)
    relay.connect(10)
    if not relay.connected:
        raise RuntimeError("could not connect")
    try:
        def on_event(e):
            # Event.verify() checks the signature against Event.id, a property that always
            # recomputes the id from the fields; the harness compares it with the event's id.
            try:
                ev = Event(e["content"], e["pubkey"], e["created_at"], e["kind"], e["tags"], e["sig"])
                ok = ev.verify() and ev.id == e["id"]
            except Exception:  # noqa: BLE001 - "sig": "" raises
                ok = False
            if ok:
                ctx.event(e["id"])

        ctx.begin()
        sub = relay.subscribe({"limit": ctx.limit})
        sub.on("EVENT", on_event)
        relay.on("EOSE" + sub.subid, lambda _arg: ctx.eose())
        ctx.wait()
    finally:
        relay.close()


async def run_basic_nostr(ctx):
    import hashlib

    import websockets
    from basic_nostr import basic_nostr as bn
    from coincurve import PublicKeyXOnly

    # basic_nostr.connect_to_relays always passes an SSL context, which websockets refuses for a
    # ws:// URL, so the app opens the connection the same way minus ssl and hands the
    # (url, websocket) pair to read_events_from_relays, which takes exactly that.
    relays = [(ctx.url, await websockets.connect(ctx.url))]
    try:
        ctx.begin()
        events = await bn.read_events_from_relays(relays, limit=ctx.limit)
        ctx.eose()  # read_events_from_relays returns after EOSE (or a 10 s silence)
        for e in events:
            # basic-nostr has no verify for fetched events: the harness checks id + sig
            try:
                ser = json.dumps([0, e["pubkey"], e["created_at"], e["kind"], e["tags"], e["content"]],
                                 separators=(",", ":"), ensure_ascii=False).encode()
                idb = hashlib.sha256(ser).digest()
                ok = idb.hex() == e["id"] and PublicKeyXOnly(bytes.fromhex(e["pubkey"])).verify(
                    bytes.fromhex(e["sig"]), idb)
            except Exception:  # noqa: BLE001
                ok = False
            if ok:
                ctx.event(e["id"])
        ctx.finish_now()
    finally:
        for _url, ws in relays:
            await ws.close()


# ---------------------------------------------------------------------- client table

SECP_PY = "libsecp256k1 (C, bundled in secp256k1-py 0.14.0, cffi)"
COINCURVE = "libsecp256k1 @1ad5185 (C, bundled in coincurve 21.0.0, cffi)"

CLIENTS = [
    dict(id="nostr-sdk-notifications", library="nostr-sdk", dist="nostr-sdk", license="MIT",
         run=run_nostr_sdk_notifications,
         api="Client.subscribe(ReqTarget.single(url, [filter])) + Client.notifications().next(): NEW_EVENT until "
             "the MESSAGE carrying EOSE",
         websocket="async-wsocket / tokio-tungstenite (Rust, inside the UniFFI .so)",
         crypto="libsecp256k1 (C, via the Rust secp256k1 crate, inside the UniFFI .so)", verify="library",
         notes="rust-nostr 0.45 through its UniFFI Python bindings: relay I/O, parsing and verification run on "
               "tokio threads; each notification crosses the FFI (a NEW_EVENT plus a MESSAGE for every EVENT "
               "frame), id via Event.id().to_hex(). The stream handle_notifications wraps. "
               "notification_channel_size raised to 2x the workload (a broadcast channel drops what a slow "
               "consumer has not read). Drops expired (NIP-40) events. New Client per run. Headline row because "
               "stream_events loses events with a Python consumer (see nostr-sdk-stream)."),
    dict(id="nostr-sdk-stream", library="nostr-sdk", dist="nostr-sdk", license="MIT", run=run_nostr_sdk_stream,
         variant=True,
         api="Client.stream_events(ReqTarget.single(url, [filter])) + ClientEventStream.next() until it ends",
         websocket="async-wsocket / tokio-tungstenite (Rust, inside the UniFFI .so)",
         crypto="libsecp256k1 (C, via the Rust secp256k1 crate, inside the UniFFI .so)", verify="library",
         notes="short-lived stream, ends at EOSE. When the Python consumer falls behind the relay (per-event FFI "
               "await ~60-120 us vs the Rust reader), the stream ends early, with no error item, after a few "
               "thousand events (reproduced with a 0.1 ms sleep per event: 2,558 of 29,548; under machine load "
               "without any sleep: 12,979 then 9,073). notification_channel_size does not change it, so this is "
               "presumably the relay's internal notification broadcast channel lagging. Diagnostic row."),
    dict(id="nostr-sdk-fetch", library="nostr-sdk", dist="nostr-sdk", license="MIT", run=run_nostr_sdk_fetch,
         variant=True, api="Client.fetch_events(ReqTarget.single(...), timeout) -> list after EOSE",
         websocket="async-wsocket / tokio-tungstenite (Rust, inside the UniFFI .so)",
         crypto="libsecp256k1 (C, via the Rust secp256k1 crate, inside the UniFFI .so)", verify="library",
         notes="fetch-all: the list arrives after EOSE; max_events raised to the workload size (the default cap "
               "fails the `all` workload with 'too many fetched events')"),
    dict(id="pynostr-callback", library="pynostr", dist="pynostr", license="MIT", run=run_pynostr_callback,
         api="RelayManager.add_relay(message_callback=...) + add_subscription_on_all_relays + run_sync()",
         websocket="tornado 6.6 websocket_connect (pure Python on asyncio)", crypto=COINCURVE, verify="library",
         notes="pynostr verifies every EVENT (Event.from_dict recomputes the id from the fields; verify() checks "
               "the sig with coincurve) before calling message_callback with the parsed message; the id counted "
               "is the message's id field (the callback gets the JSON list, not the Event). RelayManager(timeout=0): "
               "the default 2 s timeout covers the whole read loop. Connects lazily inside run_sync: the connect "
               "is inside the timed part (~1 ms on loopback). Each frame is json.loads-ed three times by pynostr."),
    dict(id="pynostr-pool", library="pynostr", dist="pynostr", license="MIT", run=run_pynostr_pool, variant=True,
         api="RelayManager + add_subscription_on_all_relays + run_sync() + message_pool.get_event() (README idiom)",
         websocket="tornado 6.6 websocket_connect (pure Python on asyncio)", crypto=COINCURVE, verify="library",
         notes="same pipeline as pynostr-callback; the app drains the MessagePool's Event objects after run_sync "
               "returns at EOSE (the pool parses each frame again into an Event, id recomputed)"),
    dict(id="python-nostr", library="nostr (python-nostr)", dist="nostr", license="MIT", run=run_python_nostr,
         api="RelayManager.add_relay + add_subscription + open_connections + publish_message(REQ) + "
             "message_pool.events queue (README idiom)",
         websocket="websocket-client 1.9 WebSocketApp (pure Python, one thread per relay)", crypto=SECP_PY,
         verify="library",
         notes="jeffthibault/python-nostr 0.0.2 (Jan 2023, the PyPI `nostr` package, unmaintained). "
               "Relay._is_valid_message verifies every event (Event.verify recomputes the id and checks the sig "
               "against it; the id compared is that recomputed one, the Event keeps the wire id) and matches the "
               "filter, then the MessagePool parses the frame again. An exception in verify (\"sig\": \"\") is "
               "swallowed by websocket-client's callback wrapper, dropping that event. Bug: Event() turns "
               "created_at 0 into now (`created_at or int(time.time())`), so a valid event with created_at 0 fails "
               "verification and is dropped. The app reads the pool's queue from the main thread (5 ms poll when "
               "empty)."),
    dict(id="nostrj", library="nostrj", dist="nostrj", license="MIT", run=run_nostrj, overlay="nostrj",
         api="RelayManager.add_relay + add_subscription_on_all_relays + message_pool.events queue",
         websocket="websocket-client 1.9 WebSocketApp (pure Python, one thread per relay)", crypto=SECP_PY,
         verify="library",
         notes="maintained fork of python-nostr (gitlab 1440000bytes/python-nostr, 2026); same `nostr` module "
               "name, so it is installed in its own overlay. Relay verifies every event (the Event id is always "
               "computed from the fields, sig checked against it) inside a try/except that rejects anything that "
               "raises, and matches the filter. add_relay sleeps 1 s (untimed); the REQ goes out from a "
               "queue-worker thread that polls every 0.1 s while disconnected and is left behind (daemon) after "
               "each run. App reads the pool's queue (5 ms poll when empty)."),
    dict(id="monstr-subscribe", library="monstr", dist="monstr", license="MIT", run=run_monstr_subscribe,
         api="Client.run() + Client.subscribe(filters, eose_func=...): stored events handed over as a list at EOSE",
         websocket="aiohttp 3.14 ws_connect", crypto=SECP_PY, verify="explicit",
         notes="monstr's Client does not verify received events; the harness calls Event.is_valid() (sig "
               "against the id field) and checks the id with Event.serialize() + sha256. Client(eose_timeout=None)."),
    dict(id="monstr-query", library="monstr", dist="monstr", license="MIT", run=run_monstr_query, variant=True,
         api="await Client.query(filters) -> list after EOSE", websocket="aiohttp 3.14 ws_connect", crypto=SECP_PY,
         verify="explicit",
         notes="fetch-all; query() polls for completion every 100 ms, so up to 0.1 s of each run is that sleep. "
               "Verification as monstr-subscribe."),
    dict(id="aionostr", library="aionostr", dist="aionostr", license="BSD-3-Clause", run=run_aionostr,
         api="Manager([url]).get_events(filter) async generator (ends at EOSE)",
         websocket="websockets 17 (asyncio client)", crypto=COINCURVE, verify="explicit",
         notes="aionostr does not verify received events; the harness calls Event.verify() (sig against an id "
               "it recomputes with json.dumps compact, ensure_ascii=False) and compares Event.compute_id(...) with "
               "the event's id field, which verify() never does. Bug: Event() turns created_at 0 into now "
               "(`created_at or int(time.time())`), so a valid event with created_at 0 fails verification."),
    dict(id="electrum-aionostr", library="electrum-aionostr", dist="electrum-aionostr", license="BSD-3-Clause",
         run=run_electrum_aionostr, api="Manager([url]).get_events(filter) async generator (ends at EOSE)",
         websocket="aiohttp 3.14 ws_connect", crypto="libsecp256k1 (C, bundled in electrum-ecc 0.0.8, ctypes)",
         verify="library",
         notes="Electrum's fork of aionostr: Event() recomputes the id and verifies the sig on construction. "
               "Relay._receive_messages sleeps 5 ms before every message (CPU-DOS mitigation) and 5 s after any "
               "exception, and an event without a valid sig raises (ValueError 'missing sig'), so each of the "
               "1547 unsigned events costs 5 s. get_events(filter_future_events_sec=None)."),
    dict(id="nostr-tools", library="nostr-tools", dist="nostr-tools", license="MIT", run=run_nostr_tools,
         api="Client(Relay(url)).connect() + stream_events(client, Filter(limit)) async generator (ends at EOSE)",
         websocket="aiohttp 3.14 ws_connect", crypto=SECP_PY, verify="library",
         notes="bigbrotr/nostr-tools: Event.from_dict validates on construction (field formats, id recomputed, "
               "sig) and rejects empty tags and content/tags containing the text \\u0000 (a literal backslash-u: the "
               "real U+0000 of the ambiguous event passes, while a valid kind 4550 event whose content is escaped "
               "JSON holding \\u0000 is rejected); on failure it 'unescapes' content/tags and validates "
               "again, then stream_events logs the EventValidationError with a traceback (logger.exception) for "
               "every invalid event: formatted by logging's default last-resort handler, sent to /dev/null."),
    dict(id="nostrclient", library="nostrclient", dist="nostrclient", license="Unlicense", run=run_nostrclient,
         api="Relay(url).connect() + relay.subscribe(filter) + sub.on('EVENT') / relay.on('EOSE'+subid)",
         websocket="websocket-client 1.9 WebSocketApp (pure Python, thread)", crypto=SECP_PY, verify="explicit",
         notes="nostrclient does not verify received events; the harness builds nostrclient.event.Event from the "
               "dict, calls verify() (sig against the recomputed id) and compares that id with the id field. "
               "Events reach the app through an emitter thread; Subscription dedups with a list (linear scan, "
               "reset at 10 000 ids)."),
    dict(id="basic-nostr", library="basic-nostr", dist="basic-nostr", license="MIT", run=run_basic_nostr,
         api="read_events_from_relays([(url, websocket)], limit) -> deduplicated, sorted list",
         websocket="websockets 17 (asyncio client)", crypto=COINCURVE, verify="harness",
         notes="connect_to_relays() cannot open a ws:// URL (it always passes ssl=, which websockets rejects), so "
               "the harness opens the websockets connection itself, as connect_to_relays does minus ssl (untimed). "
               "Fetch-only API, no verification of fetched events (its private _verify_event_signature is "
               "sig-only and used for NIP-17 seals); the harness verifies id (json.dumps compact, "
               "ensure_ascii=False, sha256) and sig (coincurve PublicKeyXOnly.verify)."),
]
BY_ID = {c["id"]: c for c in CLIENTS}


def lib_version(c):
    try:
        return dist_version(c["dist"])
    except Exception:  # noqa: BLE001
        return None


# ======================================================================== child

def xor_hex(ids):
    x = 0
    for i in ids:
        x ^= int(i, 16)
    return f"{x:064x}"


def median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def one_run(c, ctx):
    fn = c["run"]
    if asyncio.iscoroutinefunction(fn):
        async def main():
            try:
                await asyncio.wait_for(fn(ctx), ctx.timeout_s + 15)
            except asyncio.TimeoutError:
                if ctx.t_end is not None:
                    raise RuntimeError("teardown hung") from None
                raise RunTimeout(f"no EOSE within {ctx.timeout_s * 1000:.0f} ms") from None

        asyncio.run(main())
    else:
        fn(ctx)
    if ctx.t_end is None:
        raise RuntimeError("run ended without EOSE")


def run_child(opts, workloads):
    c = BY_ID[opts.child]
    import logging

    # Libraries that log per event (nostr-tools logs a traceback per invalid event) keep paying
    # for formatting the record, but the default last-resort handler writes to /dev/null
    # instead of flooding the harness output.
    logging.lastResort = logging.StreamHandler(open(os.devnull, "w", encoding="utf-8"))
    logging.lastResort.setLevel(logging.WARNING)
    if c.get("overlay"):
        sys.path.insert(0, str(OVERLAYS / c["overlay"]))
    base = dict(client=c["id"], library=c["library"], version=lib_version(c), license=c["license"], api=c["api"],
                websocket=c["websocket"], crypto=c["crypto"], verify=c["verify"], notes=c["notes"],
                variant=bool(c.get("variant", False)))
    rows = []
    for w in workloads:
        row = dict(base, workload=w["name"], events=w["events"], bytes=w["bytes"], accepted=None, accepted_xor=None,
                   ambiguous_accepted=None, expired_accepted=None, accepted_ok=False, errors=0, error=None,
                   warmup_runs=0, runs=0, first_run_ms=None, median_ms=None, min_ms=None, p90_ms=None, run_ms=[],
                   events_per_s=None, us_per_event=None, cpu_ms=None, peak_rss_mb=None)
        rows.append(row)
        amb = set(w["ambiguous_ids"])
        exp = set(w.get("expired_ids", []))
        full = w["valid_events"] + len(amb)
        targets = (full, full - len(exp), exp)
        url = f"{opts.relay.rstrip('/')}/{w['name']}"
        first_set = None
        times, cpus = [], []
        measured_ms = 0.0
        i = 0
        while True:
            warm = i < opts.warmup_runs
            ctx = Ctx(url, w["events"], opts.timeout_ms / 1000.0, targets)
            try:
                one_run(c, ctx)
            except BaseException as ex:  # noqa: BLE001 - reported in the row
                if isinstance(ex, KeyboardInterrupt):
                    raise
                row["errors"] += 1
                row["error"] = f"run {i + 1}: {type(ex).__name__}: {ex}"[:500]
                break
            ms = (ctx.t_end - ctx.t0) * 1000.0
            cms = ctx.cpu_end - ctx.cpu0
            ids = ctx.ids
            if first_set is None:
                first_set = ids
                acc_set = set(ids)
                row["accepted"] = len(ids)
                row["accepted_xor"] = xor_hex(ids)
                row["ambiguous_accepted"] = len(acc_set & amb)
                row["expired_accepted"] = len(acc_set & exp)
                dropped_exp = exp - acc_set
                want_xor = int(w["valid_id_xor"], 16)
                for e in dropped_exp:
                    want_xor ^= int(e, 16)
                for a in acc_set & amb:
                    want_xor ^= int(a, 16)
                ea = row["expired_accepted"]
                row["accepted_ok"] = (len(acc_set) == len(ids)
                                      and ea in (0, len(exp))
                                      and len(ids) == w["valid_events"] - len(exp) + ea + row["ambiguous_accepted"]
                                      and int(row["accepted_xor"], 16) == want_xor)
                row["first_run_ms"] = round(ms, 3)
            elif len(ids) != len(first_set) or set(ids) != set(first_set):
                row["errors"] += 1
                row["error"] = f"run {i + 1} delivered a different set ({len(ids)} events, first run {len(first_set)})"
                break
            print(f"  python {c['id']:<24} {w['name']:<8} {'warmup' if warm else 'run':<6} {i + 1:>2} "
                  f"{ms:9.1f} ms  cpu {cms:9.1f} ms  accepted {len(ids)}", file=sys.stderr, flush=True)
            if warm:
                row["warmup_runs"] += 1
            else:
                times.append(ms)
                cpus.append(cms)
                measured_ms += ms
            i += 1
            n = len(times)
            if n >= opts.max_runs or (n >= opts.min_runs and measured_ms >= opts.min_time_ms):
                break
        row["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0, 1)
        if row["error"] is None and times:
            med = median(times)
            s = sorted(times)
            row.update(runs=len(times), run_ms=[round(t, 3) for t in times], median_ms=round(med, 3),
                       min_ms=round(s[0], 3), p90_ms=round(s[max(0, -(-9 * len(s) // 10) - 1)], 3),
                       events_per_s=round(w["events"] / (med / 1000.0), 1),
                       us_per_event=round(med * 1000.0 / w["events"], 3), cpu_ms=round(median(cpus), 3))
        else:
            row.update(runs=len(times), run_ms=[round(t, 3) for t in times])
    print("@@ROWS " + json.dumps(rows), flush=True)
    sys.stdout.flush()
    sys.stderr.flush()
    # Library threads (websocket-client, tornado, tokio) may still be alive: don't wait for them.
    os._exit(0)


# ======================================================================== orchestrator

def host_info():
    cpu = platform.processor() or "unknown"
    try:
        for line in open("/proc/cpuinfo", encoding="utf-8"):
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    return {"cpu": cpu, "cores": os.cpu_count(), "os": f"{platform.system()} {platform.release()}"}


def parse_args(argv):
    ap = argparse.ArgumentParser(description="nostrLibBench Python harness")
    ap.add_argument("--relay", default="ws://127.0.0.1:7777")
    ap.add_argument("--corpus", type=Path, default=Path(".corpus"))
    ap.add_argument("--out", type=Path, default=Path("results/python.json"))
    ap.add_argument("--workloads", default="all")
    ap.add_argument("--clients")
    ap.add_argument("--warmup-runs", type=int, default=2)
    ap.add_argument("--min-runs", type=int, default=5)
    ap.add_argument("--min-time-ms", type=int, default=10000)
    ap.add_argument("--max-runs", type=int, default=30)
    ap.add_argument("--timeout-ms", type=int, default=300000)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--child")
    o = ap.parse_args(argv)
    if o.quick:
        o.warmup_runs, o.min_runs, o.min_time_ms = 1, 2, 0
    o.max_runs = max(o.max_runs, 1)
    o.min_runs = min(max(o.min_runs, 1), o.max_runs)
    o.corpus = o.corpus.resolve()
    o.out = o.out.resolve()
    return o


def child_args(opts, workloads):
    return ["--relay", opts.relay, "--corpus", str(opts.corpus), "--workloads", ",".join(w["name"] for w in workloads),
            "--warmup-runs", str(opts.warmup_runs), "--min-runs", str(opts.min_runs),
            "--min-time-ms", str(opts.min_time_ms), "--max-runs", str(opts.max_runs),
            "--timeout-ms", str(opts.timeout_ms)]


def failed_rows(c, workloads, why):
    rows = []
    for w in workloads:
        rows.append(dict(client=c["id"], library=c["library"], version=lib_version(c), license=c["license"],
                         api=c["api"], websocket=c["websocket"], crypto=c["crypto"], verify=c["verify"],
                         notes=c["notes"], variant=bool(c.get("variant", False)), workload=w["name"],
                         events=w["events"], bytes=w["bytes"], accepted=None, accepted_xor=None,
                         ambiguous_accepted=None, expired_accepted=None, accepted_ok=False, errors=1, error=why,
                         warmup_runs=0, runs=0, first_run_ms=None, median_ms=None, min_ms=None, p90_ms=None,
                         run_ms=[], events_per_s=None, us_per_event=None, cpu_ms=None, peak_rss_mb=None))
    return rows


def main(argv):
    opts = parse_args(argv)
    if opts.list:
        for c in CLIENTS:
            print(c["id"])
        return 0
    mpath = opts.corpus / "manifest.json"
    if not mpath.exists():
        sys.exit(f"no corpus at {opts.corpus}: run python3 corpus/prepare.py")
    manifest = json.loads(mpath.read_text(encoding="utf-8"))
    by_name = {w["name"]: w for w in manifest["workloads"]}
    names = opts.workloads.split(",")
    unknown = [n for n in names if n not in by_name]
    if unknown:
        sys.exit(f"unknown workload(s): {unknown}")
    workloads = [by_name[n] for n in names]

    if opts.child:
        if opts.child not in BY_ID:
            sys.exit(f"unknown client {opts.child}")
        run_child(opts, workloads)
        return 0

    clients = CLIENTS
    if opts.clients:
        ids = opts.clients.split(",")
        unknown = [i for i in ids if i not in BY_ID]
        if unknown:
            sys.exit(f"unknown client(s): {unknown}")
        clients = [c for c in CLIENTS if c["id"] in ids]

    results = []
    # A child that wedges past every run's timeout is killed: per workload, the most runs a
    # child can do, each bounded by --timeout-ms, plus setup slack.
    budget = len(workloads) * (opts.warmup_runs + opts.max_runs) * (opts.timeout_ms / 1000.0 + 20) + 60
    for c in clients:
        print(f"[python] {c['id']}", file=sys.stderr, flush=True)
        try:
            r = subprocess.run([sys.executable, __file__, *child_args(opts, workloads), "--child", c["id"]],
                               stdout=subprocess.PIPE, stderr=None, text=True, check=False, timeout=budget)
            out, code = r.stdout, r.returncode
        except subprocess.TimeoutExpired as ex:
            out, code = (ex.stdout or b"").decode() if isinstance(ex.stdout, bytes) else (ex.stdout or ""), "timeout"
        line = next((ln for ln in out.splitlines() if ln.startswith("@@ROWS ")), None)
        if line:
            results.extend(json.loads(line[7:]))
            continue
        why = f"child process failed ({code})"
        print(f"  {why}", file=sys.stderr)
        results.extend(failed_rows(c, workloads, why))

    doc = {
        "harness": "python",
        "language": "Python",
        "runtime": f"CPython {platform.python_version()}",
        "host": host_info(),
        "settings": {"warmup_runs": opts.warmup_runs, "min_runs": opts.min_runs, "min_time_ms": opts.min_time_ms,
                     "max_runs": opts.max_runs, "timeout_ms": opts.timeout_ms},
        "relay": opts.relay,
        "corpus_fingerprint": manifest.get("fingerprint"),
        "results": results,
    }
    opts.out.parent.mkdir(parents=True, exist_ok=True)
    opts.out.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {opts.out}", file=sys.stderr)
    for r in results:
        med = "-" if r["median_ms"] is None else f"{r['median_ms']:.1f} ms"
        print(f"  {r['client']:<24} {r['workload']:<8} {med:>12}  accepted={r['accepted']} ok={r['accepted_ok']}"
              f"{'' if r['error'] is None else '  ERROR ' + r['error']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
