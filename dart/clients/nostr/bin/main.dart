// nostr (ethicnology/dart-nostr): a transport-agnostic protocol library, paired with
// dart:io's WebSocket the way its own examples do.
import 'dart:async';
import 'dart:io';

import 'package:bench_common/bench_common.dart';
import 'package:nostr/nostr.dart';

Future<void> main(List<String> args) => childMain(args, [NostrDartIo()]);

class NostrDartIo extends BenchClient {
  @override
  String get id => 'nostr-dartio';
  @override
  String get library => 'nostr (Dart)';
  @override
  String get package => 'nostr';
  @override
  String get license => 'LGPL-3.0-only';
  @override
  String get api => 'dart:io WebSocket + Request(...).serialize() + Message.deserialize(frame), one relay';
  @override
  String get websocket => 'dart:io WebSocket (the library has no relay client; its examples use dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'library';
  @override
  bool get variant => true;
  @override
  String get notes =>
      'The library has no WebSocket client ("transport-agnostic"), so this is a variant paired with dart:io WebSocket '
      'as in its examples. Message.deserialize parses each frame; for an EVENT it builds the Event with the default '
      'verify: true, which recomputes the id and checks the BIP-340 signature and throws on failure (counted as '
      'rejected).';

  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _ws = await WebSocket.connect(url.toString());
  }

  @override
  Future<void> run(RunCtx ctx) async {
    final sid = newSubId();
    _sub = _ws!.listen((frame) {
      Message m;
      try {
        m = Message.deserialize(frame as String);
      } catch (_) {
        ctx.reject();
        return;
      }
      if (m.type == MessageType.event) {
        final e = m.message as Event;
        if (e.subscriptionId == sid) ctx.event(e.id);
      } else if (m.type == MessageType.eose) {
        if ((m.message as Eose).subscriptionId == sid) ctx.eose();
      }
    }, onError: (Object e) => ctx.fail(e));
    ctx.start();
    _ws!.add(Request(subscriptionId: sid, filters: [Filter(limit: ctx.limit)]).serialize());
  }

  @override
  Future<void> teardown() async {
    await _sub?.cancel();
    await _ws?.close();
  }
}
