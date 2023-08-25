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

    await TudoServer().serve(
      port: int.parse(result['port']),
      database: result['db'],
      dbHost: result['db-host'],
      dbPort: int.parse(result['db-port']),
      dbUsername: result['db-username'],
      dbPassword: result['db-password'],
    );
  } on ArgParserException catch (e) {
    print('$e\n\nOptions:\n${argParser.usage}');
    exit(64);
  } catch (e) {
    print('$e');
    exit(64);
  }
}
