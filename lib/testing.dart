/// Query helpers for driving a tree through [TestHost], without a browser.
///
/// Depends on nothing but reactx itself — no `package:test` — so it works from
/// any test runner, and failures throw a [StateError] that says what was
/// actually there rather than `Null check operator used on a null value`.
///
/// ```dart
/// final app = mountApp(App);
/// app.tree.byClass('nav-link').click();
/// expect(app.tree.byTag('h1').text, 'Stats');
/// ```
library;

import 'src/host.dart';
import 'src/reconciler.dart';
import 'src/vdom.dart';

/// A mounted tree plus the pieces needed to drive it.
class TestApp {
  TestApp(this.host, this.root);

  final TestHost host;
  final Root root;

  /// The container node. Query from here.
  TestNode get tree => host.root;

  /// Runs [body] and flushes every resulting render and effect synchronously.
  void act(void Function() body) => root.act(body);

  /// The current markup, for snapshot-style assertions.
  String get html => tree.children.map((c) => c.toHtml()).join();
}

/// Mounts [app] (a [VNode] or a [FunctionComponent]) into a fresh [TestHost].
///
/// Each call gets its own [Root], so store state never leaks between tests.
TestApp mountApp(Object app) {
  final host = TestHost();
  final root = createRoot(host, host.root);
  root.render(asVNode(app));
  return TestApp(host, root);
}

/// Finding things in a rendered tree.
extension TestNodeQuery on TestNode {
  /// This node and everything under it, in document order.
  Iterable<TestNode> get descendants sync* {
    yield this;
    for (final child in children) {
      yield* child.descendants;
    }
  }

  /// Whether `class` contains [name] as a whole word.
  bool hasClass(String name) =>
      '${attributes['class'] ?? ''}'.split(' ').contains(name);

  /// Every descendant matching [test].
  List<TestNode> all(bool Function(TestNode node) test) =>
      descendants.where(test).toList();

  /// The first descendant matching [test], or `null`.
  TestNode? maybe(bool Function(TestNode node) test) {
    for (final node in descendants) {
      if (test(node)) return node;
    }
    return null;
  }

  /// The first descendant matching [test]. Throws when there is none.
  TestNode one(bool Function(TestNode node) test, String description) =>
      maybe(test) ??
      (throw StateError('reactx.testing: no $description in:\n${toHtml()}'));

  List<TestNode> allByClass(String name) => all((n) => n.hasClass(name));

  TestNode byClass(String name) =>
      one((n) => n.hasClass(name), 'element with class "$name"');

  TestNode? maybeByClass(String name) => maybe((n) => n.hasClass(name));

  List<TestNode> allByTag(String tag) => all((n) => n.tag == tag);

  TestNode byTag(String tag) => one((n) => n.tag == tag, '<$tag>');

  TestNode? maybeByTag(String tag) => maybe((n) => n.tag == tag);

  /// The first element whose whole text is exactly [value].
  TestNode byText(String value) => one(
        (n) => n.tag != null && n.textContent == value,
        'element with the text "$value"',
      );

  /// The first element whose [name] attribute equals [value].
  TestNode byAttr(String name, String value) => one(
        (n) => '${n.attributes[name]}' == value,
        'element with $name="$value"',
      );

  /// All the text inside this node, elements included.
  ///
  /// Named after the DOM property rather than `text`, which on [TestNode] is
  /// the raw content of a text node and nothing else.
  String get textContent =>
      children.map((c) => c.text ?? c.textContent).join();

  /// Fires a `click` at this node.
  void click() => dispatch('click');

  /// Fires a `change` at this node — checkboxes, radios, `<select>`.
  void change() => dispatch('change');

  /// Fires an `input` at this node.
  void input() => dispatch('input');

  /// Fires a `submit` at this node.
  void submit() => dispatch('submit');
}
