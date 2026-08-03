/// A JSX-like template syntax that compiles to [VNode]s.
///
/// ```dart
/// jsx(r'''
///   <div class="card">
///     <h1>${0}</h1>
///     <button onClick=${1}>+</button>
///     ${2}
///   </div>
/// ''', [title, handleClick, childVNode]);
/// ```
///
/// Rules:
///   * Use a **raw string** (`r'...'`) so `${0}`, `${1}`, ... are treated as
///     literal interpolation slots, indexing into the args list.
///   * `${n}` in text or as a child inserts `args[n]` (a `VNode`, `String`,
///     list, etc).
///   * `attr=${n}` passes `args[n]` through unchanged (great for event handlers
///     and object props like `style`).
///   * `<${n} .../>` renders a component: `args[n]` must be a
///     [FunctionComponent].
///   * `<>...</>` is a fragment.
///
/// Templates are parsed once and cached. The optional build_runner precompiler
/// (see `lib/builder.dart`) fills the same cache at build time — turning the
/// template directly into `h(...)` calls — so no parsing happens at runtime.
library;

import 'vdom.dart';

/// A compiled template: turns an args list into a [VNode].
typedef JsxBuilder = VNode Function(List<Object?> args);

final Map<String, JsxBuilder> _cache = {};

/// Registers a precompiled builder for [template]. Called by generated code
/// from the build_runner precompiler; you normally never call this yourself.
void registerCompiledTemplate(String template, JsxBuilder builder) {
  _cache[template] = builder;
}

/// Compiles [template] into a [VNode], interpolating [args].
VNode jsx(String template, [List<Object?> args = const []]) {
  final builder = _cache[template] ??= _compile(template);
  return builder(args);
}

JsxBuilder _compile(String template) {
  final nodes = parseTemplate(template);
  return (args) => buildTop(nodes, args);
}

/// Parses [template] into an AST. Public-but-internal: also used by the
/// build_runner precompiler.
List<TemplateNode> parseTemplate(String template) =>
    _Parser(template).parseChildren(topLevel: true);

