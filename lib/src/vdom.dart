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

/// A component invocation with typed arguments — what `<StatCard value={3} />`
/// compiles to.
///
/// One of these is generated per [Component] function, from its parameter
/// list, and it is a [VNode] in its own right: constructing it *is* writing the
/// element. There is no props map anywhere in the path, so a misspelled
/// attribute or a `String` where an `int` belongs is a compile error at the
/// call site rather than a `null` at render time.
///
/// ```dart
/// Component StatCard({required int value, required String label}) => …;
///
/// // generated beside it:
/// final class StatCardProps extends ComponentProps {
///   const StatCardProps({required this.value, required this.label, super.key});
///   final int value;
///   final String label;
///   @override String get name => 'StatCard';
///   @override VNode build() => StatCard(value: value, label: label);
///   @override List<Object?> get fields => [value, label];
/// }
/// ```
///
/// Hand-writing one is fine too — the framework's own components do, because
/// consumers do not run builders over reactx's `lib/`.
abstract class ComponentProps extends VNode {
  const ComponentProps({super.key});

  /// Calls the component with these arguments. The reconciler runs this with
  /// the fiber current, so hooks inside behave exactly as they do for a
  /// map-based component.
  VNode build();

  /// The component's name, for error messages and tree paths.
  ///
  /// Unlike a closure's `runtimeType`, this survives obfuscation and hot
  /// reload, so diagnostics keep naming the component you wrote.
  String get name;

  /// The argument values, in declaration order, for [memoized] comparison.
  /// [key] is deliberately not among them: it identifies the element rather
  /// than describing it.
  List<Object?> get fields => const [];

  /// Whether the reconciler may skip re-rendering when [fields] are unchanged
  /// — the `@memoized` marker.
  ///
  /// Off by default, and worth turning on only for leaves with plain-value
  /// arguments: markup children are rebuilt every render, so a component that
  /// takes children rarely bails out.
  bool get memoized => false;
}

/// The return type that declares a function to be a component.
///
/// It is [VNode] — a component still returns a tree, and the body is checked
/// exactly as it would be otherwise. What the name adds is a marker the builder
/// can see: every capitalised function returning `Component` gets a props type
/// generated from its parameter list, and that is what its markup call sites
/// construct.
///
/// ```dart
/// Component Badge({required int count, String label = ''}) => …;
/// // <Badge count={3} />  ->  BadgeProps(count: 3)
/// ```
///
/// Writing it in the signature rather than in an annotation means the marker
/// cannot be forgotten separately from the thing it marks — and it tells the
/// two forms apart on sight: a `Component` function takes typed arguments, a
/// `VNode Function(Props)` reads an untyped map.
///
/// The parameters must be named — they are the attributes, and a positional
/// parameter has no attribute name to answer to. `key` is understood without
/// declaring it, and a `List<VNode> children` parameter receives the element's
/// children.
typedef Component = VNode;

/// Opts a component into the props bailout: the reconciler skips its re-render
/// when every argument compares equal.
///
/// ```dart
/// @memoized
/// Component Row({required Todo todo}) => …;
/// ```
///
/// Worth it for leaves with plain-value arguments. Markup children are rebuilt
/// on every render, so a component that takes children rarely bails out.
class Memoized {
  const Memoized();
}

/// See [Memoized].
const memoized = Memoized();

/// Compares two components' [ComponentProps.fields] one level deep, with the
/// same list handling as [propsShallowEqual].
bool fieldsEqual(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (identical(x, y)) continue;
    if (x is List && y is List) {
      if (x.length != y.length) return false;
      for (var j = 0; j < x.length; j++) {
        if (!identical(x[j], y[j])) return false;
      }
      continue;
    }
    if (x != y) return false;
  }
  return true;
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

/// Coerces the thing an entrypoint was handed into a [VNode].
///
/// [app] may be a [VNode] (`use(App, {'title': 'Hi'})`) or a
/// [FunctionComponent] (`App`), so `runApp(App)` and `renderToString(App)` read
/// the way you'd expect while passing props stays available.
VNode asVNode(Object app) {
  if (app is VNode) return app;
  if (app is FunctionComponent) return use(app);
  throw ArgumentError.value(
    app,
    'app',
    'must be a VNode or a FunctionComponent (VNode Function(Props))',
  );
}

/// Component equality functions registered by [memo], keyed by the wrapper the
/// call returned. Populated once per [memo] call, at declaration time.
final Map<Object, bool Function(Props, Props)> _memoEquality = {};

/// Wraps [component] so the reconciler can skip re-rendering it when its props
/// have not changed — the props-based counterpart to the identity bailout you
/// get for free by hoisting a [VNode].
///
/// ```dart
/// final Row = memo(_Row);        // declare once, at the top level
/// ```
///
/// [areEqual] defaults to [propsShallowEqual]. Note that markup children are
/// rebuilt on every render, so a memoized component that takes children rarely
/// bails out — memo pays off on leaves with plain-value props.
FunctionComponent memo(
  FunctionComponent component, {
  bool Function(Props previous, Props next)? areEqual,
}) {
  VNode memoized(Props props) => component(props);
  _memoEquality[memoized] = areEqual ?? propsShallowEqual;
  return memoized;
}

/// The equality function [memo] registered for [component], or `null` when it
/// was not memoized. Used by the reconciler.
bool Function(Props, Props)? memoEqualityOf(FunctionComponent component) =>
    _memoEquality[component];

/// Compares two prop maps one key deep.
///
/// Lists (children, and anything else you pass) are compared element by element
/// with `identical`, so a rebuilt list of the same nodes still counts as equal.
bool propsShallowEqual(Props a, Props b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    final x = entry.value;
    final y = b[entry.key];
    if (identical(x, y)) continue;
    if (x is List && y is List) {
      if (x.length != y.length) return false;
      for (var i = 0; i < x.length; i++) {
        if (!identical(x[i], y[i])) return false;
      }
      continue;
    }
    if (x != y) return false;
  }
  return true;
}

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
