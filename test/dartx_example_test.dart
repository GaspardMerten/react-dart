/// End-to-end check that dartx-generated code really is a working component
/// tree: the transpiler's own tests assert on emitted source, but this one
/// imports what the builder produced from `example/app.dartx` and runs it.
library;

import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

import '../example/app.dartx.dart';

/// Depth-first search for the first node with tag [tag].
TestNode? find(TestNode node, String tag) {
  if (node.tag == tag) return node;
  for (final child in node.children) {
    final hit = find(child, tag);
    if (hit != null) return hit;
  }
  return null;
}

Iterable<TestNode> findAll(TestNode node, String tag) sync* {
  if (node.tag == tag) yield node;
  for (final child in node.children) {
    yield* findAll(child, tag);
  }
}

String textOf(TestNode node) => node.children
    .map((c) => c.text ?? textOf(c))
    .join();

void main() {
  group('the dartx example', () {
    test('server-renders the whole tree', () {
      final html = renderToString(const AppProps());
      expect(html, contains('<div class="app">'));
      expect(html, contains('<h1>reactx demo</h1>'));
      expect(html, contains('<section class="counter">'));
      expect(html, contains('<p>Value: <strong>0</strong></p>'));
      // The keyed collection-for inside `<ul>`.
      expect(html, contains('<li>Learn reactx</li>'));
      // Attributes from an expression, and a self-closing void element.
      expect(html, contains('placeholder="Add a todo"'));
    });

    test('a component tag renders the component, not a literal tag', () {
      // `<Counter />` must not end up as `<Counter>` in the HTML.
      expect(renderToString(const AppProps()), isNot(contains('<Counter')));
    });

    test('handlers written as attributes are live after mounting', () {
      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(const CounterProps());

      final increment = findAll(host.root, 'button')
          .firstWhere((b) => textOf(b) == '+');
      root.act(() => increment.dispatch('click'));

      expect(textOf(find(host.root, 'strong')!), '1');
      root.unmount();
    });

    test('the keyed list grows when state changes', () {
      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(const TodosProps());

      expect(findAll(host.root, 'li').length, 1);
      root.unmount();
    });
  });
}
