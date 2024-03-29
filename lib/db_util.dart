import 'dart:async';

import 'package:postgres_crdt/postgres_crdt.dart';

/// Convenience class to handle database creation and upgrades
class DbUtil {
  DbUtil._();

  static Future<void> createTables(SqlCrdt crdt) async {
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS auth (
        token TEXT NOT NULL,
        user_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (token)
      )
    ''');
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT NOT NULL,
        name TEXT,
        PRIMARY KEY (id)
      )
    ''');
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS user_lists (
        user_id TEXT NOT NULL,
        list_id TEXT NOT NULL,
        position INTEGER,
        created_at TEXT NOT NULL,
        PRIMARY KEY (user_id, list_id)
      )
    ''');
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS lists (
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        color TEXT NOT NULL,
        creator_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS todos (
        id TEXT NOT NULL,
        list_id TEXT NOT NULL,
        name TEXT NOT NULL,
        done INTEGER DEFAULT 0,
        done_at TEXT,
        done_by TEXT,
        position INTEGER,
        creator_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
  }
}
