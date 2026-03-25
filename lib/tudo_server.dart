import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crdt_sync/crdt_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';
import 'package:version/version.dart';

import 'db_util.dart';
import 'extensions.dart';

Map<String, Query> _queries(String userId) => {
  // Get all users that share a list with the user
  'users': '''
        SELECT crdt_users_view.id, crdt_users_view.name,
          crdt_users_view.crdt_id, crdt_users_view.crdt_hlc, crdt_users_view.crdt_node_id,
          MAX(crdt_users_view.crdt_modified, crdt_user_lists_view.crdt_modified) AS crdt_modified,
          crdt_users_view.crdt_is_deleted
        FROM crdt_users_view JOIN crdt_user_lists_view ON id = user_id
        WHERE list_id IN (SELECT list_id FROM user_lists WHERE user_id = ?1)
      ''',
  // Get all participants in lists where this user is a member.
  'user_lists': '''
      SELECT user_id, list_id, position, created_at,
        crdt_id, crdt_hlc, crdt_node_id,
        MAX(crdt_user_lists_view.crdt_modified,
          (SELECT crdt_modified FROM crdt_user_lists_view WHERE user_id = ?1)
        ) AS crdt_modified, crdt_is_deleted
      FROM crdt_user_lists_view
      WHERE list_id IN (SELECT list_id FROM user_lists WHERE user_id = ?1)
    ''',
  // '''
  //       SELECT * FROM user_lists
  //       WHERE list_id IN (SELECT list_id FROM user_lists WHERE user_id = ?1)
  //     ''',
  // Get all lists the user is member of
  'lists': '''
        SELECT id, name, color, creator_id, crdt_lists_view.created_at,
          crdt_lists_view.crdt_id, crdt_lists_view.crdt_hlc, crdt_lists_view.crdt_node_id,
          MAX(crdt_lists_view.crdt_modified, crdt_user_lists_view.crdt_modified) AS crdt_modified,
          crdt_lists_view.crdt_is_deleted
        FROM crdt_lists_view JOIN crdt_user_lists_view ON id = list_id
        WHERE user_id = ?1
      ''',
  // Get all todos in lists the user is member of
  'todos': '''
        SELECT id, crdt_todos_view.list_id, name, done, done_at, done_by, crdt_todos_view.position, creator_id, crdt_todos_view.created_at,
          crdt_todos_view.crdt_id, crdt_todos_view.crdt_hlc, crdt_todos_view.crdt_node_id,
          MAX(crdt_todos_view.crdt_modified, crdt_user_lists_view.crdt_modified) AS crdt_modified,
          crdt_todos_view.crdt_is_deleted
        FROM crdt_todos_view JOIN crdt_user_lists_view ON crdt_todos_view.list_id = crdt_user_lists_view.list_id
        WHERE user_id = ?1
      ''',
}.map((table, sql) => MapEntry(table, Query(sql, [userId])));

// Maximum time clients can remain connected without activity
const maxIdleDuration = Duration(minutes: 5);

final minimumVersion = Version(6, 0, 0);

final skipPaths = {'list'};

