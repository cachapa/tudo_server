import 'dart:async';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:version/version.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'db_util.dart';
import 'extensions.dart';

class TudoServer {
  final String? apiSecret;
  late final SqlCrdt _crdt;
  late final CrdtSyncServer _crdtSync;

  TudoServer(this.apiSecret);

  Future<void> serve({
    required int port,
    required String database,
    required String dbHost,
    required int dbPort,
    String? dbUsername,
    String? dbPassword,
  }) async {
    _crdt = await PostgresCrdt.open(
      database,
      host: dbHost,
      port: dbPort,
      username: dbUsername,
      password: dbPassword,
    );
    await DbUtil.createTables(_crdt);
    _crdtSync = CrdtSyncServer(_crdt);

    final router = Router()
      ..head('/check_version', _checkVersion)
      ..get('/auth/<userId>', _auth)
      ..get('/ws/<userId>', _wsHandler);

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_validateVersion)
        .addMiddleware(_validateSecret)
        .addMiddleware(_validateCredentials)
        .addHandler(router);

    var server = await io.serve(handler, '0.0.0.0', port);
    print('Serving at http://${server.address.host}:${server.port}');
  }

  Response _checkVersion(Request request) => _isVersionSupported(request)
      ? Response(HttpStatus.noContent)
      : Response(HttpStatus.upgradeRequired);

  /// By the time we arrive here, both the secret and credentials have been validated
  Response _auth(Request request) => Response(HttpStatus.noContent);

  Future<Response> _wsHandler(Request request, String userId) async {
    final handler = webSocketHandler((WebSocketChannel webSocket) async {
      await _crdtSync.handle(
        webSocket,
        tables: ['users', 'user_lists', 'lists', 'todos'],
        onConnect: (nodeId, __) => print(
            '${userId.short} (${nodeId.short}): connect [${_crdtSync.clientCount}]'),
        onDisconnect: (nodeId, code, reason) => print(
            '${userId.short} (${nodeId.short}): leave [${_crdtSync.clientCount}] $code $reason'),
        onChangesetReceived: (recordCounts) => print(
            '⬇️ ${userId.short} ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}'),
        onChangesetSent: (recordCounts) => print(
            '⬆️ ${userId.short} ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}'),
        queryBuilder: (table, lastModified, remoteNodeId) =>
            _queryBuilder(userId, table, lastModified, remoteNodeId),
      );
    });
    return await handler(request);
  }

  (String, List<Object?>)? _queryBuilder(
      String userId, String table, Hlc lastModified, String remoteNodeId) {
    final query = switch (table) {
      'users' => '''
          SELECT users.id, users.name, users.is_deleted, users.hlc FROM
            (SELECT user_id, max(created_at) AS created_at FROM
              (SELECT list_id FROM user_lists WHERE user_id = ?1 AND is_deleted = 0) AS list_ids
              JOIN user_lists ON user_lists.list_id = list_ids.list_id
              GROUP BY user_lists.user_id
            ) AS user_ids
          JOIN users ON users.id = user_ids.user_id
          WHERE node_id != ?2
            AND modified > CASE WHEN user_ids.created_at >= ?3 THEN '' ELSE ?3 END
        ''',
      'user_lists' => '''
          SELECT user_lists.list_id, user_id, position, user_lists.created_at, is_deleted, hlc FROM
            (SELECT list_id, created_at FROM user_lists WHERE user_id = ?1) AS own_lists
          JOIN user_lists ON own_lists.list_id = user_lists.list_id
          WHERE node_id != ?2
            AND modified > CASE WHEN own_lists.created_at >= ?3 THEN '' ELSE ?3 END
        ''',
      'lists' => '''
          SELECT lists.id, lists.name, lists.color, lists.creator_id,
            lists.created_at, lists.is_deleted, lists.hlc FROM user_lists
          JOIN lists ON list_id = lists.id AND user_id = ?1 AND user_lists.is_deleted = 0
          WHERE lists.node_id != ?2
            AND lists.modified > CASE WHEN user_lists.created_at >= ?3 THEN '' ELSE ?3 END
        ''',
      'todos' => '''
          SELECT todos.id, todos.list_id, todos.name, todos.done, todos.position,
            todos.creator_id, todos.created_at, todos.done_at, todos.done_by,
            todos.is_deleted, todos.hlc FROM user_lists
          JOIN todos ON user_lists.list_id = todos.list_id AND user_id = ?1 AND user_lists.is_deleted = 0
          WHERE todos.node_id != ?2
            AND todos.modified > CASE WHEN user_lists.created_at >= ?3 THEN '' ELSE ?3 END
        ''',
      _ => throw "$table: I've never seen this table in my life!"
    };
    return (query, [userId, remoteNodeId, lastModified]);
  }

  Handler _validateVersion(Handler innerHandler) => (request) =>
      _isVersionSupported(request) ? innerHandler(request) : Response(426);

  Handler _validateSecret(Handler innerHandler) => (request) async {
        // Skip if secret isn't set
        if (apiSecret == null) return innerHandler(request);

        // Do not validate for public paths
        if (['check_version'].contains(request.url.path)) {
          return innerHandler(request);
        }

        final suppliedSecret =
            request.requestedUri.queryParameters['api_secret'] ?? '';
        if (suppliedSecret == apiSecret) {
          return innerHandler(request);
        } else {
          return Response.forbidden('Invalid API secret: $suppliedSecret');
        }
      };

  Handler _validateCredentials(Handler innerHandler) => (request) async {
        // Do not validate for public paths
        if (['check_version'].contains(request.url.path)) {
          return innerHandler(request);
        }

        final userId =
            request.headers['user_id'] ?? request.url.pathSegments.last;
        final token = request.requestedUri.queryParameters['token'];

        // Validate user id length
        if (userId.length != 36) {
          return Response.forbidden('Invalid user id: $userId');
        }

        // Validate token length
        // print(token!.length);
        if (token == null || token.length < 32 || token.length > 128) {
          return Response.forbidden('Invalid token: $token');
        }

        // Associate token with user id, if it doesn't exist yet
        String? knownToken;
        await _crdt.transaction((txn) async {
          // Check if there's a token in the db
          // This is done in a transaction to make sure the check and creation
          // happen atomically
          final result = await txn
              .query('SELECT token FROM auth WHERE user_id = ?1', [userId]);
          knownToken = result.isEmpty ? null : result.first['token'] as String?;

          // Associate new token with user id
          if (knownToken == null) {
            await txn.execute('''
              INSERT INTO auth (user_id, token, created_at)
              VALUES (?1, ?2, ?3)
            ''', [userId, token, DateTime.now()]);
            knownToken = token;
          }
        });

        // Verify that user id and token match
        return token == knownToken
            ? innerHandler(request)
            : Response.forbidden(
                'Invalid token for supplied user id: $userId\n$token');
      };

  bool _isVersionSupported(Request request) {
    final userAgent = request.headers[HttpHeaders.userAgentHeader]!;
    final version = Version.parse(userAgent.substring(
        userAgent.indexOf('/') + 1, userAgent.indexOf(' ')));
    return version >= Version(2, 3, 0);
  }
}

class CrdtStream {
  final _controller = StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void add(String event) => _controller.add(event);

  void close() => _controller.close();
}
