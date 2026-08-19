/// Translating positions between a `.dartx` file and the Dart it compiles to.
///
/// This is the piece that lets the Dart analysis server answer questions about
/// a file it has never seen. The analyser works on `foo.dartx.dart`; the editor
/// asks about `foo.dartx`. Something has to carry a cursor across.
///
/// The translation leans on the one property the transpiler guarantees:
/// **line numbers are preserved exactly**. Markup is emitted on a single line
/// and padded with the newlines it consumed, so line *N* of the generated Dart
/// is line *N* of the `.dartx`. That reduces a two-dimensional problem to a
/// one-dimensional one — the column.
///
/// Columns are recovered by identifier, not by arithmetic. Within a line the
/// transpiler preserves the *order* of identifiers and copies embedded Dart
/// through verbatim, so the k-th occurrence of `todo` on a source line is the
/// k-th occurrence of `todo` on the generated line. That is exact for embedded
/// expressions, which is where the identifiers a person points at live.
///
/// Where it is approximate, and honestly so:
///
///  * A component name is rewritten: `<StatCard …>` emits `StatCardProps(…)`.
///    Pointing at `StatCard` resolves to `StatCardProps`, the generated type —
///    which is the thing the call site actually constructs, so it is a useful
///    answer rather than a wrong one.
///  * An attribute name is rewritten too (`class` → `className`), and a
///    markup-only identifier that does not survive into the output has no
///    answer at all. Both return null rather than guessing.
///
/// A real source map would remove the approximation, and the transpiler could
/// emit one — but it would mean threading generated offsets through the
/// emitter's string composition. This gets the common cases exactly right
/// without touching a component that markup compilation depends on.
library;

/// A zero-based line and column, the shape LSP speaks.
final class Spot {
  const Spot(this.line, this.column);
  final int line;
  final int column;

  @override
  bool operator ==(Object other) =>
      other is Spot && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(line, column);

  @override
  String toString() => '$line:$column';
}

/// Maps positions between one `.dartx` buffer and its generated Dart.
final class PositionMap {
  PositionMap({required String source, required String generated})
      : _sourceLines = source.split('\n'),
        _generatedLines = generated.split('\n');

  final List<String> _sourceLines;
  final List<String> _generatedLines;

  /// Where [spot] in the `.dartx` lands in the generated Dart, or null when
  /// nothing there survives compilation.
  Spot? toGenerated(Spot spot) => _translate(spot, _sourceLines, _generatedLines);

  /// The reverse, for turning an answer back into something the editor can
  /// show against the file the person is actually looking at.
  Spot? toSource(Spot spot) => _translate(spot, _generatedLines, _sourceLines);

  Spot? _translate(Spot spot, List<String> from, List<String> to) {
    if (spot.line < 0 || spot.line >= from.length) return null;
    if (spot.line >= to.length) return null;

    final word = _wordAt(from[spot.line], spot.column);
    // Not on an identifier — punctuation, whitespace. The line is right and
    // that is all that can be said, so say exactly that.
    if (word == null) return Spot(spot.line, 0);

    final occurrence = _occurrenceOf(from[spot.line], word.start, word.text);
    final target = _nthOccurrence(to[spot.line], word.text, occurrence);
    if (target != null) return Spot(spot.line, target);

    // The identifier was rewritten. A component name grows a suffix, which is
    // the one rewrite worth following: `StatCard` -> `StatCardProps`.
    final grown = _nthOccurrence(to[spot.line], word.text, 0, prefix: true);
    if (grown != null) return Spot(spot.line, grown);

    return null;
  }

  /// The identifier containing or immediately before [column].
  static _Word? _wordAt(String line, int column) {
    if (line.isEmpty) return null;
    var i = column.clamp(0, line.length);
    // A cursor sitting just past the end of a word still means that word.
    if (i == line.length || !_isWordChar(line.codeUnitAt(i))) {
      if (i == 0 || !_isWordChar(line.codeUnitAt(i - 1))) return null;
      i--;
    }
    var start = i;
    while (start > 0 && _isWordChar(line.codeUnitAt(start - 1))) {
      start--;
    }
    var end = i;
    while (end + 1 < line.length && _isWordChar(line.codeUnitAt(end + 1))) {
      end++;
    }
    return _Word(line.substring(start, end + 1), start);
  }

  /// How many times [word] already appeared on [line] before [start].
  static int _occurrenceOf(String line, int start, String word) {
    var count = 0;
    var i = 0;
    while (i < start) {
      final at = line.indexOf(word, i);
      if (at < 0 || at >= start) break;
      if (_isWholeWord(line, at, word.length)) count++;
      i = at + 1;
    }
    return count;
  }

  /// The column of the [n]-th whole-word occurrence of [word] in [line], or of
  /// the [n]-th identifier *starting with* [word] when [prefix] is set.
  static int? _nthOccurrence(String line, String word, int n,
      {bool prefix = false}) {
    var count = 0;
    var i = 0;
    while (true) {
      final at = line.indexOf(word, i);
      if (at < 0) return null;
      final ok = prefix
          ? _startsWord(line, at)
          : _isWholeWord(line, at, word.length);
      if (ok) {
        if (count == n) return at;
        count++;
      }
      i = at + 1;
    }
  }

  static bool _isWholeWord(String line, int at, int length) =>
      _startsWord(line, at) &&
      (at + length >= line.length || !_isWordChar(line.codeUnitAt(at + length)));

  static bool _startsWord(String line, int at) =>
      at == 0 || !_isWordChar(line.codeUnitAt(at - 1));

  static bool _isWordChar(int c) =>
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x5f ||
      c == 0x24;
}

final class _Word {
  const _Word(this.text, this.start);
  final String text;
  final int start;
}
