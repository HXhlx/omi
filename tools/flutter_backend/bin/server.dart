import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:flutter_backend/src/db.dart';

/// Single local user; native clients send a Bearer token the server maps here.
const kLocalUserId = 'local-dev-user';

void main(List<String> args) async {
  final port = int.parse(Platform.environment['FLUTTER_BACKEND_PORT'] ?? '8100');
  final dbPath = Platform.environment['FLUTTER_BACKEND_DB'] ??
      '.flutter-backend/omi_local.db';
  final db = LocalDb.open(dbPath);
  db.migrate();
  db.setSetting('booted', DateTime.now().toIso8601String());

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_cors())
      .addHandler(_router(db));

  final server = await shelf_io.serve(handler, '127.0.0.1', port);
  stdout.writeln('flutter-backend listening on http://127.0.0.1:$port');
  ProcessSignal.sigint.watch().listen((_) {
    db.close();
    server.close(force: true);
  });
}

Middleware _cors() {
  const h = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  };
  return (inner) => (req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: h);
        }
        final res = await inner(req);
        return res.change(headers: h);
      };
}

Handler _router(LocalDb db) {
  return (Request req) async {
    final path = req.url.path;
    final uid = _resolveUid(req);

    // ---- health ----
    if (path == 'health' || path == 'ready') {
      return _json({'status': 'ok', 'stage': 'offline', 'uid': uid});
    }
    if (path == 'v1/health') {
      return _json({'status': 'ok'});
    }
    if (path == 'metrics') {
      return _text('# flutter_backend\n', 'text/plain; version=0.0.4');
    }

    // ---- boot echo: proof the DB + router live ----
    if (path == '_internal/boot') {
      return _json({'booted': db.getSetting('booted'), 'uid': uid});
    }

    return _json({'detail': 'Not Found', 'path': path}, status: 404);
  };
}

String _resolveUid(Request req) {
  // Any Firebase-shaped Bearer maps to the single local user.
  final auth = req.headers['authorization'];
  return (auth != null && auth.startsWith('Bearer ')) ? kLocalUserId : kLocalUserId;
}

Response _json(Object data, {int status = 200}) => Response(
      status,
      body: jsonEncode(data),
      headers: {'content-type': 'application/json'},
    );

Response _text(String body, String contentType) =>
    Response.ok(body, headers: {'content-type': contentType});