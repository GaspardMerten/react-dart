/// Positions and errors for the dartx transpiler.
///
/// Every diagnostic points back into the **original `.dartx` source**, so an
/// editor can underline the offending markup directly rather than the
/// generated Dart.
library;

/// Maps byte offsets in a source string to 1-based line/column pairs.
class LineMap {
  final String source;
  final List<int> _lineStarts;

  LineMap(this.source) : _lineStarts = _computeLineStarts(source);

  static List<int> _computeLineStarts(String source) {
    final starts = <int>[0];
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0a) starts.add(i + 1);
    }
    return starts;
  }

  /// 1-based line number containing [offset].
  int lineAt(int offset) {
    var lo = 0, hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }

  /// 1-based column number of [offset].
  int columnAt(int offset) => offset - _lineStarts[lineAt(offset) - 1] + 1;
}

/// A dartx compile error, located in the source it came from.
class DartxError implements Exception {
  final String message;

  /// Byte offset into the original source.
  final int offset;

  /// 1-based line.
  final int line;

  /// 1-based column.
  final int column;

  /// Where the source came from (a path or `-` for stdin), when known.
  final String? uri;

  const DartxError(
    this.message, {
    required this.offset,
    required this.line,
    required this.column,
    this.uri,
  });

  /// Rebuilds this error with [uri] attached (the transpiler knows the message
  /// and position; the caller knows the file).
  DartxError withUri(String? value) => DartxError(
        message,
        offset: offset,
        line: line,
        column: column,
        uri: value ?? uri,
      );

  Map<String, Object?> toJson() => {
        'message': message,
        'offset': offset,
        'line': line,
        'column': column,
        if (uri != null) 'uri': uri,
      };

  @override
  String toString() => '${uri ?? '<dartx>'}:$line:$column: $message';
}
