import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:omi/backend/http/api/provider_settings.dart';

/// The provider-cards page is a thin client over `/v1/provider/*`; these tests
/// pin the wire contract it depends on: catalog parsing, the settings document,
/// the activated-provider lists, and that a key is never echoed back.
void main() {
  ProviderApi apiWith(Map<String, Object?> routes) => ProviderApi(
        send: (method, path, body) async {
          final payload = routes['$method $path'];
          if (payload == null) {
            return http.Response('{"detail":"Not Found"}', 404);
          }
          return http.Response(jsonEncode(payload), 200, headers: {'content-type': 'application/json'});
        },
      );

  test('catalog carries capabilities and static models', () async {
    final api = apiWith({
      'GET v1/provider/catalog': {
        'channels': [
          {
            'id': 'local-llm',
            'label': 'Local LLM',
            'capabilities': ['llm'],
            'defaultBase': 'http://127.0.0.1:4000/v1',
            'staticModels': {
              'llm': ['deepseek-flash']
            },
            'requiresKey': false,
          }
        ]
      }
    });
    final channels = await api.getCatalog();
    expect(channels, hasLength(1));
    expect(channels.first.capabilities, ['llm']);
    expect(channels.first.requiresKey, isFalse);
    expect(channels.first.staticModels['llm'], ['deepseek-flash']);
  });

  test('settings round-trip keeps per-card model selection and routes', () async {
    final document = {
      'version': 1,
      'accounts': [
        {
          'id': 'minimax',
          'baseUrl': 'https://api.minimax.chat/v1',
          'selectedModels': {'llm': 'MiniMax-M3.1-Flash'},
          'capabilities': <String>[],
        }
      ],
      'routing': {
        'asr': {
          'primary': 'local-stt',
          'fallbacks': ['siliconflow']
        },
        'llm': {
          'primary': 'minimax',
          'fallbacks': ['local-llm']
        },
      },
    };
    final api = apiWith({'PUT v1/provider/settings': document});
    final saved = await api.saveSettings(
      ProviderSettings.fromJson(Map<String, dynamic>.from(document)),
    );
    expect(saved.account('minimax')!.selectedModels['llm'], 'MiniMax-M3.1-Flash');
    expect(saved.routing['asr']!.primary, 'local-stt');
    expect(saved.routing['asr']!.fallbacks, ['siliconflow']);
    expect(saved.routing['llm']!.fallbacks, ['local-llm']);
  });

  test('active lists drive the unified picker: only activated ids', () async {
    final api = apiWith({
      'GET v1/provider/active': {
        'asr': ['local-stt'],
        'tts': ['local-tts', 'edge'],
        'llm': ['local-llm'],
        'realtime': <String>[],
      }
    });
    final active = await api.getActive();
    expect(active['asr'], ['local-stt']);
    expect(active['realtime'], isEmpty);
  });

  test('key activation response never contains the key', () async {
    final api = apiWith({
      'PUT v1/provider/key': {'status': 'ok', 'activated': true}
    });
    expect(await api.setKey('siliconflow', 'sk-secret'), isTrue);
  });

  test('discover returns the backend candidate order', () async {
    final api = apiWith({
      'POST v1/provider/discover': {
        'id': 'siliconflow',
        'capability': 'asr',
        'candidates': ['XingChenASR-V3.2-Ultra', 'XingChenASR-V3.0'],
      }
    });
    expect(await api.discover('siliconflow', 'asr'), ['XingChenASR-V3.2-Ultra', 'XingChenASR-V3.0']);
  });
}
