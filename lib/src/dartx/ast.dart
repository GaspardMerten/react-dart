/// The dartx markup AST.
///
/// The transpiler produces this from a `<...>` region inside a `.dartx` file,
/// and the emitter turns it back into Dart `h(...)` calls. Embedded Dart
/// (`{ ... }`) is kept as **already-transpiled source text**, because nested
/// markup inside an expression is handled by recursing through the transpiler
/// before the node is built.
library;

/// Anything that can appear as a child of an element.
sealed class DartxNode {
  /// Offset of the node's first character in the original source.
  final int offset;
  const DartxNode(this.offset);
}

/// A run of literal text between tags, already whitespace-normalized with JSX
/// rules and HTML-entity decoded.
final class DartxText extends DartxNode {
  final String text;
  const DartxText(this.text, int offset) : super(offset);
}

/// `{ dartExpression }` used as a child.
final class DartxExpression extends DartxNode {
  /// Transpiled Dart source of the expression (without the braces).
  final String code;
  const DartxExpression(this.code, int offset) : super(offset);
}

/// An element (`<div>`), a component (`<Counter>`), or a fragment (`<>`).
final class DartxElement extends DartxNode {
  /// `null` for a fragment.
  final String? name;
  final List<DartxAttribute> attributes;
  final List<DartxNode> children;

  /// Offset just past the element's closing `>`.
  final int end;

  const DartxElement({
    required this.name,
    required this.attributes,
    required this.children,
    required int offset,
    required this.end,
  }) : super(offset);

  bool get isFragment => name == null;

  /// Lowercase, dot-free names are host elements (`div`, `my-widget`);
  /// everything else is a Dart expression naming a component (`Counter`,
  /// `widgets.Card`).
  bool get isHostElement {
    final n = name;
    if (n == null) return false;
    if (n.contains('.')) return false;
    final first = n.codeUnitAt(0);
    return first >= 0x61 && first <= 0x7a; // a-z
  }
}

/// Either a named attribute or a `{...spread}`.
sealed class DartxAttribute {
  final int offset;
  const DartxAttribute(this.offset);
}

/// `name`, `name="literal"` or `name={expression}`.
final class DartxNamedAttribute extends DartxAttribute {
  final String name;
  final DartxAttributeValue value;
  const DartxNamedAttribute(this.name, this.value, int offset) : super(offset);
}

/// `{...expression}` — merged into the props map.
final class DartxSpreadAttribute extends DartxAttribute {
  /// Transpiled Dart source of the spread expression.
  final String code;
  const DartxSpreadAttribute(this.code, int offset) : super(offset);
}

sealed class DartxAttributeValue {
  const DartxAttributeValue();
}

/// A bare attribute — `disabled` — meaning `true`.
final class DartxFlagValue extends DartxAttributeValue {
  const DartxFlagValue();
}

/// A quoted literal — `class="card"`. Not interpolated (JSX semantics); use
/// `class={'card $modifier'}` for that.
final class DartxStringValue extends DartxAttributeValue {
  final String value;
  const DartxStringValue(this.value);
}

/// `onClick={handler}` — passed through as a Dart expression.
final class DartxExpressionValue extends DartxAttributeValue {
  /// Transpiled Dart source of the expression (without the braces).
  final String code;
  const DartxExpressionValue(this.code);
}
