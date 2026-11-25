import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:flutter_backend/src/db.dart';
import 'package:flutter_backend/src/router.dart';

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
      .addHandler(Api(db).handler);

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