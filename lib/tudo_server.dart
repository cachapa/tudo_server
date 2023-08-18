import 'dart:async';
import 'dart:convert';
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

const _queries = {
  'users': '''
    SELECT users.id, users.name, users.is_deleted, users.hlc FROM
      (SELECT user_id, max(created_at) AS created_at FROM
        (SELECT list_id FROM user_lists WHERE user_id = ?1 AND is_deleted = 0) AS list_ids
        JOIN user_lists ON user_lists.list_id = list_ids.list_id
        GROUP BY user_lists.user_id
      ) AS user_ids
    JOIN users ON users.id = user_ids.user_id
  ''',
  'user_lists': '''
    SELECT user_lists.list_id, user_id, position, user_lists.created_at, is_deleted, hlc FROM
      (SELECT list_id, created_at FROM user_lists WHERE user_id = ?1) AS own_lists
    JOIN user_lists ON own_lists.list_id = user_lists.list_id
  ''',
  'lists': '''
    SELECT * FROM (SELECT lists.id, lists.name, lists.color, lists.creator_id,
      lists.created_at, lists.is_deleted, lists.hlc, lists.node_id,
      CASE WHEN lists.modified > user_lists.modified THEN lists.modified ELSE user_lists.modified END AS modified
    FROM user_lists
    JOIN lists ON list_id = lists.id AND user_id = ?1 AND user_lists.is_deleted = 0) a
  ''',
  'todos': '''
    SELECT * FROM (SELECT todos.id, todos.list_id, todos.name, todos.done, todos.position,
      todos.creator_id, todos.created_at, todos.done_at, todos.done_by,
      todos.is_deleted, todos.hlc, todos.node_id,
      CASE WHEN todos.modified > user_lists.modified THEN todos.modified ELSE user_lists.modified END AS modified
      FROM user_lists
    JOIN todos ON user_lists.list_id = todos.list_id AND user_id = ?1 AND user_lists.is_deleted = 0) a
  ''',
};

class TudoServer {
  final String? apiSecret;
  late final SqlCrdt _crdt;
  late final CrdtSyncServer _syncServer;

  var _clientCount = 0;
  var _userNames = <String, String>{};

  TudoServer(this.apiSecret);

  Future<void> serve({
    required int port,
    required String database,
    required String dbHost,
    required int dbPort,
    String? dbUsername,
    String? dbPassword,
  }) async {
    try {
      _crdt = await PostgresCrdt.open(
        database,
        host: dbHost,
        port: dbPort,
        username: dbUsername,
        password: dbPassword,
      );
    } catch (e) {
      print('Failed to open Postgres database.');
      rethrow;
    }
    await DbUtil.createTables(_crdt);
    _syncServer = CrdtSyncServer(
      _crdt,
      verbose: true,
    );

    // Watch and cache user names
    _crdt.watch("SELECT id, name FROM users WHERE name <> ''").listen(
        (records) => _userNames = {
              for (final r in records) r['id'] as String: r['name'] as String
            });

    final router = Router()
      ..head('/check_version', _checkVersion)
      ..get('/auth/<userId>', _auth)
      ..post('/lists/<userId>/<listId>', _joinList)
      ..get('/changeset/<userId>/<peerId>', _getChangeset)
      ..get('/ws/<userId>', _wsHandler);

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_validateVersion)
        .addMiddleware(_validateSecret)
        .addMiddleware(_validateCredentials)
        .addHandler(router);

