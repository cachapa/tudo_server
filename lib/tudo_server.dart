import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crdt_sync/crdt_sync_server.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:version/version.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'db_util.dart';
import 'extensions.dart';

Map<String, Query> _queries(String userId) => {
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
    }.map((table, sql) => MapEntry(table, (sql, [userId])));

// Maximum time clients can remain connected without activity
const maxIdleDuration = Duration(minutes: 5);

final minimumVersion = Version(2, 3, 4);

class TudoServer {
  late final SqlCrdt _crdt;

  final _connectedClients = <CrdtSync, DateTime>{};
  var _userNames = <String, String>{};

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
        sslMode: SslMode.disable,
      );
    } catch (e) {
      print('Failed to open Postgres database.');
      rethrow;
    }
    await DbUtil.createTables(_crdt);

    // Watch and cache user names
    _crdt.watch("SELECT id, name FROM users WHERE name <> ''").listen(
        (records) => _userNames = {
              for (final r in records) r['id'] as String: r['name'] as String
            });

    final router = Router()
      ..head('/check_version', _checkVersion)
      ..post('/auth/login', _login)
      ..post('/lists/<userId>/<listId>', _joinList)
      ..get('/changeset/<userId>/<peerId>', _getChangeset)
      ..get('/ws/<userId>', _wsHandler);

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_validateVersion)
        .addHandler(router.call);

    final server = await io.serve(handler, '0.0.0.0', port);
    print('Serving at http://${server.address.host}:${server.port}');
  }

  /// By the time we arrive here, the version has already been checked
  Response _checkVersion(Request request) => Response(HttpStatus.noContent);

  Future<Response> _login(Request request) async {
    final token = request.headers[HttpHeaders.authorizationHeader]
            ?.replaceFirst('bearer ', '') ??
        request.requestedUri.queryParameters['token'];

    final result = await _crdt.query(
        'SELECT user_id FROM auth WHERE token = ?1 AND is_deleted = 0',
        [token]);
    final userId = result.firstOrNull?['user_id'] as String?;

    return userId == null
        ? Response.forbidden('Invalid token')
        : Response.ok(jsonEncode({
            'user_id': userId,
            'changeset':
                await _crdt.getChangeset(customQueries: _queries(userId)),
          }));
  }

  Future<Response> _joinList(
      Request request, String userId, String listId) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

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
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    final changeset = await _crdt.getChangeset(
      customQueries: _queries(userId),
      exceptNodeId: peerId,
    );
    return Response.ok(jsonEncode(changeset));
  }

  Future<Response> _wsHandler(Request request, String userId) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    final handler = webSocketHandler(
      (WebSocketChannel webSocket) {
        late CrdtSync syncClient;
        syncClient = CrdtSync.server(
          _crdt,
          webSocket,
          changesetBuilder: (
                  {exceptNodeId,
                  modifiedAfter,
                  modifiedOn,
                  onlyNodeId,
                  onlyTables}) =>
              _crdt.getChangeset(
                  onlyTables: onlyTables,
                  customQueries: _queries(userId),
                  onlyNodeId: onlyNodeId,
                  exceptNodeId: exceptNodeId,
                  modifiedOn: modifiedOn,
                  modifiedAfter: modifiedAfter),
          validateRecord: _validateRecord,
          onConnect: (nodeId, __) {
            _refreshClient(syncClient);
            print(
                '${_getName(userId)} (${nodeId.short}): connect [${_connectedClients.length}]');
          },
          onDisconnect: (nodeId, code, reason) {
            _connectedClients.remove(syncClient);
            print(
                '${_getName(userId)} (${nodeId.short}): disconnect [${_connectedClients.length}] $code ${reason ?? ''}');
          },
          onChangesetReceived: (nodeId, recordCounts) {
            _refreshClient(syncClient);
            print(
                '⬇️ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}');
          },
          onChangesetSent: (nodeId, recordCounts) => print(
              '⬆️ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}'),
          // verbose: true,
        );
      },
    );

    return await handler(request);
  }

  void _refreshClient(CrdtSync syncClient) {
    final now = DateTime.now();
    // Reset client's idle time
    _connectedClients[syncClient] = now;
    // Close stale connections
    _connectedClients.forEach((client, lastAccess) {
      final idleTime = now.difference(lastAccess);
      if (idleTime > maxIdleDuration) {
        print('Closing idle client: (${syncClient.peerId!.short})');
        client.close();
      }
    });
  }

  Handler _validateVersion(Handler innerHandler) => (request) {
        final userAgent = request.headers[HttpHeaders.userAgentHeader]!;
        final version = Version.parse(userAgent.substring(
            userAgent.indexOf('/') + 1, userAgent.indexOf(' ')));
        return version >= minimumVersion
            ? innerHandler(request)
            : Response(HttpStatus.upgradeRequired);
      };

  Future<void> _validateAuth(Request request, String userId) async {
    // Validate token
    final token = request.headers[HttpHeaders.authorizationHeader]
            ?.replaceFirst('bearer ', '') ??
        request.requestedUri.queryParameters['token'];
    if (token == null || token.length < 32 || token.length > 128) {
      throw 'Invalid token: $token';
    }

    // Validate user id
    final userId = request.headers['user_id'] ?? request.url.pathSegments[1];
    if (userId.length != 36) {
      throw 'Invalid user id: $userId';
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
    if (token != knownToken) {
      throw 'Invalid token for supplied user id: $userId\n$token';
    }
  }

  bool _validateRecord(String table, Map<String, dynamic> record) =>
      // Disallow external changes to the auth table
      table != 'auth';

  String _getName(String userId) => _userNames[userId] ?? userId.short;
}

class CrdtStream {
  final _controller = StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void add(String event) => _controller.add(event);

  void close() => _controller.close();
}