/// Builds the top-level result: a single node when there is exactly one,
/// otherwise a fragment. Shared by the runtime and (indirectly, via the emitted
/// code shape) the precompiler.
VNode buildTop(List<TemplateNode> nodes, List<Object?> args) {
  final built = [for (final n in nodes) n.build(args)];
  if (built.length == 1 && built.first is VNode) return built.first as VNode;
  return FragmentNode(normalizeChildren(built));
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

sealed class TemplateNode {
  Object? build(List<Object?> args);
}

class TemplateText extends TemplateNode {
  final String text;
  TemplateText(this.text);
  @override
  Object? build(List<Object?> args) => text;
}

class TemplateSlot extends TemplateNode {
  final int index;
  TemplateSlot(this.index);
  @override
  Object? build(List<Object?> args) => args[index];
}

class TemplateElement extends TemplateNode {
  /// A tag `String`, an `int` slot resolving to a component, or `null` for a
  /// fragment.
  final Object? tagOrSlot;
  final List<TemplateAttr> attrs;
  final List<TemplateNode> children;
  TemplateElement(this.tagOrSlot, this.attrs, this.children);

  @override
  Object? build(List<Object?> args) {
    final builtChildren = [for (final c in children) c.build(args)];
    if (tagOrSlot == null) {
      return FragmentNode(normalizeChildren(builtChildren));
    }
    final props = <String, Object?>{
      for (final a in attrs) a.name: a.value.resolve(args),
    };
    final type = tagOrSlot is int
        ? args[tagOrSlot as int] as FunctionComponent
        : tagOrSlot as String;
    return h(type, props, builtChildren);
  }
}

class TemplateAttr {
  final String name;
  final AttrValue value;
  TemplateAttr(this.name, this.value);
}

/// An attribute value, kept structured so both the runtime and the precompiler
/// can interpret it.
sealed class AttrValue {
  Object? resolve(List<Object?> args);
}

class AttrStatic extends AttrValue {
  final Object value; // bool `true` or a `String`
  AttrStatic(this.value);
  @override
  Object? resolve(List<Object?> args) => value;
}

class AttrSlot extends AttrValue {
  final int index;
  AttrSlot(this.index);
  @override
  Object? resolve(List<Object?> args) => args[index];
}

class AttrConcat extends AttrValue {
  final List<Object> parts; // String literals and int slot indices
  AttrConcat(this.parts);
  @override
  Object? resolve(List<Object?> args) {
    final b = StringBuffer();
    for (final p in parts) {
      b.write(p is int ? args[p]?.toString() ?? '' : p);
    }
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class _Parser {
  final String src;
  int i = 0;
  _Parser(this.src);

  bool get _eof => i >= src.length;
  String get _c => src[i];

  Never _err(String msg) =>
      throw FormatException('jsx: $msg at offset $i in template:\n$src');

  List<TemplateNode> parseChildren({bool topLevel = false}) {
    final out = <TemplateNode>[];
    final text = StringBuffer();

    void flushText() {
      final normalized = _normalizeText(text.toString());
      if (normalized != null) out.add(TemplateText(normalized));
      text.clear();
    }

    while (!_eof) {
      if (_c == '<') {
        if (_startsWith('</')) {
          flushText();
          if (topLevel) _err('unexpected closing tag');
          return _trimEdges(out);
        }
        if (_startsWith('<!--')) {
          _skipComment();
          continue;
        }
        flushText();
        out.add(_parseElement());
      } else if (_isSlotStart()) {
        flushText();
        out.add(TemplateSlot(_parseSlot()));
      } else {
        text.write(_c);
        i++;
      }
    }
    flushText();
    return _trimEdges(out);
  }

  /// Drops whitespace-only text at the start/end of a child list, so template
  /// indentation around the outermost tags never leaks into output.
  static List<TemplateNode> _trimEdges(List<TemplateNode> nodes) {
    bool blank(TemplateNode n) => n is TemplateText && n.text.trim().isEmpty;
    while (nodes.isNotEmpty && blank(nodes.first)) {
      nodes.removeAt(0);
    }
    while (nodes.isNotEmpty && blank(nodes.last)) {
      nodes.removeLast();
    }
    return nodes;
  }

  TemplateElement _parseElement() {
    _expect('<');
    if (_c == '>') {
      i++;
      final children = parseChildren();
      _expect('<');
      _expect('/');
      _expect('>');
      return TemplateElement(null, const [], children);
    }

    Object tagOrSlot = _isSlotStart() ? _parseSlot() : _readName();

    final attrs = <TemplateAttr>[];
    while (true) {
      _skipWs();
      if (_eof) _err('unterminated tag');
      if (_c == '/') {
        i++;
        _expect('>');
        return TemplateElement(tagOrSlot, attrs, const []);
      }
      if (_c == '>') {
        i++;
        break;
      }
      attrs.add(_parseAttr());
    }

    final children = parseChildren();
    _expect('<');
    _expect('/');
    if (_isSlotStart()) {
      _parseSlot();
    } else {
      _readName();
    }
    _skipWs();
    _expect('>');
    return TemplateElement(tagOrSlot, attrs, children);
  }

  TemplateAttr _parseAttr() {
    final name = _readName();
    _skipWs();
    if (_eof || _c != '=') {
      return TemplateAttr(name, AttrStatic(true));
    }
    i++; // '='
    _skipWs();

    if (_isSlotStart()) {
      return TemplateAttr(name, AttrSlot(_parseSlot()));
    }
    if (_c == '"' || _c == "'") {
      return TemplateAttr(name, _valueFromParts(_parseQuoted(_c)));
    }

    final start = i;
    while (!_eof && _c != '>' && _c != '/' && !_isWs(_c)) {
      i++;
    }
    return TemplateAttr(name, AttrStatic(src.substring(start, i)));
  }

  List<Object> _parseQuoted(String quote) {
    i++; // opening quote
    final parts = <Object>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        parts.add(buf.toString());
        buf.clear();
      }
    }

    while (!_eof && _c != quote) {
      if (_isSlotStart()) {
        flush();
        parts.add(_parseSlot());
      } else {
        buf.write(_c);
        i++;
      }
    }
    if (_eof) _err('unterminated attribute value');
    i++; // closing quote
    flush();
    return parts;
  }

  AttrValue _valueFromParts(List<Object> parts) {
    if (parts.isEmpty) return AttrStatic('');
    if (parts.length == 1 && parts.first is int) {
      return AttrSlot(parts.first as int); // preserve value type
    }
    if (parts.every((p) => p is String)) {
      return AttrStatic(parts.join());
    }
    return AttrConcat(parts);
  }

  bool _isSlotStart() => _c == r'$' && i + 1 < src.length && src[i + 1] == '{';

  int _parseSlot() {
    i += 2; // '${'
    final start = i;
    while (!_eof && _c != '}') {
      i++;
    }
    if (_eof) _err('unterminated \${...} slot');
    final digits = src.substring(start, i).trim();
    i++; // '}'
    final n = int.tryParse(digits);
    if (n == null) _err('slot must be an integer index, got "$digits"');
    return n;
  }

  String _readName() {
    final start = i;
    while (!_eof && _isNameChar(_c)) {
      i++;
    }
    if (i == start) _err('expected a name');
    return src.substring(start, i);
  }

  void _skipComment() {
    final end = src.indexOf('-->', i);
    i = end < 0 ? src.length : end + 3;
  }

  void _skipWs() {
    while (!_eof && _isWs(_c)) {
      i++;
    }
  }

  bool _startsWith(String s) => src.startsWith(s, i);

  void _expect(String ch) {
    if (_eof || _c != ch) _err('expected "$ch"');
    i++;
  }

  static bool _isWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
  static bool _isNameChar(String c) => RegExp(r'[A-Za-z0-9_:.-]').hasMatch(c);
}

/// JSX-ish whitespace handling: drop pure structural (newline) whitespace,
/// collapse the rest, so template indentation doesn't leak into output. Returns
/// `null` when the run should be dropped entirely.
String? _normalizeText(String s) {
  if (s.isEmpty) return null;
  if (s.trim().isEmpty) {
    return s.contains('\n') ? null : ' ';
  }
  final leadingNewline = RegExp(r'^\s*\n').hasMatch(s);
  final trailingNewline = RegExp(r'\n\s*$').hasMatch(s);
  var out = s
      .replaceAll(RegExp(r'\s*\n\s*'), ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ');
  if (leadingNewline) out = out.replaceFirst(RegExp(r'^ '), '');
  if (trailingNewline) out = out.replaceFirst(RegExp(r' $'), '');
  return out;
}
