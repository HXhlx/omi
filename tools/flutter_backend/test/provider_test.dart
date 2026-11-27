import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/provider_catalog.dart';
import 'package:flutter_backend/src/provider_router.dart';
import 'package:flutter_backend/src/provider_settings.dart';
import 'package:flutter_backend/src/provider_surfaces.dart';
import 'package:flutter_backend/src/router.dart';
import 'package:flutter_backend/src/stt_client.dart';
import 'package:flutter_backend/src/tts.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('catalog', () {
    test('local channels are key-free and first in the list', () {
      final ids = kProviderCatalog.map((d) => d.id).toList();
      expect(ids.take(4), ['local-stt', 'local-whisper', 'local-sensevoice', 'local-tts']);
      for (final id in ids.take(4)) {
        expect(descriptorOf(id)!.requiresKey, isFalse);
      }
    });

    test('on-device model channels activate only after the model is reported', () async {
      final db = LocalDb.inMemory();
      await db.migrate();
      addTearDown(db.close);
      final keys = ProviderKeyStore(db);
      expect(keys.activated('local-whisper'), isFalse, reason: 'no model row yet');
      keys.setModelState('local-whisper', model: 'tiny', sizeBytes: 77691713);
      expect(keys.activated('local-whisper'), isTrue);
      expect(keys.modelState('local-whisper')!['model'], 'tiny');
      keys.clearModelState('local-whisper');
      expect(keys.activated('local-whisper'), isFalse);
      // Plain local cards stay key-and-model free.
      expect(keys.activated('local-stt'), isTrue);
    });

    test('every capability a card declares has a static model entry', () {
      for (final d in kProviderCatalog) {
        if (d.id == 'custom') continue;
        for (final cap in d.capabilities) {
          expect(
            d.staticModels.containsKey(cap.name),
            isTrue,
            reason: '${d.id} declares ${cap.name} without a static list',
          );
        }
      }
    });
  });

  group('sortModels newest-first', () {
    test('stable releases beat previews and newer majors win', () {
      final sorted = sortModels(['model-1.0', 'model-2.0', 'model-2.0-preview', 'model-10.0']);
      expect(sorted.first, 'model-10.0');
      expect(sorted.contains('model-2.0-preview'), isFalse, reason: 'previews drop when a stable exists');
    });

    test('static order breaks ties when versions match', () {
      final sorted = sortModels(['b-same', 'a-same'], staticOrder: ['b-same', 'a-same']);
      expect(sorted, ['b-same', 'a-same']);
    });
  });

  group('settings round-trip', () {
    test('defaults point routes at the local cards; llm stays empty', () {
      final s = ProviderSettings.defaults();
      expect(s.routing.asr.primary, 'local-stt');
      expect(s.routing.tts.primary, 'local-tts');
      expect(s.routing.llm.primary, isEmpty);
      expect(s.routing.realtime.primary, isEmpty);
    });

    test('encode/decode preserves cards, selection and routes', () {
      final s = ProviderSettings.defaults()
          .withAccount(ProviderAccount(id: 'minimax', selectedModels: {'llm': 'MiniMax-M3.1-Flash'}))
          .copyWith(
            routing: ProviderRouting(
              asr: RouteChain(primary: 'local-stt', fallbacks: ['siliconflow']),
              tts: RouteChain(primary: 'local-tts'),
              realtime: RouteChain(primary: 'qwen'),
              llm: RouteChain(primary: 'minimax', fallbacks: ['siliconflow']),
            ),
          );
      final back = ProviderSettings.decode(s.encode());
      expect(back.account('minimax')!.selectedModels['llm'], 'MiniMax-M3.1-Flash');
      expect(back.routing.asr.primary, 'local-stt');
      expect(back.routing.asr.fallbacks, ['siliconflow']);
      expect(back.routing.llm.fallbacks, ['siliconflow']);
    });

    test('RouteChain drops the primary from its own fallbacks', () {
      final c = RouteChain(primary: 'a', fallbacks: ['a', 'b', 'b']);
      expect(c.fallbacks, ['b']);
      expect(c.chain, ['a', 'b']);
    });

    test('unknown version falls back to defaults', () {
      final back = ProviderSettings.decode('{"version": 99, "accounts": []}');
      expect(back.routing.llm.primary, isEmpty);
    });
  });

  group('router resolution', () {
    late LocalDb db;
    late ProviderRouter router;

    setUp(() async {
      db = LocalDb.inMemory();
      await db.migrate();
      router = ProviderRouter(db);
    });

    tearDown(() => db.close());

    test('fresh install activates exactly the key-free channels', () {
      // No on-device LLM: chat stays cloud-only until a key is added.
      expect(router.activatedFor(ProviderCapability.llm), isEmpty);
      expect(router.activatedFor(ProviderCapability.vision), isEmpty);
      expect(router.activatedFor(ProviderCapability.asr), ['local-stt']);
      expect(router.activatedFor(ProviderCapability.tts), ['local-tts', 'edge']);
      expect(router.activatedFor(ProviderCapability.realtime), isEmpty);
    });

    test('adding a key activates a cloud card in the unified picker', () {
      router.save(router.settings.withAccount(ProviderAccount(id: 'siliconflow')));
      expect(router.activatedFor(ProviderCapability.asr), ['local-stt']);
      router.keys.setKey('siliconflow', 'sk-test');
      expect(router.activatedFor(ProviderCapability.asr), containsAll(['local-stt', 'siliconflow']));
    });

    test('resolve follows primary then fallbacks and skips unactivated', () {
      router.save(
        router.settings
            .withAccount(ProviderAccount(id: 'siliconflow'))
            .copyWith(
              routing: ProviderRouting(
                asr: RouteChain(primary: 'local-stt', fallbacks: ['siliconflow']),
                tts: RouteChain(primary: 'local-tts'),
                realtime: RouteChain(),
                llm: RouteChain(primary: 'local-llm'),
              ),
            ),
      );
      expect(router.resolve(ProviderCapability.asr).map((c) => c.id), ['local-stt']);
      router.keys.setKey('siliconflow', 'sk-test');
      expect(router.resolve(ProviderCapability.asr).map((c) => c.id), ['local-stt', 'siliconflow']);
    });

    test('card default model is the newest static entry', () {
      router.save(router.settings.withAccount(ProviderAccount(id: 'siliconflow')));
      final acct = router.settings.account('siliconflow')!;
      final newest = acct.candidates(ProviderCapability.asr).first;
      // Newest by version, per the "default selects the latest" rule.
      expect(newest, 'XingChenAGI/XingChenASR-V3.2-Ultra');
      expect(acct.effectiveModel(ProviderCapability.asr), newest);
    });
  });

  group('provider HTTP endpoints', () {
    late LocalDb db;
    late Handler handler;

    setUp(() async {
      db = LocalDb.inMemory();
      await db.migrate();
      handler = Api(db).handler;
    });

    tearDown(() => db.close());

    Future<Map<String, dynamic>> call(String method, String path, {Object? body}) async {
      final req = Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );
      final res = await handler(req);
      final text = await res.readAsString();
      return {'status': res.statusCode, 'body': text.isEmpty ? null : jsonDecode(text)};
    }

    test('catalog lists local channels', () async {
      final r = await call('GET', '/v1/provider/catalog');
      expect(r['status'], 200);
      final ids = (r['body']['channels'] as List).map((c) => c['id']).toList();
      expect(ids, containsAll(['local-stt', 'local-sensevoice', 'local-tts']));
      expect(ids, isNot(contains('local-llm')), reason: 'no on-device LLM card');
    });

    test('settings PUT round-trips and GET reflects it', () async {
      final put = await call(
        'PUT',
        '/v1/provider/settings',
        body: {
          'version': 1,
          'accounts': [
            {
              'id': 'minimax',
              'baseUrl': 'https://api.minimax.chat/v1',
              'selectedModels': {'llm': 'MiniMax-M3.1-Flash'},
            },
          ],
          'routing': {
            'asr': {'primary': 'local-stt', 'fallbacks': <String>[]},
            'tts': {'primary': 'local-tts', 'fallbacks': <String>[]},
            'realtime': {'primary': '', 'fallbacks': <String>[]},
            'llm': {
              'primary': 'minimax',
              'fallbacks': <String>[],
            },
          },
        },
      );
      expect(put['status'], 200);
      final got = await call('GET', '/v1/provider/settings');
      expect(got['body']['routing']['llm']['primary'], 'minimax');
      expect(got['body']['accounts'][0]['id'], 'minimax');
    });

    test('active lists only activated channels per capability', () async {
      final r = await call('GET', '/v1/provider/active?capability=llm');
      expect(r['status'], 200);
      expect(r['body']['llm'], isEmpty, reason: 'no on-device LLM; cloud needs a key');
    });

    test('setting a key activates the channel without echoing it back', () async {
      final key = await call('PUT', '/v1/provider/key', body: {'id': 'siliconflow', 'key': 'sk-secret'});
      expect(key['status'], 200);
      expect(key['body']['activated'], isTrue);
      expect(jsonEncode(key['body']), isNot(contains('sk-secret')));
      final settings = await call('GET', '/v1/provider/settings');
      expect(jsonEncode(settings['body']), isNot(contains('sk-secret')));
    });
  });

  group('on-device surfaces', () {
    late LocalDb db;

    setUp(() async {
      db = LocalDb.inMemory();
      await db.migrate();
    });

    tearDown(() => db.close());

    test('local-stt card routes to the injected in-process surface, not HTTP', () async {
      final calls = <List<Object?>>[];
      final router = ProviderRouter(
        db,
        localStt: {'local-stt': _FakeStt(calls)},
      );
      final result = await router.sttSurface().transcribePcm(
        Uint8List.fromList([1, 2, 3, 4]),
        sampleRate: 16000,
        channels: 1,
        language: 'zh',
      );
      expect(result.text, 'fake transcription');
      // The fake received the exact call parameters and never dialed a socket.
      expect(calls, [
        [16000, 1, 'zh'],
      ]);
    });

    test('per-card surfaces: sensevoice card gets its own engine', () async {
      final calls = <List<Object?>>[];
      final router = ProviderRouter(
        db,
        localStt: {'local-sensevoice': _FakeStt(calls)},
      );
      // Mark the model downloaded so the card activates, then route asr to it.
      router.keys.setModelState('local-sensevoice', model: 'int8', sizeBytes: 239);
      router.save(router.settings.copyWith(
        routing: ProviderRouting(
          asr: RouteChain(primary: 'local-sensevoice'),
          tts: RouteChain(primary: 'local-tts'),
          realtime: RouteChain(),
          llm: RouteChain(),
        ),
      ));
      final result = await router.sttSurface().transcribePcm(
        Uint8List.fromList([5, 6]),
        sampleRate: 16000,
      );
      expect(result.text, 'fake transcription');
      expect(calls.single, [16000, 1, null]);
    });

    test('local-tts card routes to the injected in-process surface, not HTTP', () async {
      final router = ProviderRouter(db, localTts: _FakeTts());
      final audio = await router.ttsSurface().synthesize(TtsRequest('你好'));
      expect(audio, Uint8List.fromList([9, 9, 9]));
    });

    test('without injected surfaces the cards keep the HTTP chain', () {
      final router = ProviderRouter(db);
      expect(router.localStt, isEmpty);
      expect(router.localTts, isNull);
      // Resolution itself is unchanged: the local cards still come first.
      expect(router.resolve(ProviderCapability.asr).first.id, 'local-stt');
      expect(router.resolve(ProviderCapability.tts).first.id, 'local-tts');
    });
  });
}

class _FakeStt implements SttSurface {
  _FakeStt(this.seen);
  final List<List<Object?>> seen;

  @override
  Future<SttResult> transcribePcm(Uint8List pcm16, {int sampleRate = 16000, int channels = 1, String? language}) async {
    seen.add([sampleRate, channels, language]);
    return SttResult(
      text: 'fake transcription',
      segments: const [],
    );
  }

  @override
  Future<SttResult> transcribeMultipart(Uint8List body, String contentType) async =>
      SttResult(text: 'fake multipart', segments: const []);
}

class _FakeTts implements TtsSurface {
  @override
  Future<Uint8List> synthesize(TtsRequest req) async => Uint8List.fromList([9, 9, 9]);
}