class TudoServer {
  late final SqliteCrdt _crdt;

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
    _crdt = await SqliteCrdt.open(
      'tudo.db',
      collections: ['auth', 'users', 'user_lists', 'lists', 'todos'],
      onCreate: (db, version) => DbUtil.createTables(db),
      version: 2,
      onUpgrade: (db, from, to) async {
        print('Upgrading $from -> $to');

        // Fix column that was never used
        await db.execute('ALTER TABLE users_old DROP COLUMN created_at');

        for (final table in ['auth', 'users', 'user_lists', 'lists', 'todos']) {
          final result = await db.rawQuery('SELECT * FROM ${table}_old');
          for (final row in result) {
            // Copy CRDT metadata over to dedicated table
            final id =
                switch (table) {
                      'auth' => row['token'],
                      'user_lists' => '${row['user_id']}::${row['list_id']}',
                      _ => row['id'],
                    }
                    as String;
            // Convert to HLC to ensure millisecond precision
            final hlc = Hlc.parse(row['hlc'] as String);
            final modified = Hlc.parse(row['modified'] as String).logicalTime;
            await db.execute(
              '''
                INSERT INTO crdt (collection, id, hlc, modified)
                VALUES (?1, ?2, ?3, ?4)
              ''',
              [table, id, hlc.toString(), modified],
            );
          }
          // Purge soft-deleted rows
          await db.execute('DELETE FROM ${table}_old WHERE is_deleted = 1');
          // Drop CRDT columns
          await db.execute('ALTER TABLE ${table}_old DROP COLUMN is_deleted');
          await db.execute('ALTER TABLE ${table}_old DROP COLUMN hlc');
          await db.execute('ALTER TABLE ${table}_old DROP COLUMN node_id');
          await db.execute('ALTER TABLE ${table}_old DROP COLUMN modified');
        }
        // Copy data over
        await db.execute(
          'INSERT INTO auth (token, user_id, created_at) SELECT * FROM auth_old',
        );
        await db.execute(
          'INSERT INTO users (id, name) SELECT * FROM users_old',
        );
        await db.execute(
          'INSERT INTO user_lists (user_id, list_id, position, created_at) SELECT * FROM user_lists_old',
        );
        await db.execute(
          'INSERT INTO lists (id, name, color, creator_id, created_at) SELECT * FROM lists_old',
        );
        await db.execute(
          'INSERT INTO todos (id, list_id, name, done, done_at, done_by, position, creator_id, created_at) SELECT * FROM todos_old',
        );
        // Drop old tables
        await db.execute('DROP TABLE auth_old');
        await db.execute('DROP TABLE users_old');
        await db.execute('DROP TABLE user_lists_old');
        await db.execute('DROP TABLE lists_old');
        await db.execute('DROP TABLE todos_old');
      },
    );

    // Watch and cache user names
    _crdt
        .watch(
          "SELECT id, name FROM users WHERE name IS NOT NULL AND name <> ''",
        )
        .listen(
          (records) => _userNames = {
            for (final r in records) r['id'] as String: r['name'] as String,
          },
        );

