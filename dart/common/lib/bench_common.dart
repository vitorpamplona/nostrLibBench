/// nostrLibBench Dart harness: the code shared by every client binary.
///
/// Each client library is its own package (clients/<lib>/) with its own pubspec.lock, AOT
/// compiled (`dart compile exe`) into build/<lib>. Its binary runs in two modes, both driven by
/// the orchestrator (bench/):
///   --list-json                     print the clients of this binary with their metadata
///   --child <client> --workload ... run one client on one workload (fresh process) and write
///                                   one result row as JSON to --result <file>
/// A run follows HARNESS.md "A run": untimed setup (new client + connect), timed subscription
/// until EOSE and the last accepted event, untimed teardown.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One client entry: a library driven through one of its subscription APIs.
abstract class BenchClient {
  String get id;
  String get library;

  /// pub package whose resolved version (pubspec.lock) is the row's version.
  String get package;
  String get license;
  String get api;

  /// "{pkg}" is replaced with that package's resolved version.
  String get websocket;
  String get crypto;
  String get verify;
  String get notes => '';
  bool get variant => false;

  /// Untimed: create a new client instance and connect it (when the API allows).
  Future<void> setup(Uri url, RunCtx ctx);

  /// Timed: call ctx.start() right before the library's subscription call, then report each
  /// delivered event with ctx.event(id) (after the library's own verify for `explicit` rows)
  /// and the EOSE with ctx.eose(). The future may complete at EOSE or never; the driver
  /// decides when the run is over and then calls teardown().
  Future<void> run(RunCtx ctx);

  /// Untimed: close the subscription and the client.
  Future<void> teardown();
}

final Stopwatch _clock = Stopwatch()..start();
int nowUs() => _clock.elapsedMicroseconds;

final int _clkTck = () {
  try {
    final r = Process.runSync('getconf', ['CLK_TCK']);
    return int.parse((r.stdout as String).trim());
  } catch (_) {
    return 100;
  }
}();

/// Process CPU time (user + system, all threads) in ms, from /proc/self/stat.
double cpuMs() {
  final s = File('/proc/self/stat').readAsStringSync();
  final f = s.substring(s.lastIndexOf(')') + 2).split(' ');
  // fields after "pid (comm) ": state=0 ... utime=11, stime=12
  final ticks = int.parse(f[11]) + int.parse(f[12]);
  return ticks * 1000.0 / _clkTck;
}

double peakRssMb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmHWM:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]) / 1024.0;
      }
    }
  } catch (_) {}
  return 0;
}

class Workload {
  final String name;
  final int events, validEvents, bytes;
  final String validIdXor;
  final List<String> ambiguousIds, expiredIds;
  Workload(this.name, this.events, this.validEvents, this.bytes, this.validIdXor, this.ambiguousIds,
      this.expiredIds);

