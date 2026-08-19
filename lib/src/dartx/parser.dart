/// The markup parser: turns a `<...>` region of a `.dartx` file into a
/// [DartxElement] tree.
///
/// It follows JSX's grammar, with three deliberate departures that make it feel
/// native to HTML and to Dart:
///
///   * HTML void elements (`<br>`, `<img src=...>`) may omit the slash.
///   * HTML entities in text and quoted attributes are decoded.
///   * `<!-- ... -->` comments are accepted alongside `{/* ... */}`.
library;

import 'ast.dart';
import 'diagnostics.dart';
import 'scanner.dart';

/// Transpiles the `[start, end)` slice of the source as embedded Dart, which
/// may itself contain markup.
///
/// The parser always works on the whole original source and hands out ranges,
/// never substrings, so every offset — and therefore every error position —
/// stays absolute.
typedef EmbeddedTranspiler = String Function(int start, int end);

/// HTML elements that never have children, so a missing `/` is not an error.
const htmlVoidElements = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

class DartxParser {
  final String src;
  final LineMap lineMap;
  final EmbeddedTranspiler transpileEmbedded;

  int i;

  DartxParser(
    this.src, {
    required this.lineMap,
    required this.transpileEmbedded,
    int start = 0,
  }) : i = start;

  bool get _eof => i >= src.length;

  Never _err(String message, [int? at]) {
    final offset = at ?? i;
    throw DartxError(
      message,
      offset: offset,
      line: lineMap.lineAt(offset),
      column: lineMap.columnAt(offset),
    );
  }

  /// Parses one element or fragment starting at the current `<`. Leaves [i]
  /// just past the element's final `>`.
  DartxElement parseElement() {
    final start = i;
    _expect('<', 'expected an element');

    // Fragment: <>...</>
    if (!_eof && src[i] == '>') {
      i++;
      final children = _parseChildren(ownerName: null, ownerOffset: start);
      _expectSequence('</', 'unclosed fragment `<>`', start);
      _skipWs();
      _expect('>', 'expected `</>` to close the fragment');
      return DartxElement(
        name: null,
        attributes: const [],
        children: children,
        offset: start,
        end: i,
      );
    }

    final name = _readTagName();
    final attributes = <DartxAttribute>[];
    var selfClosing = false;

    while (true) {
      _skipWs();
      if (_eof) _err('unterminated `<$name>` tag', start);
      if (src[i] == '/') {
        i++;
        _expect('>', 'expected `>` after `/`');
        selfClosing = true;
        break;
      }
      if (src[i] == '>') {
        i++;
        break;
      }
      final attribute = _parseAttribute(name);
      if (attribute is DartxNamedAttribute) {
        for (final existing in attributes) {
          if (existing is DartxNamedAttribute &&
              existing.name == attribute.name) {
            _err(
              '`${attribute.name}` is set twice on `<$name>`. On a host element '
              'the second silently wins; on a component it is a duplicate '
              'named argument. Either way one of them is not what you meant.',
              attribute.offset,
            );
          }
        }
      }
      attributes.add(attribute);
    }

    if (selfClosing || htmlVoidElements.contains(name)) {
      return DartxElement(
        name: name,
        attributes: attributes,
        children: const [],
        offset: start,
        end: i,
      );
    }

    final children = _parseChildren(ownerName: name, ownerOffset: start);
    _expectSequence('</', 'unclosed `<$name>` element', start);
    final closeOffset = i;
    final closeName = _readTagName();
    if (closeName != name) {
      _err(
        'closing tag `</$closeName>` does not match opening `<$name>`',
        closeOffset,
      );
    }
    _skipWs();
    _expect('>', 'expected `>` to close `</$name>`');

    return DartxElement(
      name: name,
      attributes: attributes,
      children: children,
      offset: start,
      end: i,
    );
  }

  // -------------------------------------------------------------------------
  // Children
  // -------------------------------------------------------------------------

