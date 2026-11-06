// dart_nostr (anasfik/nostr).
import 'package:bench_common/bench_common.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:dart_nostr/nostr/model/debug_options.dart';

Future<void> main(List<String> args) => childMain(args, [DartNostrClient()]);

class DartNostrClient extends BenchClient {
  @override
  String get id => 'dart_nostr';
  @override
  String get library => 'dart_nostr';
  @override
  String get package => 'dart_nostr';
  @override
  String get license => 'MIT';
  @override
  String get api =>
      'Nostr().services.relays.init([relay]) + startEventsSubscription(request, onEose).stream, one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'explicit';
  @override
  String get notes =>
      'A new Nostr() instance per run (Nostr.instance is a process-wide singleton whose registry drops event ids it '
      'has seen before). The relay layer does not verify: per event the harness calls NostrEvent.getEventId(...) (the '
      'library\'s id function, jsonEncode + SHA-256) against id, then event.isVerified() (BIP-340 only). Per-event '
      'console logging is on by default and turned off (NostrDebugOptions(isLogsEnabled: false)). The relay layer '
      'jsonDecodes each frame once. Library costs paid on every event, named not worked around: every raw frame '
      'string goes into an LRU set of 5000 (frame-level dedup) and onto an all-data-entities sink; every event is '
      'stored in the instance\'s unbounded eventsRegistry map (event-level dedup, so a new Nostr() per run); and its '
      'log strings (frame, content) are interpolated per event even with logs off.';

  Nostr? _nostr;
  NostrEventsStream? _sub;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _nostr = Nostr(debugOptions: NostrDebugOptions(tag: 'bench', isLogsEnabled: false));
    await _nostr!.services.relays.init(relaysUrl: [url.toString()]);
  }

  @override
  Future<void> run(RunCtx ctx) async {
    ctx.start();
    _sub = _nostr!.services.relays.startEventsSubscription(
      request: NostrRequest(filters: [NostrFilter(limit: ctx.limit)]),
      onEose: (relay, eose) => ctx.eose(),
    );
    _sub!.stream.listen((e) {
      bool ok;
      try {
        ok = e.id != null &&
            NostrEvent.getEventId(
                    kind: e.kind!,
                    content: e.content ?? '',
                    createdAt: e.createdAt!,
                    tags: e.tags ?? const [],
                    pubkey: e.pubkey) ==
                e.id &&
            e.isVerified();
      } catch (_) {
        ok = false;
      }
      if (ok) {
        ctx.event(e.id!);
      } else {
        ctx.reject();
      }
    });
  }

  @override
  Future<void> teardown() async {
    try {
      _sub?.close();
    } catch (_) {}
    await _nostr?.services.relays.freeAllResources();
  }
}