  static (String, List<Workload>) loadManifest(String corpusDir) {
    final doc = jsonDecode(File('$corpusDir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    final list = <Workload>[
      for (final w in doc['workloads'] as List)
        Workload(
          w['name'] as String,
          w['events'] as int,
          w['valid_events'] as int,
          w['bytes'] as int,
          w['valid_id_xor'] as String,
          [for (final x in (w['ambiguous_ids'] as List? ?? [])) x as String],
          [for (final x in (w['expired_ids'] as List? ?? [])) x as String],
        )
    ];
    return ((doc['fingerprint'] as String?) ?? '', list);
  }

  String expectedXor(bool ambiguousAccepted, bool expiredAccepted) {
    final x = _hex(validIdXor);
    void xor(String id) {
      final b = _hex(id);
      for (var i = 0; i < 32; i++) {
        x[i] ^= b[i];
      }
    }

    if (ambiguousAccepted) ambiguousIds.forEach(xor);
    if (!expiredAccepted) expiredIds.forEach(xor);
    return _toHex(x);
  }
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Per-run bookkeeping: the accepted set, the EOSE and the timestamps.
class RunCtx {
  final Set<String> _ambiguous, _expired;
  final int _complete; // valid + every ambiguous: nothing more can arrive
  final int events, limit;
  final Completer<void> _done = Completer<void>();
  int t0 = 0, eoseUs = 0, lastEventUs = 0, lastActivityUs = 0;
  double cpu0 = 0, cpuEose = 0, cpuDone = 0;
  bool cpuDoneSet = false, eoseSeen = false, started = false, eventAfterEose = false;
  int accepted = 0, rejected = 0, ambiguousAccepted = 0, expiredAccepted = 0;
  // the XOR of the accepted ids, as 8 x 32-bit words (AOT ints are 64-bit, but hex parsing
  // of 64-bit chunks overflows signed ints; 32-bit chunks keep it simple)
  final Uint32List _x = Uint32List(8);
  Object? failure;

  RunCtx(Workload w)
      : _ambiguous = w.ambiguousIds.toSet(),
        _expired = w.expiredIds.toSet(),
        _complete = w.validEvents + w.ambiguousIds.length,
        events = w.events,
        limit = w.events;

  Future<void> get done => _done.future;

  /// t0: right before the library's subscription call.
  void start() {
    cpu0 = cpuMs();
    t0 = nowUs();
    lastActivityUs = t0;
    started = true;
  }

  /// The library delivered an event (already verified) with this id hex.
  void event(String id) {
    final now = nowUs();
    accepted++;
    if (id.length != 64) throw FormatException('event id is not 64 hex chars: $id');
    for (var i = 0; i < 8; i++) {
      _x[i] ^= int.parse(id.substring(8 * i, 8 * i + 8), radix: 16);
    }
    lastEventUs = now;
    lastActivityUs = now;
    if (_ambiguous.contains(id)) ambiguousAccepted++;
    if (_expired.contains(id)) expiredAccepted++;
    if (eoseSeen) eventAfterEose = true;
    if (eoseSeen && accepted >= _complete) _finish();
  }

  /// The harness dropped an event its explicit verify rejected.
  void reject() {
    rejected++;
    lastActivityUs = nowUs();
  }

  void eose() {
    if (eoseSeen) return;
    final now = nowUs();
    eoseSeen = true;
    eoseUs = now;
    cpuEose = cpuMs();
    if (now > lastActivityUs) lastActivityUs = now;
    if (accepted >= _complete) _finish();
  }

  void fail(Object e) {
    failure ??= e;
    if (!_done.isCompleted) _done.complete();
  }

  void _finish() {
    if (!cpuDoneSet) {
      cpuDone = cpuMs();
      cpuDoneSet = true;
    }
    if (!_done.isCompleted) _done.complete();
  }

  String get xorHex => _x.map((w) => w.toRadixString(16).padLeft(8, '0')).join();
}

class Settings {
  final int warmupRuns, minRuns, minTimeMs, maxRuns, timeoutMs;
  Settings(this.warmupRuns, this.minRuns, this.minTimeMs, this.maxRuns, this.timeoutMs);
}

class _RunResult {
  final double ms, cpuMs;
  final int accepted, ambiguous, expired;
  final String xor;
  _RunResult(this.ms, this.cpuMs, this.accepted, this.ambiguous, this.expired, this.xor);
}

Map<String, String> _resolved = {};

String _expand(String s) =>
    s.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) => _resolved[m[1]!] ?? '?');

/// Resolved versions from a pubspec.lock (a YAML file; the few lines needed are parsed by hand).
Map<String, String> readPubspecLock(String path) {
  final map = <String, String>{};
  final f = File(path);
  if (!f.existsSync()) return map;
  String? current;
  for (final line in f.readAsLinesSync()) {
    final pkg = RegExp(r'^  ([A-Za-z0-9_]+):$').firstMatch(line);
    if (pkg != null) {
      current = pkg[1];
      continue;
    }
    final ver = RegExp(r'^    version: "?([^"]+)"?$').firstMatch(line);
    if (ver != null && current != null) map[current] = ver[1]!;
  }
  return map;
}