  List<DartxNode> _parseChildren({
    required String? ownerName,
    required int ownerOffset,
  }) {
    final out = <DartxNode>[];
    final text = StringBuffer();
    var textStart = i;

    void flushText() {
      final normalized = normalizeText(text.toString());
      if (normalized != null) out.add(DartxText(normalized, textStart));
      text.clear();
    }

    while (!_eof) {
      if (src.startsWith('</', i)) {
        flushText();
        return out;
      }
      if (src.startsWith('<!--', i)) {
        flushText();
        final end = src.indexOf('-->', i);
        i = end < 0 ? src.length : end + 3;
        textStart = i;
        continue;
      }
      if (src[i] == '<') {
        flushText();
        out.add(parseElement());
        textStart = i;
        continue;
      }
      if (src[i] == '{') {
        flushText();
        final node = _parseExpressionChild();
        if (node != null) out.add(node);
        textStart = i;
        continue;
      }
      text.write(src[i]);
      i++;
    }

    flushText();
    _err(
      ownerName == null
          ? 'unclosed fragment `<>`'
          : 'unclosed `<$ownerName>` element',
      ownerOffset,
    );
  }

  /// Parses `{ ... }` in child position. Returns `null` for an empty or
  /// comment-only container, which JSX drops.
  DartxNode? _parseExpressionChild() {
    final start = i;
    final end = skipBalancedBraces(src, i);
    if (end < 0) _err('unterminated `{` expression', start);
    i = end;
    if (_isCommentOnly(start + 1, end - 1)) return null;
    return DartxExpression(transpileEmbedded(start + 1, end - 1), start);
  }

  /// True when `[start, end)` holds nothing but whitespace and comments.
  bool _isCommentOnly(int start, int end) =>
      skipWhitespaceAndComments(src, start, end) >= end;

  // -------------------------------------------------------------------------
  // Attributes
  // -------------------------------------------------------------------------

  DartxAttribute _parseAttribute(String ownerName) {
    final start = i;

    if (src[i] == '{') {
      final end = skipBalancedBraces(src, i);
      if (end < 0) _err('unterminated `{` in the `<$ownerName>` tag', start);
      i = end;
      final dots = skipWhitespaceAndComments(src, start + 1, end - 1);
      if (!src.startsWith('...', dots)) {
        _err(
          'expected a spread `{...props}`; a bare `{expr}` is not an attribute',
          start,
        );
      }
      return DartxSpreadAttribute(
        transpileEmbedded(dots + 3, end - 1),
        start,
      );
    }

    final name = _readAttributeName(ownerName);
    _skipWs();
    if (_eof || src[i] != '=') {
      return DartxNamedAttribute(name, const DartxFlagValue(), start);
    }
    i++; // '='
    _skipWs();
    if (_eof) _err('expected a value after `$name=`', start);

    if (src[i] == '{') {
      final valueStart = i;
      final end = skipBalancedBraces(src, i);
      if (end < 0) _err('unterminated `{` in `$name={...}`', valueStart);
      i = end;
      if (_isCommentOnly(valueStart + 1, end - 1)) {
        _err('`$name={}` is empty; give it a value', valueStart);
      }
      return DartxNamedAttribute(
        name,
        DartxExpressionValue(transpileEmbedded(valueStart + 1, end - 1)),
        start,
      );
    }

    if (src[i] == '"' || src[i] == "'") {
      return DartxNamedAttribute(
        name,
        DartxStringValue(_readQuoted()),
        start,
      );
    }

    _err(
      'attribute `$name` must be followed by a quoted string or `{expression}`',
      i,
    );
  }

