/// Emits Dart source from a [DartxElement] tree.
///
/// Everything funnels into `h(...)`, the same hyperscript primitive the rest of
/// the library is built on — so generated code has no privileged access to the
/// runtime and stays readable.
///
/// ## Line fidelity
///
/// The emitter keeps a cursor on the generated line number and, before each
/// child, pads with newlines until it reaches that child's line in the
/// `.dartx` source. An element therefore emits *exactly* as many newlines as it
/// spanned: markup is line-neutral, and every nested expression ends up on its
/// original line. Analyzer errors, stack traces and breakpoints all point where
/// you wrote the code.
library;

import 'ast.dart';
import 'diagnostics.dart';

/// Emits [element] as a Dart expression, aligning generated lines with
/// [lineMap]. Pass no [lineMap] to emit everything on one line.
String emitElement(DartxElement element, {LineMap? lineMap, String? scope}) =>
    DartxEmitter(lineMap, scope: scope).element(element);

/// Emits [node] as a Dart expression. See [emitElement].
String emitNode(DartxNode node, {LineMap? lineMap, String? scope}) =>
    DartxEmitter(lineMap, scope: scope).node(node);

class DartxEmitter {
  final LineMap? lineMap;

  /// When this file has a `@scoped` stylesheet, the attribute every host
  /// element it renders must carry for that stylesheet to reach it.
  final String? scope;

  /// The source line the output has reached so far.
  int _line = 0;

  DartxEmitter(this.lineMap, {this.scope});

  String node(DartxNode n) {
    if (lineMap != null && _line == 0) _line = lineMap!.lineAt(n.offset);
    return _node(n);
  }

  String element(DartxElement e) {
    if (lineMap != null && _line == 0) _line = lineMap!.lineAt(e.offset);
    return _element(e);
  }

  String _node(DartxNode n) => switch (n) {
        DartxText(text: final t) => stringLiteral(t),
        DartxExpression(code: final c) => _embedded(c),
        DartxElement e => _element(e),
      };

  String _element(DartxElement e) {
    // A component is a Dart constructor call with named arguments; a host
    // element is a tag string and a map. They are emitted separately because
    // they are genuinely different things, not two spellings of one.
    if (!e.isFragment && !e.isHostElement) return _component(e);

    final props = _props(e.attributes);
    final children = _children(e.children);
    // Close on the line the closing tag was on, so the element as a whole is
    // line-neutral and whatever follows it keeps its number.
    final tail = _padTo(e.end - 1);

    if (e.isFragment) {
      return 'FragmentNode(normalizeChildren($children$tail))';
    }
    // Host elements go through `h`, which takes a tag string and an untyped
    // attribute map — the right model for HTML, where the attribute set is the
    // spec's and not yours.
    return 'h(${stringLiteral(e.name!)}, $props, $children$tail)';
  }

  /// A component element: `<StatCard value={3}>…</StatCard>` becomes a call to
  /// its generated props type, `StatCardProps(value: 3, …)`.
  ///
  /// That constructor is ordinary Dart, so the analyzer checks every attribute
  /// name and value where you wrote it. A typo is a compile error naming the
  /// argument, not a `null` that surfaces three frames into a render.
  String _component(DartxElement e) {
    final buffer = StringBuffer('${_propsTypeOf(e.name!)}(');
    var first = true;

    for (final attribute in e.attributes) {
      if (attribute is DartxSpreadAttribute) {
        _err(
          'a spread cannot be used on a component: `${e.name}` takes named '
          'arguments, so pass them explicitly. Spreads still work on host '
          'elements, where attributes really are an open-ended map.',
          attribute.offset,
        );
      }
      final named = attribute as DartxNamedAttribute;
      if (!first) buffer.write(', ');
      first = false;
      buffer.write(_padTo(named.offset));
      buffer.write('${_argumentName(named, e.name!)}: ${_value(named.value)}');
    }

    if (e.children.isNotEmpty) {
      if (!first) buffer.write(', ');
      first = false;
      // `normalizeChildren` flattens and coerces, so `{todos.map(…)}` and a
      // bare string read the same here as they do under a host element.
      buffer.write('children: normalizeChildren(${_children(e.children)})');
    }

    return (buffer..write('${_padTo(e.end - 1)})')).toString();
  }

  /// The attribute's name as a Dart named argument.
  ///
  /// Markup keeps HTML's spelling — you write `class` and `aria-label` — and
  /// neither is a Dart identifier, so a small fixed mapping bridges them. It is
  /// deliberately short: anything outside it is a mistake worth a message
  /// rather than a guess.
  String _argumentName(DartxNamedAttribute attribute, String component) {
    final name = attribute.name;
    if (name == 'key') return 'key';

    final mapped = _reservedAttributes[name] ??
        (name.contains('-') ? _camelCase(name) : name);

    if (_dartReserved.contains(mapped)) {
      _err(
        '`$name` is a Dart keyword, so it cannot be a named argument on '
        '`$component`. Rename the attribute (reactx maps `class` to '
        '`className` and `for` to `htmlFor` for you).',
        attribute.offset,
      );
    }
    return mapped;
  }

