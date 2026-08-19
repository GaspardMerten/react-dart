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

  group('when the markup does not match the tree', () {
    TestNode el(String tag, [String? text]) {
      final n = TestNode.element(tag);
      if (text != null) n.children.add(TestNode.text(text));
      return n;
    }

    TestHost serverRendered(List<TestNode> children) {
      final host = TestHost();
      for (final c in children) {
        host.insertBefore(host.root, c, null);
      }
      return host;
    }

    test("a replacement node takes the rejected one's place, not the end", () {
      // Server said <span>x</span><b>y</b>; the tree wants <i>1</i><b>y</b>.
      final host = serverRendered([el('span', 'x'), el('b', 'y')]);
      createRoot(host, host.root)
          .hydrate(FragmentNode([h('i', null, '1'), h('b', null, 'y')]));

      expect(host.root.children.map((c) => c.tag), ['i', 'b'],
          reason: 'appending it would leave the DOM and the fibers disagreeing '
              'about order, and every later update diffs against that');
    });

    test('server nodes the tree never claimed are removed', () {
      final host =
          serverRendered([el('li', 'a'), el('li', 'b'), el('li', 'c')]);
      createRoot(host, host.root).hydrate(FragmentNode([h('li', null, 'a')]));

      expect(host.root.children.length, 1);
    });

    test('nested leftovers are removed too', () {
      final ul = TestNode.element('ul')
        ..children.addAll([el('li', 'a'), el('li', 'b')]);
      final host = serverRendered([ul]);
      createRoot(host, host.root).hydrate(h('ul', null, [h('li', null, 'a')]));

      expect(host.root.children.single.children.length, 1);
    });

    test('an attribute the server set and the tree dropped is removed', () {
      final server = TestNode.element('div');
      server.attributes['class'] = 'a';
      server.attributes['data-server-only'] = '1';

      final host = serverRendered([server]);
      createRoot(host, host.root).hydrate(h('div', {'class': 'a'}, []));

      expect(host.root.children.single.attributes, {'class': 'a'});
    });

    test('a matching tree still adopts everything untouched', () {
      final host = serverRendered([el('p', 'same')]);
      final before = host.root.children.single;
      final inserts = host.insertBeforeCount;

      createRoot(host, host.root).hydrate(h('p', null, 'same'));

      expect(identical(host.root.children.single, before), isTrue);
      expect(host.insertBeforeCount, inserts,
          reason: 'nothing was created or moved');
    });
  });
}

String htmlRoot(TestHost host) =>
    host.root.children.map((c) => c.toHtml()).join();

VNode button2(int count, StateSetter<int> setCount) => button(
      {'onClick': () => setCount((c) => c + 1)},
      '$count',
    );
