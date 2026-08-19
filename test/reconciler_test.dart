import 'package:reactx/reactx.dart';
import 'package:reactx/testing.dart';
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

  // -------------------------------------------------------------------------
  group('reassemble', () {
    // What a hot reload calls. The contract is Flutter's: re-run every mounted
    // component against the new code, keep every fiber, restart nothing.
    test('re-runs every component without unmounting anything', () {
      var renders = 0;
      VNode leaf(Props props) {
        renders++;
        final (n, setN) = useState(0);
        return h('button', {'onClick': (Object _) => setN(n + 1)}, '$n');
      }

      VNode app(Props props) => h('div', null, [use(leaf)]);

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      expect(renders, 1);

      root.act(() => host.root.byTag('button').click());
      expect(host.root.byTag('button').textContent, '1');
      expect(renders, 2);

      root.reassemble();

      // Ran again with new code...
      expect(renders, 3);
      // ...and kept the state it had, because the fiber was never replaced.
      expect(host.root.byTag('button').textContent, '1');
    });

    test('effects with stable deps are not re-run', () {
      var effects = 0;
      VNode leaf(Props props) {
        useEffect(() {
          effects++;
          return null;
        }, const []);
        return h('p', null, 'x');
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(leaf));
      expect(effects, 1);

      root.reassemble();
      expect(effects, 1, reason: 'a reassemble is a re-render, not a remount');
    });

    test('is a no-op before anything is mounted', () {
      final host = TestHost();
      expect(createRoot(host, host.root).reassemble, returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  group('sibling keys', () {
    test('two children with the same key do not adopt one fiber', () {
      // Duplicate keys are a mistake and are warned about, but the reconciler
      // must not corrupt itself over them: pairing both children with the same
      // fiber renders only the last, then unmounts it twice on the next pass.
      final host = TestHost();
      final root = createRoot(host, host.root)
        ..render(h('ul', null, [
          h('li', {'key': 'a'}, '1'),
          h('li', {'key': 'a'}, '2'),
        ]));

      expect(host.root.byTag('ul').children.length, 2);
      expect(host.root.byTag('ul').children.map((c) => c.textContent),
          ['1', '2']);

      var cleanups = 0;
      VNode row(Props props) {
        useEffect(() => () => cleanups++, const []);
        return h('li', null, '${props['n']}');
      }

      final host2 = TestHost();
      final root2 = createRoot(host2, host2.root)
        ..render(h('ul', null, [
          use(row, {'key': 'a', 'n': 1}),
          use(row, {'key': 'a', 'n': 2}),
        ]));

      root2.act(() => root2.render(h('ul', null, const [])));
      expect(cleanups, 2,
          reason: 'each fiber cleans up exactly once, not one of them twice');
      root.unmount();
    });
  });

  // -------------------------------------------------------------------------
  group('unmount', () {
    test('store state does not survive into the next render', () {
      final counter = defineStore<int, int>(0, (s, a) => s + a);

      VNode app(Props props) {
        final (n, dispatch) = useStore(counter);
        return h('button', {'onClick': (Object _) => dispatch(1)}, '$n');
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      root.act(() => host.root.byTag('button').click());
      expect(host.root.byTag('button').textContent, '1');

      root.unmount();
      root.render(use(app));
      expect(host.root.byTag('button').textContent, '0',
          reason: 'state belongs to the root, so unmounting it takes the '
              'state with it');
    });
  });

  // -------------------------------------------------------------------------
  group('useReducer', () {
    test('reads the current reducer, not the one from the first render', () {
      VNode app(Props props) {
        final (step, setStep) = useState(1);
        // Closes over `step`, so it is a different function every render.
        final (total, add) = useReducer<int, void>((s, _) => s + step, 0);
        return h('div', null, [
          h('button', {'class': 'add', 'onClick': (Object _) => add(null)},
              '$total'),
          h('button', {'class': 'step', 'onClick': (Object _) => setStep(10)},
              '$step'),
        ]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));

      root.act(() => host.root.byClass('add').click());
      expect(host.root.byClass('add').textContent, '1');

      root.act(() => host.root.byClass('step').click());
      root.act(() => host.root.byClass('add').click());
      expect(host.root.byClass('add').textContent, '11',
          reason: 'a stale reducer would still be adding 1');
    });
  });

  // -------------------------------------------------------------------------
  group('refs', () {
    test('a ref that is dropped stops pointing at the node', () {
      final a = Ref<Object?>(null);

      VNode app(Props props) {
        final (attached, setAttached) = useState(true);
        return h('div', {
          'ref': attached ? a : null,
          'onClick': (Object _) => setAttached(false),
        }, 'x');
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      expect(a.current, isNotNull);

      root.act(() => host.root.byTag('div').click());
      expect(a.current, isNull,
          reason: 'a null check on `current` has to mean detached');
    });

    test('swapping refs clears the old one', () {
      final a = Ref<Object?>(null);
      final b = Ref<Object?>(null);

      VNode app(Props props) {
        final (first, setFirst) = useState(true);
        return h('div', {
          'ref': first ? a : b,
          'onClick': (Object _) => setFirst(false),
        }, 'x');
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      root.act(() => host.root.byTag('div').click());

      expect(a.current, isNull);
      expect(b.current, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('effects', () {
    test('every cleanup in a batch runs before any new effect', () {
      final order = <String>[];

      VNode child(Props props) {
        useEffect(() {
          order.add('child create ${props['tick']}');
          return () => order.add('child cleanup ${props['tick']}');
        }, [props['tick']]);
        return h('i', null, 'c');
      }

      VNode parent(Props props) {
        final (tick, setTick) = useState(0);
        useEffect(() {
          order.add('parent create $tick');
          return () => order.add('parent cleanup $tick');
        }, [tick]);
        return h('div', {'onClick': (Object _) => setTick(tick + 1)},
            [use(child, {'tick': tick})]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(parent));
      order.clear();

      root.act(() => host.root.byTag('div').click());

      final firstCreate = order.indexWhere((e) => e.contains('create'));
      final lastCleanup = order.lastIndexWhere((e) => e.contains('cleanup'));
      expect(lastCleanup, lessThan(firstCreate),
          reason: 'destroys are a phase, not interleaved with creates: $order');
    });

    test('unmount cleans up children before their parent', () {
      final order = <String>[];

      VNode child(Props props) {
        useEffect(() => () => order.add('child'), const []);
        return h('i', null, 'c');
      }

      VNode parent(Props props) {
        useEffect(() => () => order.add('parent'), const []);
        return h('div', null, [use(child)]);
      }

      final host = TestHost();
      createRoot(host, host.root)
        ..render(use(parent))
        ..unmount();

      expect(order, ['child', 'parent']);
    });
  });

}
