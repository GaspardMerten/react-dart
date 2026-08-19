/// LSP's wire format: `Content-Length` headers around JSON bodies.
///
/// Small on purpose. The proxy in `server.dart` needs to read and write this
/// on two connections — the editor's and the analysis server's — and nothing
/// about the framing differs between them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Turns a byte stream of LSP frames into decoded messages.
///
/// Reads headers and body as *bytes*, because `Content-Length` counts bytes,
/// not characters — decoding first would mis-split any message containing a
/// character outside ASCII, which for an editor means any message containing a
/// person's identifier or a doc comment.
Stream<Map<String, Object?>> readMessages(Stream<List<int>> input) {
  var buffer = Uint8List(0);

  return input.transform(
    StreamTransformer<List<int>, Map<String, Object?>>.fromHandlers(
      handleData: (chunk, sink) {
        buffer = Uint8List.fromList([...buffer, ...chunk]);

        while (true) {
          final headerEnd = _indexOfHeaderEnd(buffer);
          if (headerEnd < 0) return;

          final headers = utf8.decode(buffer.sublist(0, headerEnd));
          final length = _contentLength(headers);
          if (length == null) {
            // Unparseable header: drop it rather than stalling forever.
            buffer = Uint8List.sublistView(buffer, headerEnd + 4);
            continue;
          }

          final bodyStart = headerEnd + 4;
          if (buffer.length < bodyStart + length) return; // wait for the rest

          final body = utf8.decode(buffer.sublist(bodyStart, bodyStart + length));
          buffer = Uint8List.fromList(buffer.sublist(bodyStart + length));

          try {
            final decoded = jsonDecode(body);
            if (decoded is Map<String, Object?>) sink.add(decoded);
          } catch (_) {
            // A malformed body is the other side's problem; keep the
            // connection rather than taking the editor down with it.
          }
        }
      },
    ),
  );
}

/// Encodes [message] as one LSP frame.
List<int> frame(Map<String, Object?> message) {
  final body = utf8.encode(jsonEncode(message));
  final header = utf8.encode('Content-Length: ${body.length}\r\n\r\n');
  return [...header, ...body];
}

int _indexOfHeaderEnd(Uint8List buffer) {
  for (var i = 0; i + 3 < buffer.length; i++) {
    if (buffer[i] == 0x0d &&
        buffer[i + 1] == 0x0a &&
        buffer[i + 2] == 0x0d &&
        buffer[i + 3] == 0x0a) {
      return i;
    }
  }
  return -1;
}

int? _contentLength(String headers) {
  for (final line in headers.split('\r\n')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    if (line.substring(0, colon).trim().toLowerCase() != 'content-length') {
      continue;
    }
    return int.tryParse(line.substring(colon + 1).trim());
  }
  return null;
}
