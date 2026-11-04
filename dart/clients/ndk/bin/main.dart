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
      // query()'s defaults (cacheRead/cacheWrite: true): every verified event is saved to the
      // MemCacheManager and only delivered if the cache keeps it visible. A store, outside the
      // job: a variant, with the Rust verifier so its cost shows next to ndk-rust.
      NdkClient('ndk-cache', 'RustEventVerifier() (as ndk-rust)', () => RustEventVerifier(),
          'libsecp256k1 (C, via rust secp256k1 0.31 in ndk\'s librust_lib_ndk.so, built by its build hook)', true,
          cache: true),
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

  /// true: query() with its defaults (cacheRead: true, cacheWrite: true); false: both off.
  final bool cache;
  NdkClient(this.id, this.verifierDesc, this.verifier, this.crypto, this.variant, {this.cache = false});

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
      'recompute + NIP-13 PoW check) and the verifier; invalid events are dropped. It keeps an LRU of verified id/sig '
      'pairs per Ndk instance (a new Ndk per run, so nothing is reused across runs). Frames are JSON-decoded on an '
      'encoding isolate. NdkConfig: bootstrapRelays = [the relay] (connected and awaited in setup, untimed), '
      'MemCacheManager (a required parameter), log level off, and query timeout = 1 h (the default 10 s query timeout '
      'would cut the stream). The stream closes when the relay sends EOSE: that is the EOSE time. '
      '${cache ? _cacheNote : _noCacheNote} '
      'Library costs paid on every event, named not worked around: the id is computed twice '
      '(${id == 'ndk' ? 'isIdValid in VerifyEventStream and again inside Bip340EventVerifier.verify' : 'isIdValid in Dart, then again in the native call'}), '
      'the NIP-13 check, the frame\'s string length taken for relay stats, the query\'s returnedIds dedup set; and '
      'after connect ndk fires an unawaited NIP-11 HTTP GET (setup, but it may still be in flight). '
      'Nip01Event\'s constructor replaces created_at: 0 with the current time, so that valid event fails its id check '
      'and is dropped: accepted_ok is false.';

  static const _noCacheNote = 'query(cacheRead: false, cacheWrite: false): with cacheWrite off ndk returns the '
      'verified stream as is, so nothing is stored (the defaults run in the ndk-cache variant). Expired events and '
      'older kind-0 versions are delivered.';
  static const _cacheNote = 'Variant: query() with its defaults, cacheRead: true and cacheWrite: true: every '
      'verified event is saved to the MemCacheManager (saveEventIfAbsent, addEventSources) and then delivered only if '
      'loadEvents (with its visibility rules) still returns it, so expired events and a kind-0 profile older than '
      'another by the same author in the stream are dropped. Same as ndk-rust otherwise.';

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
      cacheRead: cache,
      cacheWrite: cache,
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
