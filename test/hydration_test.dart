import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

TestNode? find(TestNode n, String tag) {
  if (n.tag == tag) return n;
  for (final c in n.children) {
    final r = find(c, tag);
    if (r != null) return r;
  }
  return null;
}

void main() {
  group('hydration', () {
    test('adopts existing nodes instead of recreating them', () {
      // Simulate server-rendered markup: <button>0</button>.
      final host = TestHost();
      final button = TestNode.element('button');
      host.insertBefore(host.root, button, null);
      host.insertBefore(button, TestNode.text('0'), null);

      final existingButton = host.root.children.single;

      VNode counter(Props props) {
        final (count, setCount) = useState(0);
        return button2(count, setCount);
      }

      final root = createRoot(host, host.root);
      root.hydrate(h(counter));

      // Same physical node was adopted, not replaced.
      expect(host.root.children.length, 1);
      expect(identical(host.root.children.single, existingButton), isTrue);

      // The server markup matches and a listener is now attached.
      expect(existingButton.listeners.containsKey('click'), isTrue);
      expect(existingButton.children.single.text, '0');

      // And it is interactive.
      root.act(() => existingButton.dispatch('click'));
      expect(existingButton.children.single.text, '1');
    });

    test('server render + hydrate round-trips the same html', () {
      VNode app(Props props) => div({'class': 'app'}, [
            h1(null, 'Count'),
            span(null, 'static'),
          ]);

      final serverHtml = renderToString(h(app));
      expect(serverHtml, '<div class="app"><h1>Count</h1><span>static</span></div>');

      // Rebuild that markup as a host tree and hydrate it.
      final host = TestHost();
      final divNode = TestNode.element('div')..attributes['class'] = 'app';
      host.insertBefore(host.root, divNode, null);
      final h1Node = TestNode.element('h1')
        ..children.add(TestNode.text('Count'));
      final spanNode = TestNode.element('span')
        ..children.add(TestNode.text('static'));
      for (final n in [h1Node, spanNode]) {
        host.insertBefore(divNode, n, null);
      }

      final root = createRoot(host, host.root);
      root.hydrate(h(app));

      expect(identical(find(host.root, 'div'), divNode), isTrue);
      expect(identical(find(host.root, 'h1'), h1Node), isTrue);
      expect(htmlRoot(host), serverHtml);
    });
  });
}

String htmlRoot(TestHost host) =>
    host.root.children.map((c) => c.toHtml()).join();

VNode button2(int count, StateSetter<int> setCount) => button(
      {'onClick': () => setCount((c) => c + 1)},
      '$count',
    );
