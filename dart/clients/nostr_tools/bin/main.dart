// nostr_tools (aniketambore/nostr_tools), a Dart port of nostr-tools.
import 'dart:async';

import 'package:bench_common/bench_common.dart';
import 'package:nostr_tools/nostr_tools.dart';

Future<void> main(List<String> args) => childMain(args, [NostrToolsClient()]);

class NostrToolsClient extends BenchClient {
  @override
  String get id => 'nostr_tools';
  @override
  String get library => 'nostr_tools (Dart)';
  @override
  String get package => 'nostr_tools';
  @override
  String get license => 'MIT';
  @override
  String get api => 'RelayApi(relayUrl).connect() (Stream<Message>) + relay.sub([filter]), one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'explicit';
  @override
  String get notes =>
      'Last release 2023. The relay stream delivers every event unverified (the verifying Event constructor body is '
      'commented out): per event the harness calls EventApi().getEventHash(event) (the library\'s id function) against '
      'event.id, then EventApi().verifySignature(event) (BIP-340). The relay picks its own random subscription id. connect() does not expose the handshake: setup waits 200 ms after it (untimed).';

  RelayApi? _relay;
  Stream<Message>? _stream;
  StreamSubscription<Message>? _sub;
  final _events = EventApi();

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _relay = RelayApi(relayUrl: url.toString());
    _stream = await _relay!.connect();
    // WebSocketChannel.connect starts the handshake without exposing it here: give it 200 ms
    // (loopback needs ~1 ms) so the connect stays out of the timed part.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<void> run(RunCtx ctx) async {
    _sub = _stream!.listen((m) {
      if (m.type == 'EVENT') {
        final e = m.message as Event;
        bool ok;
        try {
          ok = _events.getEventHash(e) == e.id && _events.verifySignature(e);
        } catch (_) {
          ok = false;
        }
        if (ok) {
          ctx.event(e.id);
        } else {
          ctx.reject();
        }
      } else if (m.type == 'EOSE') {
        ctx.eose();
      }
    }, onError: (Object e) => ctx.fail(e));
    ctx.start();
    _relay!.sub([Filter(limit: ctx.limit)]);
  }

  @override
  Future<void> teardown() async {
    await _sub?.cancel();
    _relay?.close();
  }
}
