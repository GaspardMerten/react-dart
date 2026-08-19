/// A very small VM service client, used to hot reload the SSR server.
///
/// The browser half of `reactx serve` patches new libraries into a running
/// page; without this, the *server* half was still being killed and started
/// again on every save — a fresh process, a second of startup, and any
/// in-memory state gone. The Dart VM can do the same trick natively: its JIT
/// keeps a kernel view of the running isolate, and `reloadSources` swaps in
/// recompiled libraries while the isolate keeps running. Function bodies are
/// updated in place, so an HTTP handler that was registered at startup serves
/// the new code without being re-registered.
///
/// Only three RPCs are needed, so this speaks JSON-RPC over the service
/// WebSocket directly rather than taking on `package:vm_service` — the dev
/// server is not the place to add a dependency that large.
///
/// The same caveats apply as anywhere else in Dart: already-initialised
/// top-level and static fields keep their values, so a changed *initializer*
/// needs a restart. When the VM declines a reload outright, [reload] reports
/// it and the caller restarts the process instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the VM made of a reload request.
class ReloadResult {
  ReloadResult(this.success, [this.message]);

  final bool success;

  /// The VM's reason for refusing, when it did.
  final String? message;
}

class VmService {
  VmService(this.uri);

  /// The `ws://…/ws` endpoint the isolate is listening on.
  final Uri uri;

  WebSocket? _socket;
  var _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  /// Reads the service URI out of the line the VM prints at startup, or returns
  /// null for any other line.
  ///
  /// The VM announces `http://…`; the RPC endpoint is the same authority with a
  /// `ws` scheme and a `ws` path, which is the form this client needs.
  static Uri? parseAnnouncement(String line) {
    final match =
        RegExp(r'(?:Dart VM service|Observatory).*?(https?://\S+)').firstMatch(line);
    if (match == null) return null;
    final http = Uri.tryParse(match.group(1)!);
    if (http == null) return null;
    final path = http.path.endsWith('/') ? '${http.path}ws' : '${http.path}/ws';
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws', path: path);
  }

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    final socket = await WebSocket.connect(uri.toString());
    _socket = socket;
    socket.listen(
      (raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = message['id'];
        // Events carry no id; only replies are awaited.
        if (id == null) return;
        _pending.remove(int.parse('$id'))?.complete(message);
      },
      onDone: _dropConnection,
      onError: (_) => _dropConnection(),
      cancelOnError: true,
    );
  }

  void _dropConnection() {
    _socket = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete({
          'error': {'message': 'the VM service connection closed'}
        });
      }
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _call(
      String method, Map<String, dynamic> params) async {
    await _ensureConnected();
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket!.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future
        .timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      return {
        'error': {'message': '$method timed out'}
      };
    });
  }

  /// The isolate running the app.
  ///
  /// There is normally exactly one; if the app spawned others, the main isolate
  /// is the one to reload, and it is the first the VM lists.
  Future<String?> _mainIsolateId() async {
    final response = await _call('getVM', const {});
    final result = response['result'] as Map<String, dynamic>?;
    final isolates = result?['isolates'] as List?;
    if (isolates == null || isolates.isEmpty) return null;
    for (final isolate in isolates.cast<Map<String, dynamic>>()) {
      if (isolate['name'] == 'main') return isolate['id'] as String?;
    }
    return (isolates.first as Map<String, dynamic>)['id'] as String?;
  }

  /// Recompiles changed libraries into the running isolate.
  Future<ReloadResult> reload() async {
    try {
      final isolateId = await _mainIsolateId();
      if (isolateId == null) {
        return ReloadResult(false, 'no isolate to reload');
      }
      final response =
          await _call('reloadSources', {'isolateId': isolateId});

      final error = response['error'] as Map<String, dynamic>?;
      if (error != null) return ReloadResult(false, '${error['message']}');

      final report = response['result'] as Map<String, dynamic>?;
      if (report?['success'] == true) return ReloadResult(true);

      // A refusal comes back as notices explaining what the VM could not do.
      final notices = report?['notices'] as List?;
      final reason = notices
          ?.cast<Map<String, dynamic>>()
          .map((n) => '${n['message']}')
          .join('; ');
      return ReloadResult(
          false, reason?.isNotEmpty == true ? reason : 'the VM refused');
    } catch (error) {
      return ReloadResult(false, '$error');
    }
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}
