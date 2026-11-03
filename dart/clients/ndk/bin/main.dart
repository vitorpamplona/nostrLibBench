// ndk (relaystr/ndk): Nostr Development Kit.
import 'package:bench_common/bench_common.dart';
import 'package:ndk/ndk.dart';

Future<void> main(List<String> args) => childMain(args, [
      NdkClient('ndk', 'Bip340EventVerifier() (the documented default: pure Dart, verifies on a compute isolate)',
          () => Bip340EventVerifier(), 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart, on compute isolates)',
          false),
      NdkClient('ndk-rust', 'RustEventVerifier() (Rust via FFI: id hash + BIP-340 in one native call)',
          () => RustEventVerifier(),
          'libsecp256k1 (C, via rust secp256k1 0.31 in ndk\'s librust_lib_ndk.so, built by its build hook)', false),
    ]);

class NdkClient extends BenchClient {
  @override
  final String id;
  final String verifierDesc;
  final EventVerifier Function() verifier;
  @override
  final String crypto;
  @override
  final bool variant;
  NdkClient(this.id, this.verifierDesc, this.verifier, this.crypto, this.variant);

  @override
  String get library => 'ndk';
  @override
  String get package => 'ndk';
  @override
  String get license => 'MIT';
  @override
  String get api => 'Ndk.requests.query(filter, explicitRelays: [relay]).stream (closes after EOSE), one relay';
  @override
  String get websocket => 'ndk\'s vendored web_socket_client (dart:io WebSocket)';
  @override
  String get verify => 'library';
  @override
  String get notes =>
      'Event verifier: $verifierDesc. Every event goes through VerifyEventStream: Nip01Utils.isIdValid (Dart id '
      'recompute) and the verifier; invalid events are dropped. It keeps an LRU of verified id/sig pairs per Ndk '
      'instance (a new Ndk per run, so nothing is reused across runs). Frames are JSON-decoded on an encoding isolate. '
      'NdkConfig: bootstrapRelays = [the relay] (connected and awaited in setup, untimed), MemCacheManager (query writes '
      'every event to it, as by default), and query timeout = 1 h (the default 10 s query timeout would cut '
      'the stream). The stream closes when the relay sends EOSE: that is the EOSE time.';

  Ndk? _ndk;
  late String _url;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _url = url.toString();
    _ndk = Ndk(NdkConfig(
      eventVerifier: verifier(),
      cache: MemCacheManager(),
      bootstrapRelays: [_url],
      logLevel: LogLevel.off,
    ));
    await _ndk!.relays.seedRelaysConnected;
  }

  @override
  Future<void> run(RunCtx ctx) async {
    ctx.start();
    final resp = _ndk!.requests.query(
      filter: Filter(limit: ctx.limit),
      explicitRelays: [_url],
      timeout: const Duration(hours: 1),
    );
    await for (final e in resp.stream) {
      ctx.event(e.id);
    }
    ctx.eose();
  }

  @override
  Future<void> teardown() async {
    await _ndk?.destroy();
  }
}