  /// Reads `"…"` or `'…'`. Markup quoting has no escape character — that is
  /// HTML's rule, not an omission — so a value containing its own quote has to
  /// be written as an expression instead.
  String _readQuoted() {
    final quote = src[i];
    final start = ++i;
    while (!_eof && src[i] != quote) {
      i++;
    }
    if (_eof) {
      _err(
        'unterminated attribute value. Quoted markup values have no escapes, '
        "so a value containing $quote has to be an expression: "
        "title={'…'}.",
        start - 1,
      );
    }
    final value = src.substring(start, i);
    i++; // closing quote
    return decodeEntities(value);
  }

  String _readTagName() {
    final start = i;
    if (_eof || !isIdentifierStart(src.codeUnitAt(i))) {
      _err('expected a tag name');
    }
    i++;
    while (!_eof) {
      final c = src.codeUnitAt(i);
      if (isIdentifierPart(c) || c == 0x2e || c == 0x2d || c == 0x3a) {
        i++; // . - :
      } else {
        break;
      }
    }
    return src.substring(start, i);
  }

  String _readAttributeName(String ownerName) {
    final start = i;
    while (!_eof) {
      final c = src.codeUnitAt(i);
      if (isIdentifierPart(c) || c == 0x2d || c == 0x3a || c == 0x2e) {
        i++;
      } else {
        break;
      }
    }
    if (i == start) {
      _err(
        'unexpected `${src[i]}` in the `<$ownerName>` tag; '
        'expected an attribute, `>` or `/>`',
      );
    }
    return src.substring(start, i);
  }

  // -------------------------------------------------------------------------
  // Low-level
  // -------------------------------------------------------------------------

  void _skipWs() {
    while (!_eof && isWhitespace(src.codeUnitAt(i))) {
      i++;
    }
  }

  void _expect(String ch, String message) {
    if (_eof || src[i] != ch) _err(message);
    i++;
  }

  void _expectSequence(String seq, String message, int at) {
    if (!src.startsWith(seq, i)) _err(message, at);
    i += seq.length;
  }
}

/// JSX whitespace handling: a run of whitespace containing a newline is
/// structural indentation and disappears; everything else collapses to single
/// spaces. Returns `null` when the run should be dropped entirely.
String? normalizeText(String raw) {
  if (raw.isEmpty) return null;
  if (raw.trim().isEmpty) return raw.contains('\n') ? null : ' ';

  final leadingNewline = RegExp(r'^\s*\n').hasMatch(raw);
  final trailingNewline = RegExp(r'\n\s*$').hasMatch(raw);
  var out = raw
      .replaceAll(RegExp(r'\s*\n\s*'), ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ');
  if (leadingNewline) out = out.replaceFirst(RegExp(r'^ '), '');
  if (trailingNewline) out = out.replaceFirst(RegExp(r' $'), '');
  return decodeEntities(out);
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'copy': '©',
  'reg': '®',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'times': '×',
  'middot': '·',
  'laquo': '«',
  'raquo': '»',
  'deg': '°',
  'euro': '€',
  'pound': '£',
  'trade': '™',
};

final _entityPattern = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);');

/// The character [code] names, or null when it names none — a value past the
/// last code point, or a surrogate half. `String.fromCharCode` throws on those,
/// and an entity nobody can render is not worth crashing a build over: it is
/// left as written, exactly like an unknown named entity.
String? _codePoint(int? code) {
  if (code == null || code < 0 || code > 0x10ffff) return null;
  if (code >= 0xd800 && code <= 0xdfff) return null;
  return String.fromCharCode(code);
}

/// Decodes the HTML entities dartx recognises. Unknown entities are left as
/// written, which is what a browser would render anyway.
String decodeEntities(String input) {
  if (!input.contains('&')) return input;
  return input.replaceAllMapped(_entityPattern, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      return _codePoint(int.tryParse(body.substring(2), radix: 16)) ??
          m.group(0)!;
    }
    if (body.startsWith('#')) {
      return _codePoint(int.tryParse(body.substring(1))) ?? m.group(0)!;
    }
    return _namedEntities[body] ?? m.group(0)!;
  });
}