Map<String, Object?> meta(BenchClient c) => {
      'client': c.id,
      'library': c.library,
      'version': _resolved[c.package] ?? '?',
      'license': c.license,
      'api': c.api,
      'websocket': _expand(c.websocket),
      'crypto': _expand(c.crypto),
      'verify': c.verify,
      'notes': _expand(c.notes),
      'variant': c.variant,
    };

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Entry point of every client binary.
Future<void> childMain(List<String> args, List<BenchClient> clients) async {
  final lock = _arg(args, '--lockfile');
  if (lock != null) _resolved = readPubspecLock(lock);
  if (args.contains('--list-json')) {
    stdout.write(jsonEncode([for (final c in clients) meta(c)]));
    await stdout.flush();
    exit(0);
  }
  String req(String name) => _arg(args, name) ?? (throw ArgumentError('missing $name'));
  final id = req('--child');
  final client = clients.firstWhere((c) => c.id == id);
  final (_, workloads) = Workload.loadManifest(req('--corpus'));
  final w = workloads.firstWhere((x) => x.name == req('--workload'));
  final relay = req('--relay');
  final url = Uri.parse('${relay.endsWith('/') ? relay.substring(0, relay.length - 1) : relay}/${w.name}');
  final s = Settings(int.parse(req('--warmup-runs')), int.parse(req('--min-runs')),
      int.parse(req('--min-time-ms')), int.parse(req('--max-runs')), int.parse(req('--timeout-ms')));
  Map<String, Object?> row;
  try {
    row = await _measure(client, w, url, s);
  } catch (e) {
    row = errorRow(client, w, '$e');
  }
  File(req('--result')).writeAsStringSync(jsonEncode(row));
  // Libraries may leave timers, sockets or isolates behind: leave hard.
  exit(0);
}

Future<_RunResult> _oneRun(BenchClient client, Workload w, Uri url, Settings s) async {
  final ctx = RunCtx(w);
  final timeout = Duration(milliseconds: s.timeoutMs);
  await client.setup(url, ctx).timeout(timeout,
      onTimeout: () => throw TimeoutException('setup (connect) did not finish within ${s.timeoutMs} ms'));

  Future<void> run;
  try {
    run = client.run(ctx);
  } catch (e) {
    run = Future.error(e);
  }
  var runDone = false;
  run.then((_) => runDone = true, onError: (Object e, StackTrace st) {
    runDone = true;
    ctx.fail(e);
  });

  const idleUs = 1000000; // 1 s without events after EOSE: the run is over
  while (true) {
    await Future.any([ctx.done, Future<void>.delayed(const Duration(milliseconds: 20))]);
    if (ctx.failure != null) break;
    if (ctx._done.isCompleted) break;
    final now = nowUs();
    if (!ctx.started) {
      if (runDone) break;
      continue;
    }
    if (ctx.eoseSeen && now - ctx.lastActivityUs >= idleUs) break;
    if (now - ctx.t0 > s.timeoutMs * 1000) break;
  }
  final cpuDetect = cpuMs();
  final tEnd = ctx.eoseUs > ctx.lastEventUs ? ctx.eoseUs : ctx.lastEventUs;
  final cpuEnd = ctx.cpuDoneSet ? ctx.cpuDone : (ctx.eventAfterEose ? cpuDetect : ctx.cpuEose);
  final r = _RunResult((tEnd - ctx.t0) / 1000.0, cpuEnd - ctx.cpu0, ctx.accepted, ctx.ambiguousAccepted,
      ctx.expiredAccepted, ctx.xorHex);
  try {
    await client.teardown().timeout(const Duration(seconds: 5));
  } catch (_) {/* teardown errors do not fail a run */}
  if (ctx.failure != null) throw Exception('run failed: ${ctx.failure}');
  if (!ctx.started) throw Exception('the client never started the subscription');
  if (!ctx.eoseSeen) throw TimeoutException('no EOSE within ${s.timeoutMs} ms (accepted ${r.accepted} events)');
  return r;
}

double _r1(double v) => (v * 10).roundToDouble() / 10;

