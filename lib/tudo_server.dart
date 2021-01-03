import 'dart:async';

import 'package:crdt/crdt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';

class TudoServer {
  final _nodeId = Uuid().v4();
  final _crdts = <String, Crdt>{};
  final _streams = <Crdt, CrdtStream>{};

  Future<void> serve(int port) async {
    var router = Router()
      ..get('/<ignored|.*>/ws', _wsHandler)
      ..get('/<ignored|.*>', _getCrdtHandler)
      ..post('/<ignored|.*>', _postCrdtHandler)
      // Return 404 for everything else
      ..all('/<ignored|.*>', _notFoundHandler);

    var handler =
        const Pipeline().addMiddleware(logRequests()).addHandler(router);

    var server = await io.serve(handler, '0.0.0.0', port);
    print('Serving at http://${server.address.host}:${server.port}');
  }

  Future<Response> _getCrdtHandler(Request request) async {
    var crdt = _getCrtd(request);
    return await _crdtResponse(crdt);
  }

  Future<Response> _postCrdtHandler(Request request) async {
    var crdt = _getCrtd(request);

    try {
      var json = await request.readAsString();
      await _merge(crdt, json, null);
      return await _crdtResponse(crdt);
    } on ClockDriftException catch (e) {
      return _errorResponse(e);
    }
  }

  void _merge(Crdt crdt, String json, Hlc lastSync) {
    print('<= $json');
    crdt.mergeJson(json);

    final changeset = crdt.toJson(modifiedSince: lastSync);
    if (changeset != '{}') {
      print('=> $changeset');
      _streams[crdt]?.add(changeset);
    }
  }

  Response _crdtResponse(Crdt crdt) => Response.ok(crdt.toJson());

  Response _errorResponse(Exception e) => Response(412, body: '$e');

  Response _notFoundHandler(Request request) => Response.notFound('Not found');

  Crdt _getCrtd(Request request) {
    var key = request.url.path;
    if (key.endsWith('/ws')) key = key.substring(0, key.length - 3);

    if (!_crdts.containsKey(key)) {
      _crdts[key] = CrdtMap(_nodeId);
    }
    return _crdts[key];
  }

  CrdtStream _getStream(Crdt crdt) {
    if (!_streams.containsKey(crdt)) {
      _streams[crdt] = CrdtStream();
    }
    return _streams[crdt];
  }

  Response _wsHandler(Request request) {
    var crdt = _getCrtd(request);
    var crdtStream = _getStream(crdt);

    var handler = webSocketHandler((webSocket) async {
      print('Client connected to ${request.url.path}');

      webSocket.sink.addStream(crdtStream.stream);

      Hlc lastSync;
      webSocket.stream.listen(
        (message) {
          _merge(crdt, message, lastSync);
          lastSync = crdt.canonicalTime;
        },
        onDone: () {
          // crdtStream.close();
          // _streams.remove(crdt);
          print('Client disconnected from ${request.url.path}');
        },
      );
    });

    return handler(request);
  }
}

class CrdtStream {
  final _controller = StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void add(String event) => _controller.add(event);

  void close() => _controller.close();
}
