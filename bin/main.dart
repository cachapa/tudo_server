import 'dart:io';

import 'package:args/args.dart';
import 'package:tudo_server/tudo_server.dart';

void main(List<String> args) async {
  final argParser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080')
    ..addOption('db', defaultsTo: 'tudo')
    ..addOption('db-host', defaultsTo: 'localhost')
    ..addOption('db-port', defaultsTo: '5432')
    ..addOption('db-username')
    ..addOption('db-password')
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Display this help and exit');

  try {
    final result = argParser.parse(args);

    if (result['help']) {
      print('Options:\n${argParser.usage}');
      exit(0);
    }

    final env = Platform.environment;

    final port = int.parse(env['TUDO_SERVER_PORT'] ?? result['port']);
    final database = env['TUDO_SERVER_DB'] ?? result['db'];
    final dbHost = env['TUDO_SERVER_DB_HOST'] ?? result['db-host'];
    final dbPort = int.parse(env['TUDO_SERVER_DB_PORT'] ?? result['db-port']);
    final dbUsername = env['TUDO_SERVER_DB_USERNAME'] ?? result['db-username'];
    final dbPassword = env['TUDO_SERVER_DB_PASSWORD'] ?? result['db-password'];

    await TudoServer().serve(
      port: port,
      database: database,
      dbHost: dbHost,
      dbPort: dbPort,
      dbUsername: dbUsername,
      dbPassword: dbPassword,
    );
  } on ArgParserException catch (e) {
    print('$e\n\nOptions:\n${argParser.usage}');
    exit(64);
  } catch (e) {
    print('$e');
    exit(64);
  }
}
