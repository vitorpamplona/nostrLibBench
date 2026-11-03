/// nostrLibBench Dart harness: the orchestrator.
///
/// Parses the HARNESS.md flags, asks every client binary (one per library package, built into
/// build/) for its clients, then runs each client on each workload in a fresh process, one
/// after another, and writes results/dart.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Library packages (clients/<dir>), in the order their rows are written, with the client ids
/// each one provides (used only for error rows when a binary failed to build).
const projects = <String, List<String>>{
  'ndk': ['ndk', 'ndk-rust'],
  'dart_nostr': ['dart_nostr'],
  'nostr_nips': ['nostr_nips'],
  'nostr_tools': ['nostr_tools'],
  'nostr_dart': ['nostr_dart'],
  'nostr_client': ['nostr_client'],
  'nip01': ['nip01'],
  'nostr': ['nostr-dartio'],
};

Future<void> main(List<String> args) async {
  var relay = 'ws://127.0.0.1:7777', corpus = '.corpus', out = 'results/dart.json';
  String? workloadsArg, clientsArg;
  var warmup = 2, minRuns = 5, minTime = 10000, maxRuns = 30, timeout = 300000;
  var list = false;
  String? buildDir;
  for (var i = 0; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : throw ArgumentError('${args[i]} needs a value');
    switch (args[i]) {
      case '--relay':
        relay = next();
      case '--corpus':
        corpus = next();
      case '--out':
        out = next();
      case '--workloads':
        workloadsArg = next();
      case '--clients':
        clientsArg = next();
      case '--warmup-runs':
        warmup = int.parse(next());
      case '--min-runs':
        minRuns = int.parse(next());
      case '--min-time-ms':
        minTime = int.parse(next());
      case '--max-runs':
        maxRuns = int.parse(next());
      case '--timeout-ms':
        timeout = int.parse(next());
      case '--quick':
        warmup = 1;
        minRuns = 2;
        minTime = 0;
      case '--list':
        list = true;
      case '--build-dir':
        buildDir = next();
      default:
        stderr.writeln('unknown flag ${args[i]}');
        exit(2);
    }
  }
  final here = buildDir ?? File(Platform.resolvedExecutable).parent.path; // dart/build
  final clientsDir = '${Directory(here).parent.path}/clients';

  // (binary, lockfile, metadata) per client
  final entries = <(String?, String, Map<String, Object?>)>[];
  for (final MapEntry(key: dir, value: ids) in projects.entries) {
    final lock = '$clientsDir/$dir/pubspec.lock';
    final bin = binaryOf(here, dir);
    if (bin == null) {
      for (final id in ids) {
        entries.add((null, lock, {'client': id, 'library': dir, 'version': '?', 'license': '?', 'api': '',
          'websocket': '', 'crypto': '', 'verify': '', 'notes': '', 'variant': id.contains('-')}));
      }
      continue;
    }
    final r = await Process.run(bin, ['--lockfile', lock, '--list-json']);
    if (r.exitCode != 0) {
      stderr.writeln('$bin --list-json failed (${r.exitCode}): ${r.stderr}');
      exit(1);
    }
    for (final m in jsonDecode(r.stdout as String) as List) {
      entries.add((bin, lock, (m as Map).cast<String, Object?>()));
    }
  }
  if (list) {
    for (final e in entries) {
      stdout.writeln(e.$3['client']);
    }
    return;
  }

  final manifest = jsonDecode(File('$corpus/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final workloadDocs = {for (final w in manifest['workloads'] as List) (w as Map)['name'] as String: w};
  final workloads = workloadsArg?.split(',').where((s) => s.isNotEmpty).toList() ?? ['all'];
  for (final w in workloads) {
    if (!workloadDocs.containsKey(w)) {
      stderr.writeln('unknown workload $w');
      exit(2);
    }
  }
  var selected = entries;
  if (clientsArg != null) {
    final want = clientsArg.split(',').where((s) => s.isNotEmpty).toSet();
    for (final c in want) {
      if (!entries.any((e) => e.$3['client'] == c)) {
        stderr.writeln('unknown client $c');
        exit(2);
      }
    }
    selected = entries.where((e) => want.contains(e.$3['client'])).toList();
  }

  final tmp = Directory.systemTemp.createTempSync('libbench-dart-');
  final results = <Map<String, Object?>>[];
  for (final w in workloads) {
    for (final (bin, lock, meta) in selected) {
      final id = meta['client'] as String;
      stderr.writeln('== $id / $w');
      Map<String, Object?> row;
      if (bin == null) {
        row = errorRow(meta, workloadDocs[w], 'the client binary did not build (see the build log of dart/run.sh)');
      } else {
        final resultFile = File('${tmp.path}/$id-$w.json');
        final childArgs = [
          '--lockfile', lock, '--child', id, '--workload', w, '--relay', relay,
          '--corpus', Directory(corpus).absolute.path,
          '--warmup-runs', '$warmup', '--min-runs', '$minRuns', '--min-time-ms', '$minTime',
          '--max-runs', '$maxRuns', '--timeout-ms', '$timeout', '--result', resultFile.path,
        ];
        // The child enforces --timeout-ms per run; this bound only catches a child that hangs
        // outside a run (it gets killed and the row says so).
        final bound = Duration(milliseconds: (warmup + maxRuns + 2) * (timeout + 10000) + minTime + 60000);
        final p = await Process.start(bin, childArgs);
        // Library output goes to our stderr (stdout stays clean).
        final o = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => stderr.writeln('    | $l'));
        final e = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(stderr.writeln);
        int code;
        String? err;
        try {
          code = await p.exitCode.timeout(bound);
        } on TimeoutException {
          p.kill(ProcessSignal.sigkill);
          code = -1;
          err = 'child process did not finish within ${bound.inMilliseconds} ms; killed';
        }
        await o.cancel();
        await e.cancel();
        if (resultFile.existsSync()) {
          row = (jsonDecode(resultFile.readAsStringSync()) as Map).cast<String, Object?>();
        } else {
          row = errorRow(meta, workloadDocs[w], err ?? 'child process exited with code $code without a result (crash)');
        }
      }
      stderr.writeln('   -> accepted ${row['accepted']} ok=${row['accepted_ok']} median ${row['median_ms']} ms '
          'cpu ${row['cpu_ms']} ms rss ${row['peak_rss_mb']} MB${row['error'] != null ? ' ERROR ${row['error']}' : ''}');
      results.add(row);
    }
  }
  tmp.deleteSync(recursive: true);

  final doc = {
    'harness': 'dart',
    'language': 'Dart',
    'runtime': 'Dart ${Platform.version.split(' ').first} (AOT: dart compile exe, or dart build cli for packages '
        'with build hooks; default VM flags)',
    'host': host(),
    'settings': {'warmup_runs': warmup, 'min_runs': minRuns, 'min_time_ms': minTime, 'max_runs': maxRuns},
    'relay': relay,
    'corpus_fingerprint': manifest['fingerprint'] ?? '',
    'results': results,
  };
  final f = File(out);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
  stderr.writeln('wrote $out');
}

/// build/<dir>/main (dart compile exe) or build/<dir>/bundle/bin/main (dart build cli).
String? binaryOf(String buildDir, String dir) {
  for (final p in ['$buildDir/$dir/bundle/bin/main', '$buildDir/$dir/main']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

Map<String, Object?> errorRow(Map<String, Object?> meta, dynamic w, String error) => {
      ...meta,
      'workload': w['name'],
      'events': w['events'],
      'bytes': w['bytes'],
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
      'peak_rss_mb': null,
    };

Map<String, Object?> host() {
  var cpu = '';
  try {
    cpu = File('/proc/cpuinfo')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('model name'))
        .split(':')
        .sublist(1)
        .join(':')
        .trim();
  } catch (_) {}
  var os = 'Linux';
  try {
    os = 'Linux ${File('/proc/sys/kernel/osrelease').readAsStringSync().trim()}';
  } catch (_) {}
  return {'cpu': cpu, 'cores': Platform.numberOfProcessors, 'os': os};
}
