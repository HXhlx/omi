import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:flutter_backend/embedded.dart';

void main() {
  test('embedded server binds loopback, serves the API, and closes', () async {
    final dir = await Directory.systemTemp.createTemp('omi-embedded-test');
    final server = await LocalBackendServer.start(dbPath: '${dir.path}/t.db');
    addTearDown(() async {
      await server.close();
      await dir.delete(recursive: true);
    });

    expect(server.uri.host, '127.0.0.1');
    expect(server.uri.port, isNot(0));

    final client = HttpClient();
    addTearDown(client.close);
    final res = await (await client.getUrl(server.uri.resolve('/health'))).close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), contains('ok'));
  });
}
