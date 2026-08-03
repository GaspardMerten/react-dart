import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

/// Finds the first node with [tag] in a [TestHost] tree.
TestNode? find(TestNode n, String tag) {
  if (n.tag == tag) return n;
  for (final c in n.children) {
    final r = find(c, tag);
    if (r != null) return r;
  }
  return null;
}

String htmlOf(TestHost host) =>
    host.root.children.map((c) => c.toHtml()).join();

(Root, TestHost) mount(VNode node) {
  final host = TestHost();
  final root = createRoot(host, host.root);
  root.render(node);
  return (root, host);
}

void main() {
  group('mount + update', () {
    test('mounts a tree to the host', () {
      final (_, host) = mount(div({'class': 'a'}, [span(null, 'hi')]));
      expect(htmlOf(host), '<div class="a"><span>hi</span></div>');
    });

    test('updates text and attributes in place, reusing nodes', () {
      final (root, host) = mount(div({'class': 'a'}, 'one'));
      final divNode = find(host.root, 'div')!;
      root.render(div({'class': 'b'}, 'two'));
      expect(identical(find(host.root, 'div'), divNode), isTrue,
          reason: 'the div node is reused, not recreated');
      expect(htmlOf(host), '<div class="b">two</div>');
    });

    test('adds and removes children', () {
      final (root, host) = mount(ul(null, [li(null, 'a')]));
      root.render(ul(null, [li(null, 'a'), li(null, 'b')]));
      expect(htmlOf(host), '<ul><li>a</li><li>b</li></ul>');
      root.render(ul(null, <VNode>[]));
      expect(htmlOf(host), '<ul></ul>');
    });

    test('conditional rendering with && and fragments', () {
      VNode view(bool show) => div(null, [
            span(null, 'always'),
            show ? strong(null, 'sometimes') : null,
          ]);
      final (root, host) = mount(view(true));
      expect(htmlOf(host),
          '<div><span>always</span><strong>sometimes</strong></div>');
      root.render(view(false));
      expect(htmlOf(host), '<div><span>always</span></div>');
    });
  });

  group('keyed reconciliation', () {
    test('reorders by key, preserving node identity', () {
      VNode list(List<String> keys) =>
          ul(null, [for (final k in keys) li({'key': k}, k)]);

      final (root, host) = mount(list(['a', 'b', 'c']));
      final ulNode = find(host.root, 'ul')!;
      final nodeA = ulNode.children[0];
      final nodeC = ulNode.children[2];

      root.render(list(['c', 'a', 'b']));

      expect(ulNode.children.map((n) => n.children.single.text).toList(),
          ['c', 'a', 'b']);
      expect(identical(ulNode.children[0], nodeC), isTrue);
      expect(identical(ulNode.children[1], nodeA), isTrue);
    });

    test('does not move nodes that are already in position', () {
      VNode view(String label) => div(null, [
            span({'key': 'a'}, 'stable'),
            span({'key': 'b'}, label),
          ]);
      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(view('x'));

      final before = host.insertBeforeCount;
      root.render(view('y')); // only 'b' text changes; order unchanged
      expect(host.insertBeforeCount - before, 0,
          reason: 'stable, correctly-ordered nodes must not be re-inserted');
      expect(htmlOf(host), '<div><span>stable</span><span>y</span></div>');
    });

    test('removes a keyed item from the middle', () {
      VNode list(List<String> keys) =>
          ul(null, [for (final k in keys) li({'key': k}, k)]);
      final (root, host) = mount(list(['a', 'b', 'c']));
      root.render(list(['a', 'c']));
      expect(htmlOf(host), '<ul><li>a</li><li>c</li></ul>');
    });
  });

  group('hooks', () {
    test('useState re-renders on set', () {
      VNode counter(Props props) {
        final (count, setCount) = useState(0);
        return div(null, [
          span(null, '$count'),
          button({'onClick': () => setCount((c) => c + 1)}, '+'),
        ]);
      }

      final (root, host) = mount(h(counter));
      expect(find(host.root, 'span')!.children.single.text, '0');

      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(find(host.root, 'span')!.children.single.text, '1');

      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(find(host.root, 'span')!.children.single.text, '2');
    });

    test('useReducer dispatches actions', () {
      int reducer(int state, String action) =>
          switch (action) { 'inc' => state + 1, 'dec' => state - 1, _ => state };

      VNode counter(Props props) {
        final (count, dispatch) = useReducer(reducer, 10);
        return button({'onClick': () => dispatch('inc')}, '$count');
      }

      final (root, host) = mount(h(counter));
      expect(find(host.root, 'button')!.children.single.text, '10');
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(find(host.root, 'button')!.children.single.text, '11');
    });

    test('useEffect runs after commit, re-runs on dep change, cleans up', () {
      final log = <String>[];

      VNode comp(Props props) {
        final (n, setN) = useState(0);
        useEffect(() {
          log.add('run $n');
          return () => log.add('cleanup $n');
        }, [n]);
        return button({'onClick': () => setN((v) => v + 1)}, '$n');
      }

      final (root, host) = mount(h(comp));
      expect(log, ['run 0']);

      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(log, ['run 0', 'cleanup 0', 'run 1']);

      root.unmount();
      expect(log, ['run 0', 'cleanup 0', 'run 1', 'cleanup 1']);
    });

    test('useEffect with [] deps runs once', () {
      final log = <String>[];
      VNode comp(Props props) {
        final (n, setN) = useState(0);
        useEffect(() => log.add('mount'), const []);
        return button({'onClick': () => setN((v) => v + 1)}, '$n');
      }

      final (root, host) = mount(h(comp));
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(log, ['mount']);
    });

    test('a setState inside an effect is flushed synchronously by act', () {
      VNode comp(Props props) {
        final (ready, setReady) = useState(false);
        useEffect(() {
          if (!ready) setReady((_) => true);
        }, [ready]);
        return span(null, ready ? 'ready' : 'loading');
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(h(comp));
      // Initial render queues the effect, which flips state, which re-renders.
      // All of it settles before render() returns.
      expect(find(host.root, 'span')!.children.single.text, 'ready');
    });

    test('effect returning a non-cleanup value is ignored, not crashed on', () {
      VNode comp(Props props) {
        useEffect(() => 42, const []); // returns a value, not a cleanup
        return span(null, 'x');
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(h(comp));
      expect(() => root.unmount(), returnsNormally);
    });

    test('object ref is attached to the host node', () {
      final ref = Ref<Object?>(null);
      mount(div({'ref': ref}));
      expect(ref.current, isA<TestNode>());
      expect((ref.current as TestNode).tag, 'div');
    });

    test('useRef persists a mutable value across renders', () {
      final renders = <int>[];
      VNode comp(Props props) {
        final (_, setN) = useState(0);
        final count = useRef(0);
        count.current++;
        renders.add(count.current);
        return button({'onClick': () => setN((v) => v + 1)}, 'x');
      }

      final (root, host) = mount(h(comp));
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(renders, [1, 2, 3]);
    });

    test('useContext updates when provider value changes', () {
      final theme = createContext('light');
      VNode consumer(Props props) => span(null, useContext(theme));

      VNode app(Props props) {
        final (t, setT) = useState('light');
        return div(null, [
          theme.provider(value: t, children: [h(consumer)]),
          button({'onClick': () => setT((_) => 'dark')}, 'toggle'),
        ]);
      }

      final (root, host) = mount(h(app));
      expect(find(host.root, 'span')!.children.single.text, 'light');
      root.act(() => find(host.root, 'button')!.dispatch('click'));
      expect(find(host.root, 'span')!.children.single.text, 'dark');
    });
  });
}