  /// `StatCard` -> `StatCardProps`, `widgets.Card` -> `widgets.CardProps`.
  String _propsTypeOf(String component) {
    final dot = component.lastIndexOf('.');
    return dot < 0
        ? '${component}Props'
        : '${component.substring(0, dot + 1)}${component.substring(dot + 1)}'
            'Props';
  }

  Never _err(String message, int offset) {
    final map = lineMap;
    throw DartxError(
      message,
      offset: offset,
      line: map?.lineAt(offset) ?? 1,
      column: map?.columnAt(offset) ?? 1,
    );
  }

  String _children(List<DartxNode> children) {
    if (children.isEmpty) return 'const <Object?>[]';
    final buffer = StringBuffer('<Object?>[');
    for (var i = 0; i < children.length; i++) {
      if (i > 0) buffer.write(', ');
      buffer.write(_padTo(children[i].offset));
      buffer.write(_node(children[i]));
    }
    return (buffer..write(']')).toString();
  }

  String _props(List<DartxAttribute> attributes) {
    final mark = scope == null ? '' : "'data-rx-$scope': '', ";
    if (attributes.isEmpty) {
      return mark.isEmpty
          ? 'const <String, Object?>{}'
          : 'const <String, Object?>{${mark.trimRight().replaceAll(RegExp(r',\$'), '')}}';
    }
    final buffer = StringBuffer('<String, Object?>{$mark');
    for (var i = 0; i < attributes.length; i++) {
      if (i > 0) buffer.write(', ');
      final a = attributes[i];
      buffer.write(_padTo(a.offset));
      buffer.write(switch (a) {
        DartxSpreadAttribute(code: final c) => '...${_embedded(c)}',
        DartxNamedAttribute(name: final n, value: final v) =>
          '${stringLiteral(n)}: ${_value(v)}',
      });
    }
    return (buffer..write('}')).toString();
  }

  String _value(DartxAttributeValue value) => switch (value) {
        DartxFlagValue() => 'true',
        DartxStringValue(value: final v) => stringLiteral(v),
        DartxExpressionValue(code: final c) => _embedded(c),
      };

  /// Embedded Dart is copied through verbatim, so it carries its own newlines;
  /// advance the cursor past them.
  String _embedded(String code) {
    _line += _countNewlines(code);
    return wrapExpression(code);
  }

  /// Newlines needed to bring the output down to the line [offset] is on.
  String _padTo(int offset) {
    final map = lineMap;
    if (map == null) return '';
    final target = map.lineAt(offset);
    if (target <= _line) return '';
    final gap = target - _line;
    _line = target;
    return '\n' * gap;
  }

  static int _countNewlines(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == 0x0a) n++;
    }
    return n;
  }
}

/// HTML attribute names that are Dart keywords, and what a component parameter
/// calls them instead. Both spellings are the conventional ones.
const _reservedAttributes = {
  'class': 'className',
  'for': 'htmlFor',
};

/// Dart keywords that cannot be named arguments. Only the ones a person might
/// plausibly reach for as an attribute are listed; the analyzer catches the
/// rest with a message of its own.
const _dartReserved = {
  'class', 'for', 'in', 'is', 'if', 'else', 'switch', 'case', 'default', //
  'new', 'const', 'final', 'var', 'void', 'this', 'super', 'return', 'true',
  'false', 'null', 'with', 'while', 'do', 'try', 'catch', 'throw', 'extends',
  'enum', 'assert', 'break', 'continue', 'rethrow',
};

/// `aria-label` -> `ariaLabel`.
String _camelCase(String name) {
  final parts = name.split('-');
  final buffer = StringBuffer(parts.first);
  for (final part in parts.skip(1)) {
    if (part.isEmpty) continue;
    buffer
      ..write(part[0].toUpperCase())
      ..write(part.substring(1));
  }
  return buffer.toString();
}

final _simpleExpression =
    RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*$');

/// Parenthesises embedded Dart so operator precedence can never leak into the
/// surrounding call — except for plain identifiers and dotted paths, where the
/// parentheses would only add noise.
String wrapExpression(String code) {
  final trimmed = code.trim();
  if (trimmed.isEmpty) return 'null';
  if (_simpleExpression.hasMatch(trimmed)) return trimmed;
  // Keep the original spacing (and therefore the original newlines) but make
  // the grouping explicit.
  return '($code)';
}

/// Emits a single-quoted Dart string literal for [s]. Newlines are escaped, so
/// a literal never disturbs the emitter's line accounting.
String stringLiteral(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return "'$escaped'";
}