    var server = await io.serve(handler, '0.0.0.0', port);
    print('Serving at http://${server.address.host}:${server.port}');
    if (apiSecret != null) print('Secret: $apiSecret');
  }

  Response _checkVersion(Request request) => _isVersionSupported(request)
      ? Response(HttpStatus.noContent)
      : Response(HttpStatus.upgradeRequired);

  /// By the time we arrive here, both the secret and credentials have been validated
  Response _auth(Request request, String userId) =>
      Response(HttpStatus.noContent);

  Future<Response> _joinList(
      Request request, String userId, String listId) async {
    await _crdt.transaction((txn) async {
      final maxPosition = (await txn.query('''
        SELECT max(position) as max_position FROM user_lists
        WHERE user_id = ?1 AND is_deleted = 0
      ''', [userId])).first['max_position'] as int? ?? -1;
      await txn.execute('''
        INSERT INTO user_lists (user_id, list_id, created_at, position, is_deleted)
          VALUES (?1, ?2, ?3, ?4, 0)
        ON CONFLICT (user_id, list_id) DO UPDATE SET
          created_at = ?3,
          position = ?4,
          is_deleted = 0
      ''', [userId, listId, DateTime.now().toUtcString, maxPosition + 1]);
    });
    return Response(HttpStatus.created);
  }

  Future<Response> _getChangeset(
      Request request, String userId, String peerId) async {
    final changeset = await CrdtSync.getChangeset(
      _crdt,
      _queries.map((table, sql) => MapEntry(table, (sql, [userId]))),
      isClient: false,
      peerId: peerId,
      afterHlc: Hlc.zero(_crdt.nodeId),
    );
    return Response.ok(jsonEncode(changeset));
  }

  Future<Response> _wsHandler(Request request, String userId) async {
    final handler = webSocketHandler(
      pingInterval: Duration(seconds: 20),
      (WebSocketChannel webSocket) {
        CrdtSync(
          _crdt,
          webSocket,
          isClient: false,
          changesetQueries:
              _queries.map((table, sql) => MapEntry(table, (sql, [userId]))),
          onConnect: (nodeId, __) => print(
              '${_getName(userId)} (${nodeId.short}): connect [${_clientCount++}]'),
          onDisconnect: (nodeId, code, reason) => print(
              '${_getName(userId)} (${nodeId.short}): disconnect [${_clientCount--}] $code ${reason ?? ''}'),
          onChangesetReceived: (nodeId, recordCounts) => print(
              '⬇️ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}'),
          onChangesetSent: (nodeId, recordCounts) => print(
              '⬆️ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}'),
          // verbose: true,
        );
      },
    );
    return await handler(request);
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
          return _forbidden('Invalid API secret: $suppliedSecret');
        }
      };

  Handler _validateCredentials(Handler innerHandler) => (request) async {
        // Do not validate for public paths
        if (['check_version'].contains(request.url.path)) {
          return innerHandler(request);
        }

        final userId =
            request.headers['user_id'] ?? request.url.pathSegments[1];
        final token = request.headers[HttpHeaders.authorizationHeader]
                ?.replaceFirst('bearer ', '') ??
            request.requestedUri.queryParameters['token'];

        // Validate user id length
        if (userId.length != 36) {
          return _forbidden('Invalid user id: $userId');
        }

        // Validate token length
        if (token == null || token.length < 32 || token.length > 128) {
          return _forbidden('Invalid token: $token');
        }

        // Associate token with user id, if it doesn't exist yet
        String? knownToken;
        await _crdt.transaction((txn) async {
          // Check if there's a token in the db
          // This is done in a transaction to make sure the check and creation
          // happen atomically
          final result = await txn
              .query('SELECT token FROM auth WHERE user_id = ?1', [userId]);
          knownToken = result.firstOrNull?['token'] as String?;

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
            : _forbidden('Invalid token for supplied user id: $userId\n$token');
      };

  bool _isVersionSupported(Request request) {
    final userAgent = request.headers[HttpHeaders.userAgentHeader]!;
    final version = Version.parse(userAgent.substring(
        userAgent.indexOf('/') + 1, userAgent.indexOf(' ')));
    return version >= Version(2, 3, 4);
  }

  Response _forbidden(String message) {
    print('Forbidden: $message');
    return Response.forbidden(message);
  }

  String _getName(String userId) => _userNames[userId] ?? userId.short;
}

class CrdtStream {
  final _controller = StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void add(String event) => _controller.add(event);

  void close() => _controller.close();
}