    final router = Router()
      ..options('/<path|.*>', _options)
      ..head('/check_version', _checkVersion)
      ..get('/list/<listId>', _redirectList)
      ..post('/auth/login', _login)
      ..post('/lists/<userId>/<listId>', _joinList)
      ..get('/changeset/<userId>/<peerId>', _getChangeset)
      ..delete('/user/<userId>', _deleteData)
      ..get('/ws/<userId>', _wsHandler)
      ..get('/<path|.*>', () => Response.notFound);

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_validateVersion)
        .addHandler(router.call);

    final server = await io.serve(handler, '0.0.0.0', port);
    print('Serving at http://${server.address.host}:${server.port}');
  }

  Response _options(Request request) => Response(
    HttpStatus.ok,
    headers: {HttpHeaders.allowHeader: 'OPTIONS, GET, HEAD, POST'},
  );

  /// By the time we arrive here, the version has already been checked
  Response _checkVersion(Request request) => Response(HttpStatus.noContent);

  Future<Response> _redirectList(Request request, String listId) async {
    return Response(
      302,
      headers: {HttpHeaders.locationHeader: 'tudo://list/$listId'},
    );
  }

  Future<Response> _login(Request request) async {
    final token =
        request.headers[HttpHeaders.authorizationHeader]?.replaceFirst(
          'bearer ',
          '',
        ) ??
        request.requestedUri.queryParameters['token'];

    final result = await _crdt.query(
      'SELECT user_id FROM auth WHERE token = ?1',
      [token],
    );
    final userId = result.firstOrNull?['user_id'] as String?;

    return userId == null
        ? Response.forbidden('Invalid token')
        : Response.ok(
            jsonEncode({
              'user_id': userId,
              'changeset': await _crdt.getChangeset(
                partialCollections: _queries(userId),
              ),
            }),
          );
  }

  Future<Response> _joinList(
    Request request,
    String userId,
    String listId,
  ) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    await _crdt.transaction((txn) async {
      final maxPosition =
          (await txn.query(
                '''
                  SELECT max(position) as max_position FROM user_lists
                  WHERE user_id = ?1
                ''',
                [userId],
              )).first['max_position']
              as int? ??
          -1;
      await txn.execute(
        '''
          INSERT INTO user_lists (user_id, list_id, created_at, position)
            VALUES (?1, ?2, ?3, ?4)
          ON CONFLICT (user_id, list_id) DO UPDATE SET
            created_at = ?3,
            position = ?4
        ''',
        [userId, listId, DateTime.now().toUtcString, maxPosition + 1],
      );
    });
    return Response(HttpStatus.created);
  }

  Future<Response> _getChangeset(
    Request request,
    String userId,
    String peerId,
  ) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    final changeset = await _crdt.getChangeset(
      partialCollections: _queries(userId),
      exceptNodeId: peerId,
    );
    return Response.ok(jsonEncode(changeset));
  }

  Future<Response> _deleteData(Request request, String userId) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    await _crdt.transaction((txn) async {
      // Anonymize user
      await txn.execute(
        '''
          INSERT INTO users (id, name) VALUES (?1, ?2)
          ON CONFLICT (id) DO UPDATE SET name = ?2
        ''',
        [userId, ''],
      );
      // Unlink all lists
      await txn.execute('DELETE FROM user_lists WHERE user_id = ?1', [userId]);
    });

    return Response(HttpStatus.noContent);
  }

  Future<Response> _wsHandler(Request request, String userId) async {
    try {
      await _validateAuth(request, userId);
    } catch (e) {
      return Response.forbidden('$e');
    }

    final handler = webSocketHandler((webSocket, _) {
      late CrdtSync syncClient;
      syncClient = CrdtSync.server(
        _crdt,
        webSocket,
        changesetBuilder:
            ({
              onlyCollections,
              onlyNodeId,
              exceptNodeId,
              modifiedOn,
              modifiedAfter,
            }) async => _crdt.getChangeset(
              onlyNodeId: onlyNodeId,
              exceptNodeId: exceptNodeId,
              modifiedOn: modifiedOn,
              modifiedAfter: modifiedAfter,
              partialCollections: _queries(userId),
              // onlyCollections == null
              //     ? _queries(userId)
              // : (Map.of(
              //     _queries(userId),
              //   )..removeWhere((key, _) => !onlyCollections.contains(key))),
              // TODO Filter only collections affected by onlyCollections
            ),
        validateRecord: _validateRecord,
        onConnect: (nodeId, _) {
          _refreshClient(syncClient);
          print(
            '${_getName(userId)} (${nodeId.short}): connect [${_connectedClients.length}]',
          );
        },
        onDisconnect: (nodeId, code, reason) {
          _connectedClients.remove(syncClient);
          print(
            '${_getName(userId)} (${nodeId.short}): disconnect [${_connectedClients.length}] $code ${reason ?? ''}',
          );
        },
        onChangesetReceived: (nodeId, recordCounts) {
          _refreshClient(syncClient);
          print(
            '↓ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
          );
        },
        onChangesetSent: (nodeId, recordCounts) => print(
          '↑ ${_getName(userId)} (${nodeId.short}) ${recordCounts.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
        ),
        // verbose: true,
      );
    });

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
    // Allow exceptions through
    if (skipPaths.contains(request.requestedUri.path.split('/')[1])) {
      return innerHandler(request);
    }

    try {
      final userAgent = request.headers[HttpHeaders.userAgentHeader]!;
      final version = Version.parse(
        userAgent.substring(userAgent.indexOf('/') + 1, userAgent.indexOf(' ')),
      );
      return version >= minimumVersion
          ? innerHandler(request)
          : Response(HttpStatus.upgradeRequired);
    } catch (_) {
      return Response.badRequest(body: 'Invalid user agent');
    }
  };

  Future<void> _validateAuth(Request request, String userId) async {
    // Validate token
    final token =
        request.headers[HttpHeaders.authorizationHeader]?.replaceFirst(
          'bearer ',
          '',
        ) ??
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
      final result = await txn.query(
        'SELECT token FROM auth WHERE user_id = ?1',
        [userId],
      );
      knownToken = result.firstOrNull?['token'] as String?;

      // Associate new token with user id
      if (knownToken == null) {
        await txn.execute(
          '''
            INSERT INTO auth (user_id, token, created_at)
            VALUES (?1, ?2, ?3)
          ''',
          [userId, token, DateTime.now().toUtcString],
        );
        knownToken = token;
      }
    });

    // Verify that user id and token match
    if (token != knownToken) {
      throw 'Invalid token for supplied user id: $userId\n$token';
    }
  }

  bool _validateRecord(String table, CrdtRecord record) =>
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
