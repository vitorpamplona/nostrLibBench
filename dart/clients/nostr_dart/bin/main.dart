// nostr_dart (Satswalker/nostr_dart).
import 'package:bench_common/bench_common.dart';
import 'package:http/http.dart' as http;
import 'package:nostr_dart/nostr_dart.dart';
// Not exported by the package, but a public constructor parameter of Relay.
import 'package:nostr_dart/src/relay_info_provider.dart';

Future<void> main(List<String> args) => childMain(args, [NostrDartClient()]);

/// Relay.connect() fetches NIP-11 over https:// and refuses relays that do not list NIPs 15
/// and 20. The bench relay serves NIP-11 over plain http (it lists [1, 11, 15, 20], but
/// nostr_dart only fetches https://), so the harness hands Relay this provider instead.
class _StaticInfo extends RelayInfoProvider {
  _StaticInfo() : super(http: http.Client());
  @override
  Future<RelayInfo> get(String url) async => RelayInfo.fromJson({
        'name': 'blast-relay',
        'supported_nips': [1, 11, 15, 20],
      });
}

class NostrDartClient extends BenchClient {
  @override
  String get id => 'nostr_dart';
  @override
  String get library => 'nostr_dart';
  @override
  String get package => 'nostr_dart';
  @override
  String get license => 'MIT';
  @override
  String get api => 'Nostr().pool.add(Relay(url)) + await pool.subscribe([filter], onEvent) (returns at EOSE), one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (IOWebSocketChannel, dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'library';
  @override
  String get notes =>
      'Last release 2023. RelayPool verifies every event (Event.isValid: id recomputed; Event.isSigned: BIP-340; '
      'signature verification is on unless Nostr(disableSignatureVerification: true)). The pool hides EOSE, but '
      'pool.subscribe() awaits the relay\'s ack, which is the EOSE: its return is the EOSE time. Relay.connect() needs '
      'NIP-11 over https and NIPs 15+20 listed, so Relay gets a RelayInfoProvider (its public constructor parameter) '
      'that returns {supported_nips: [1, 11, 15, 20]}. Caveat: the ack wait has a hard-coded 1 min timeout that '
      'disconnects the relay, so a subscription whose EOSE takes longer than 1 min to process is cut off. '
      'Relay.connect() starts IOWebSocketChannel.connect without awaiting the handshake (the channel is private), '
      'so setup waits 200 ms after pool.add (untimed), as for nostr_tools and nostr_client.'
      ' It pins bip340 ^0.0.4 (as nostr_client and nostr_dart do), whose verify serializes the public key with bigToBytes (helpers.dart:12, no left padding): for a pubkey whose first byte is 0 the BIP-340 challenge hashes 31 bytes and the valid signature fails, so every event from such a key is dropped (83 in the full corpus; fixed in bip340 0.2.0, which the ^0.0.4 constraint excludes).';

  Nostr? _nostr;
  late String _url;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _url = url.toString();
    _nostr = Nostr();
    if (!await _nostr!.pool.add(Relay(_url, relayInfoProvider: _StaticInfo()))) {
      throw Exception('RelayPool.add: could not connect');
    }
    // Relay.connect() returns before the WebSocket handshake (IOWebSocketChannel.connect is not
    // awaited and the channel is private): give it 200 ms, untimed, so it is not in the run.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<void> run(RunCtx ctx) async {
    ctx.start();
    await _nostr!.pool.subscribe([
      {'limit': ctx.limit}
    ], (Event e) => ctx.event(e.id));
    ctx.eose();
  }

  @override
  Future<void> teardown() async {
    _nostr?.pool.remove(_url);
  }
}
