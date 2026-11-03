// nip01 (kumulynja/dartstr): the NIP-01 package of the Dartstr monorepo.
import 'dart:async';

import 'package:bench_common/bench_common.dart';
import 'package:nip01/nip01.dart';

Future<void> main(List<String> args) => childMain(args, [Nip01Client()]);

class Nip01Client extends BenchClient {
  @override
  String get id => 'nip01';
  @override
  String get library => 'nip01 (dartstr)';
  @override
  String get package => 'nip01';
  @override
  String get license => 'MIT';
  @override
  String get api => 'WebSocketRelayDataSource + SubscriptionRepositoryImpl.subscribe + '
      'EventRepositoryImpl.eventStream/eoseStream, one relay';
  @override
  String get websocket => 'web_socket_channel {web_socket_channel} (dart:io WebSocket)';
  @override
  String get crypto => 'bip340 {bip340} + pointycastle {pointycastle} (pure Dart)';
  @override
  String get verify => 'library';
  @override
  String get notes =>
      'EventRepositoryImpl drops events whose signature fails (EventModel.isValid = bip340.verify(pubkey, id, sig)) '
      'but never checks the id, so the harness also calls the library\'s Event.calculateId(...) (jsonEncode + SHA-256) '
      'on every delivered event and drops mismatches. The repositories are wired the way SubscribeUseCase does it, '
      'minus the use case (it hides the EOSE stream).';

  WebSocketRelayDataSource? _ds;
  EventRepositoryImpl? _events;
  SubscriptionRepositoryImpl? _subs;
  final _listeners = <StreamSubscription<Object?>>[];
  late String _url;

  @override
  Future<void> setup(Uri url, RunCtx ctx) async {
    _url = url.toString();
    _ds = WebSocketRelayDataSource();
    _events = EventRepositoryImpl(relayDataSource: _ds!);
    _subs = SubscriptionRepositoryImpl(relayDataSource: _ds!);
    await _ds!.connect(_url);
  }

  @override
  Future<void> run(RunCtx ctx) async {
    final sid = newSubId();
    _listeners.add(_events!.eventStream.listen((m) {
      if (m.subscriptionId != sid) return;
      final e = m.event;
      bool ok;
      try {
        ok = Event.calculateId(
                pubkey: e.pubkey, createdAt: e.createdAt, kind: e.kind, tags: e.tags, content: e.content) ==
            e.id;
      } catch (_) {
        ok = false;
      }
      if (ok) {
        ctx.event(e.id);
      } else {
        ctx.reject();
      }
    }));
    _listeners.add(_events!.eoseStream.listen((m) {
      if (m.subscriptionId == sid) ctx.eose();
    }));
    ctx.start();
    await _subs!.subscribe(subscriptionId: sid, filters: [Filters(limit: ctx.limit)], relayUrls: [_url]);
  }

  @override
  Future<void> teardown() async {
    for (final l in _listeners) {
      await l.cancel();
    }
    await _ds?.dispose(_url);
  }
}
