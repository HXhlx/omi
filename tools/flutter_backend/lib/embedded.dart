import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'src/db.dart';
import 'src/router.dart';

/// The same shelf handler `bin/server.dart` binds, started inside a host
/// process (the Omi Flutter app) instead of a standalone `dart run`.
///
/// Loopback only, and port 0 by default so the OS picks a free one: a host app
/// restart must never collide with its own previous listener, and nothing else
/// on the device or LAN can reach the user's local store.
class LocalBackendServer {
  LocalBackendServer._(this._db, this._server);

  final LocalDb _db;
  final HttpServer _server;

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  /// [dbPath] is the caller's to choose: a host app passes a `path_provider`
  /// location, the standalone server passes `FLUTTER_BACKEND_DB`.
  static Future<LocalBackendServer> start({required String dbPath, int port = 0}) async {
    final file = File(dbPath);
    await file.parent.create(recursive: true);
    final db = LocalDb.open(dbPath);
    await db.migrate();
    db.setSetting('booted', DateTime.now().toIso8601String());

    final server = await shelf_io.serve(_handler(db), InternetAddress.loopbackIPv4, port);
    return LocalBackendServer._(db, server);
  }

  static Handler _handler(LocalDb db) => const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_cors())
      .addHandler(Api(db).handler);

  Future<void> close() async {
    await _server.close(force: true);
    _db.close();
  }
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
