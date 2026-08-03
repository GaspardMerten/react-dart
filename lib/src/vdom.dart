/// The virtual DOM: the immutable description of a UI that components return.
///
/// A [VNode] is a lightweight, plain-data value. It is *not* a DOM node; it is
/// a blueprint the reconciler (client) or the string renderer (server) turns
/// into output. This mirrors a React "element".
library;

import 'context.dart';

/// A bag of properties passed to an element or component.
///
/// For host elements these become attributes / event listeners. For components
/// they are the arguments. Children are passed separately (see [VNode]
/// subclasses) but are also exposed to components as `props['children']`.
typedef Props = Map<String, Object?>;

/// A function component: takes [Props] and returns a [VNode].
///
/// Children are available via `props['children']` (a `List<VNode>`).
typedef FunctionComponent = VNode Function(Props props);

/// Base type for everything in the virtual DOM tree.
sealed class VNode {
  /// Optional stable identity used by the reconciler to match nodes across
  /// renders (React's `key`). Critical for correct list diffing.
  final Object? key;

  const VNode({this.key});
}

/// A run of text.
final class TextNode extends VNode {
  final String text;
  const TextNode(this.text);
}

/// A host element such as `<div>` or `<button>`.
final class ElementNode extends VNode {
  final String tag;
  final Props props;
  final List<VNode> children;

  const ElementNode(this.tag, this.props, this.children, {super.key});
}

/// An instance of a [FunctionComponent].
final class ComponentNode extends VNode {
  final FunctionComponent component;
  final Props props;
  final List<VNode> children;

  /// Human-readable name, used for SSR debug markers and error messages.
  final String name;

  const ComponentNode(
    this.component,
    this.props,
    this.children, {
    this.name = 'Component',
    super.key,
  });
}

/// A group of children with no wrapping host element (React's `<>...</>`).
final class FragmentNode extends VNode {
  final List<VNode> children;
  const FragmentNode(this.children, {super.key});
}

/// Provides a [Context] value to the subtree (React's `Context.Provider`).
final class ProviderNode extends VNode {
  final Context<Object?> context;
  final Object? value;
  final List<VNode> children;

  const ProviderNode(this.context, this.value, this.children, {super.key});
}

/// The empty node, rendered as nothing. Handy for conditional rendering.
const VNode nothing = FragmentNode(<VNode>[]);

/// Hyperscript: the single primitive every other builder is sugar over.
///
/// * [type] is a tag `String` (host element) or a [FunctionComponent].
/// * [propsOrChildren] is either a `Props` map or the children (when you have
///   no props). A `'key'` entry in the props map is lifted to [VNode.key].
/// * [childrenArg] is the children when the second argument was the props map.
///
/// Children may be a `VNode`, a `String`/`num` (becomes text), an `Iterable`
/// (flattened), or `null`/`bool` (ignored) — see [normalizeChildren].
VNode h(Object type, [Object? propsOrChildren, Object? childrenArg]) {
  Props props;
  Object? children;
  if (propsOrChildren is Map) {
    props = Map<String, Object?>.from(propsOrChildren);
    children = childrenArg;
  } else {
    props = <String, Object?>{};
    children = propsOrChildren ?? childrenArg;
  }

  final key = props.remove('key');
  final childList = normalizeChildren(children ?? props.remove('children'));

  if (type is String) {
    return ElementNode(type, props, childList, key: key);
  }
  if (type is FunctionComponent) {
    // Expose children the React way as well as positionally.
    props['children'] = childList;
    return ComponentNode(type, props, childList, name: _fnName(type), key: key);
  }
  throw ArgumentError.value(
    type,
    'type',
    'must be a tag String or a FunctionComponent',
  );
}

/// Builds a [ComponentNode] for [component]. Equivalent to `h(component, ...)`
/// but reads better at call sites: `use(App, {'title': 'Hi'})`.
VNode use(FunctionComponent component, [Props? props, Object? children]) =>
    h(component, props ?? const <String, Object?>{}, children);

/// A fragment groups children without adding a wrapper element.
VNode fragment(Object? children, {Object? key}) =>
    FragmentNode(normalizeChildren(children), key: key);

/// A raw text node. Text passed as children is auto-wrapped, so you rarely
/// need this directly.
VNode text(Object? value) => TextNode(value?.toString() ?? '');

/// Flattens and coerces an arbitrary children value into a `List<VNode>`.
///
/// * `null`, `true`, `false` -> dropped (enables `cond && child`).
/// * `String` / `num` -> [TextNode].
/// * `VNode` -> kept.
/// * `Iterable` -> flattened recursively.
List<VNode> normalizeChildren(Object? children) {
  final out = <VNode>[];
  _collect(children, out);
  return out;
}

void _collect(Object? child, List<VNode> out) {
  if (child == null || child is bool) return;
  if (child is VNode) {
    out.add(child);
  } else if (child is String) {
    if (child.isNotEmpty) out.add(TextNode(child));
  } else if (child is num) {
    out.add(TextNode(child.toString()));
  } else if (child is Iterable) {
    for (final c in child) {
      _collect(c, out);
    }
  } else {
    out.add(TextNode(child.toString()));
  }
}

String _fnName(FunctionComponent fn) {
  // Dart has no reliable way to read a closure's name; fall back to a label
  // derived from runtimeType, which for top-level tear-offs is informative
  // enough for debug markers.
  final rt = fn.runtimeType.toString();
  return rt;
}