double _median(List<double> sorted) {
  final n = sorted.length;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

Future<Map<String, Object?>> _measure(BenchClient client, Workload w, Uri url, Settings s) async {
  final warm = <_RunResult>[];
  final runs = <_RunResult>[];
  _RunResult? first;
  String? error;
  void check(_RunResult r) {
    if (r.accepted != first!.accepted || r.xor != first!.xor) {
      throw Exception('run delivered a different set than the first run '
          '(accepted ${r.accepted} vs ${first!.accepted}, xor ${r.xor} vs ${first!.xor})');
    }
  }

  try {
    for (var i = 0; i < s.warmupRuns; i++) {
      final r = await _oneRun(client, w, url, s);
      warm.add(r);
      first ??= r;
      check(r);
      stderr.writeln('  ${client.id} ${w.name} warmup ${i + 1}: ${r.ms.toStringAsFixed(1)} ms, '
          'cpu ${r.cpuMs.toStringAsFixed(1)} ms, accepted ${r.accepted}');
    }
    final sw = Stopwatch()..start();
    while (runs.length < s.maxRuns && (runs.length < s.minRuns || sw.elapsedMilliseconds < s.minTimeMs)) {
      final r = await _oneRun(client, w, url, s);
      first ??= r;
      check(r);
      runs.add(r);
      stderr.writeln('  ${client.id} ${w.name} run ${runs.length}: ${r.ms.toStringAsFixed(1)} ms, '
          'cpu ${r.cpuMs.toStringAsFixed(1)} ms, accepted ${r.accepted}');
    }
  } catch (e) {
    error = '$e';
  }

  if (error != null || first == null) {
    final row = errorRow(client, w, error ?? 'no runs');
    if (first != null) {
      _fillAccepted(row, w, first);
      row['accepted_ok'] = false;
    }
    row['warmup_runs'] = warm.length;
    row['runs'] = runs.length;
    return row;
  }
  final ms = [for (final r in runs) r.ms];
  final sorted = [...ms]..sort();
  final median = _median(sorted);
  var p90i = (0.9 * sorted.length).ceil() - 1;
  if (p90i < 0) p90i = 0;
  final cpus = [for (final r in runs) r.cpuMs]..sort();
  final row = _baseRow(client, w);
  _fillAccepted(row, w, first);
  row.addAll({
    'errors': 0,
    'error': null,
    'warmup_runs': warm.length,
    'runs': runs.length,
    'first_run_ms': warm.isNotEmpty ? _r1(warm[0].ms) : null,
    'median_ms': _r1(median),
    'min_ms': _r1(sorted[0]),
    'p90_ms': _r1(sorted[p90i]),
    'run_ms': [for (final m in ms) _r1(m)],
    'events_per_s': _r1(w.events / (median / 1000.0)),
    'us_per_event': (median * 1000.0 / w.events * 100).roundToDouble() / 100,
    'cpu_ms': _r1(_median(cpus)),
    'peak_rss_mb': _r1(peakRssMb()),
  });
  return row;
}

void _fillAccepted(Map<String, Object?> row, Workload w, _RunResult first) {
  row['accepted'] = first.accepted;
  row['accepted_xor'] = first.xor;
  row['ambiguous_accepted'] = first.ambiguous;
  row['expired_accepted'] = first.expired;
  final expiredOk = first.expired == 0 || first.expired == w.expiredIds.length;
  final countOk = first.accepted == w.validEvents - w.expiredIds.length + first.expired + first.ambiguous;
  final xorOk = first.xor == w.expectedXor(first.ambiguous > 0, first.expired > 0 || w.expiredIds.isEmpty);
  row['accepted_ok'] = expiredOk && countOk && xorOk && first.ambiguous <= w.ambiguousIds.length;
}

Map<String, Object?> _baseRow(BenchClient c, Workload w) =>
    {...meta(c), 'workload': w.name, 'events': w.events, 'bytes': w.bytes};

Map<String, Object?> errorRow(BenchClient c, Workload w, String error) => {
      ..._baseRow(c, w),
      'accepted': null,
      'accepted_xor': null,
      'ambiguous_accepted': null,
      'expired_accepted': null,
      'accepted_ok': false,
      'errors': 1,
      'error': error,
      'warmup_runs': 0,
      'runs': 0,
      'first_run_ms': null,
      'median_ms': null,
      'min_ms': null,
      'p90_ms': null,
      'run_ms': null,
      'events_per_s': null,
      'us_per_event': null,
      'cpu_ms': null,
      'peak_rss_mb': _r1(peakRssMb()),
    };

/// A fresh, unique subscription id.
String newSubId() => 'bench-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
