// nostr_client (UlrichRaab/nostr_client).
import 'dart:async';
import 'dart:convert';

import 'package:bench_common/bench_common.dart';
import 'package:crypto/crypto.dart';
import 'package:nostr_client/nostr_client.dart';

Future<void> main(List<String> args) => childMain(args, [NostrClientDart()]);

class NostrClientDart extends BenchClient {
  @override
  String get id => 'nostr_client';
  @override
  String get library => 'nostr_client (Dart)';
  @override
  String get package => 'nostr_client';
  @override
  String get license => 'LGPL-3.0-only';
  @override
  String get api => 'Relay(url).connect() + relay.stream (Stream<Message>) + relay.subscribe(filter), one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (IOWebSocketChannel, dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'explicit';
  @override
  String get notes =>
      'Last release 2023. The relay stream delivers raw jsonDecoded messages; the harness turns EVENT messages into '
      'the library\'s Event with Event.fromJson and calls event.verify() (BIP-340 over the id, the library\'s only '
      'check). The library has no id function, so the id check is harness code: SHA-256 (package:crypto) of '
      'jsonEncode([0, pubkey, created_at, kind, tags, content]), what the other Dart libraries do. connect() is lazy '
      '(IOWebSocketChannel.connect without awaiting the handshake): setup waits 200 ms after it (untimed).';

  Relay? _relay;
  StreamSubscription<Message>? _sub;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _relay = Relay(url.toString());
    _relay!.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  static String _id(Event e) => sha256
      .convert(utf8.encode(jsonEncode(
          [0, e.pubkey, e.createdAt.millisecondsSinceEpoch ~/ 1000, e.kind, e.tags, e.content])))
      .toString();

  @override
  Future<void> run(RunCtx ctx) async {
    _sub = _relay!.stream.listen((m) {
      if (m.isEvent) {
        bool ok;
        Event? e;
        try {
          e = Event.fromJson(m[2] as Map<String, dynamic>);
          ok = _id(e) == e.id && e.verify();
        } catch (_) {
          ok = false;
        }
        if (ok) {
          ctx.event(e!.id);
        } else {
          ctx.reject();
        }
      } else if (m.isEose) {
        ctx.eose();
      }
    }, onError: (Object e) => ctx.fail(e));
    ctx.start();
    _relay!.subscribe(Filter(limit: ctx.limit));
  }

  @override
  Future<void> teardown() async {
    await _sub?.cancel();
    await _relay?.disconnect();
  }
}
