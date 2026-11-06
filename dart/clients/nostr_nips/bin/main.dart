// nostr_nips (meylis1998/dart_nostr).
import 'dart:async';

import 'package:bench_common/bench_common.dart';
import 'package:nostr_nips/nostr_nips.dart';

Future<void> main(List<String> args) => childMain(args, [NostrNipsClient()]);

class NostrNipsClient extends BenchClient {
  @override
  String get id => 'nostr_nips';
  @override
  String get library => 'nostr_nips';
  @override
  String get package => 'nostr_nips';
  @override
  String get license => 'MIT';
  @override
  String get api => 'Relay(url).connect() + relay.messages (Stream<RelayMessage>) + relay.subscribe([filter]), one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'explicit';
  @override
  String get notes =>
      'Relay parses every frame (jsonDecode + RelayMessage.parse into Event) but does not verify: per event the '
      'harness calls event.verify() (the library\'s own: recomputed id, then BIP-340). Frames that fail to parse '
      'come out as stream errors and are counted as rejected.';

  Relay? _relay;
  StreamSubscription<RelayMessage>? _sub;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _relay = Relay(url.toString());
    await _relay!.connect();
  }

  @override
  Future<void> run(RunCtx ctx) async {
    final sid = newSubId();
    _sub = _relay!.messages.listen((m) {
      if (m is EventMessage) {
        if (m.subscriptionId != sid) return;
        if (m.event.verify()) {
          ctx.event(m.event.id);
        } else {
          ctx.reject();
        }
      } else if (m is EoseMessage && m.subscriptionId == sid) {
        ctx.eose();
      }
    }, onError: (Object e) => ctx.reject());
    ctx.start();
    _relay!.subscribe([Filter(limit: ctx.limit)], subscriptionId: sid);
  }

  @override
  Future<void> teardown() async {
    await _sub?.cancel();
    await _relay?.dispose();
  }
}
