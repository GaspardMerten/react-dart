/// Tests for the reconciler's bailouts: the work it is supposed to *not* do.
///
/// These are easy to regress silently — everything still renders correctly if a
/// bailout stops working, just more slowly — so each one asserts on a counter
/// rather than on output.
library;

// A memoized component is still a component, so it keeps the PascalCase naming
// that lets dartx tell `<Row />` from `<row>`.
// ignore_for_file: non_constant_identifier_names

import 'package:reactx/reactx.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

TestNode? find(TestNode node, String tag) {
  if (node.tag == tag) return node;
  for (final child in node.children) {
    final hit = find(child, tag);
    if (hit != null) return hit;
  }
  return null;
}

String textOf(TestNode node) =>
    node.children.map((c) => c.text ?? textOf(c)).join();

void main() {
  group('identical-vnode bailout', () {
    test('a hoisted child is not re-rendered when its parent re-renders', () {
      var childRenders = 0;
      VNode child(Props props) {
        childRenders++;
        return h('span', null, 'child');
      }

      // Built once, outside the parent — the equivalent of a `const` widget.
      final hoisted = use(child);

      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        return h('div', null, [h('b', null, '$tick'), hoisted]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));
      expect(childRenders, 1);

      root.act(() => setTick(1));
      expect(textOf(find(host.root, 'b')!), '1', reason: 'parent did re-render');
      expect(childRenders, 1, reason: 'the identical child must be skipped');
    });

    test('a non-hoisted child still re-renders', () {
      var childRenders = 0;
      VNode child(Props props) {
        childRenders++;
        return h('span', null, 'child');
      }

      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        return h('div', null, [h('b', null, '$tick'), use(child)]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));
      root.act(() => setTick(1));
      expect(childRenders, 2);
    });

    test('a hoisted child that owns state still updates itself', () {
      // The bailout must not strand a component that calls setState.
      late StateSetter<int> bump;
      VNode counter(Props props) {
        final (n, setN) = useState(0);
        bump = setN;
        return h('span', null, '$n');
      }

      final hoisted = use(counter);
      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        return h('div', null, [h('b', null, '$tick'), hoisted]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));

      root.act(() => setTick(1)); // parent renders, child is skipped
      root.act(() => bump(5)); // child must still be able to update
      expect(textOf(find(host.root, 'span')!), '5');
    });
  });

  group('memo', () {
    test('equal props skip the render', () {
      var renders = 0;
      VNode row(Props props) {
        renders++;
        return h('span', null, '${props['label']}');
      }

      final Row = memo(row);
      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        // A brand-new props map every render, with the same contents.
        return h('div', null, [h('b', null, '$tick'), use(Row, {'label': 'x'})]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));
      expect(renders, 1);

      root.act(() => setTick(1));
      expect(textOf(find(host.root, 'b')!), '1', reason: 'the parent updated');
      expect(renders, 1, reason: 'equal props must not re-render the child');
    });

    test('changed props still render', () {
      var renders = 0;
      VNode row(Props props) {
        renders++;
        return h('span', null, '${props['label']}');
      }

      final Row = memo(row);
      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        return h('div', null, [use(Row, {'label': '$tick'})]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));

      root.act(() => setTick(1));
      expect(textOf(find(host.root, 'span')!), '1');
      expect(renders, 2);
    });

    test('a memoized component with its own state still updates', () {
      late StateSetter<int> bump;
      VNode counter(Props props) {
        final (n, setN) = useState(0);
        bump = setN;
        return h('span', null, '$n');
      }

      final Counter = memo(counter);
      late StateSetter<int> setTick;
      VNode parent(Props props) {
        final (tick, set) = useState(0);
        setTick = set;
        return h('div', null, [h('b', null, '$tick'), use(Counter)]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));

      root.act(() => setTick(1)); // parent renders, child is skipped
      root.act(() => bump(5)); // the child must still be able to update itself
      expect(textOf(find(host.root, 'span')!), '5');
    });

    test('a context change reaches a memoized consumer', () {
      final ctx = createContext<int>(-1, name: 'n');
      VNode consumer(Props props) => h('span', null, '${useContext(ctx)}');
      final Consumer = memo(consumer);

      late StateSetter<int> setN;
      VNode scope(Props props) {
        final (n, set) = useState(0);
        setN = set;
        return ctx.provider(value: n, children: props['children']);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(scope, null, use(Consumer)));
      expect(textOf(find(host.root, 'span')!), '0');

      root.act(() => setN(3));
      expect(textOf(find(host.root, 'span')!), '3',
          reason: 'equal props do not mean equal context');
    });

    test('a custom comparator decides', () {
      var renders = 0;
      VNode row(Props props) {
        renders++;
        return h('span', null, '${props['n']}');
      }

      // Only re-render when the value crosses a whole ten.
      final Row = memo(row,
          areEqual: (a, b) => (a['n'] as int) ~/ 10 == (b['n'] as int) ~/ 10);

      late StateSetter<int> setN;
      VNode parent(Props props) {
        final (n, set) = useState(0);
        setN = set;
        return h('div', null, [use(Row, {'n': n})]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));

      root.act(() => setN(5));
      expect(renders, 1, reason: 'same decade');
      root.act(() => setN(11));
      expect(renders, 2);
      expect(textOf(find(host.root, 'span')!), '11');
    });
  });

  group('context vs. the bailout', () {
    // `Scope(children: props['children'])` hands back the *same* child VNode on
    // every render, so a naive identical-vnode bailout would skip the subtree —
    // and with it the new context value. This is the shape every provider that
    // owns state ends up having, so it has to keep working.
    (TestHost, Root, VNode Function(Props)) scoped(
      Context<int> ctx,
      void Function(StateSetter<int>) captureSetter,
      VNode Function(Props) child,
    ) {
      VNode scope(Props props) {
        final (n, set) = useState(0);
        captureSetter(set);
        return ctx.provider(value: n, children: props['children']);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(scope, null, use(child)));
      return (host, root, scope);
    }

    test('a provider update reaches consumers through an identical subtree', () {
      final ctx = createContext<int>(-1, name: 'n');
      var childRenders = 0;
      VNode consumer(Props props) {
        childRenders++;
        return h('span', null, '${useContext(ctx)}');
      }

      late StateSetter<int> setN;
      final (host, root, _) = scoped(ctx, (s) => setN = s, consumer);
      expect(textOf(find(host.root, 'span')!), '0');
      expect(childRenders, 1);

      root.act(() => setN(7));

      expect(textOf(find(host.root, 'span')!), '7');
      expect(childRenders, 2, reason: 'the consumer must have re-rendered');
    });

    test('an unchanged provider value keeps the bailout', () {
      // The same value across renders — what memoizing a context value buys you.
      final ctx = createContext<Object>('none', name: 'stable');
      const value = 'stable';
      var childRenders = 0;
      VNode consumer(Props props) {
        childRenders++;
        return h('span', null, '${useContext(ctx)}');
      }

      late StateSetter<int> setN;
      VNode scope(Props props) {
        final (_, set) = useState(0);
        setN = set;
        return ctx.provider(value: value, children: props['children']);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(scope, null, use(consumer)));
      expect(childRenders, 1);

      root.act(() => setN(1));
      expect(childRenders, 1, reason: 'nothing below the provider changed');
    });
  });

  group('dirty-flag dedupe', () {
    test('a child refreshed by its dirty parent renders once, not twice', () {
      var childRenders = 0;
      late StateSetter<int> setChild;
      VNode child(Props props) {
        final (n, set) = useState(0);
        setChild = set;
        childRenders++;
        return h('span', null, '${props['from']}-$n');
      }

      late StateSetter<int> setParent;
      VNode parent(Props props) {
        final (n, set) = useState(0);
        setParent = set;
        return h('div', null, [
          use(child, {'from': n})
        ]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(parent));
      expect(childRenders, 1);

      // Both fibers go dirty in one batch. The parent's pass already re-renders
      // the child with fresh hook state, so the child's own entry is redundant.
      root.act(() {
        setParent(1);
        setChild(2);
      });

      expect(textOf(find(host.root, 'span')!), '1-2');
      expect(childRenders, 2, reason: 'one render for the batch, not two');
    });
  });

  group('stable event listeners', () {
    test('an inline closure does not re-bind the host listener', () {
      late StateSetter<int> setCount;
      VNode counter(Props props) {
        final (count, set) = useState(0);
        setCount = set;
        // A brand-new closure every render — the common case, and the one that
        // used to detach and re-attach on every update.
        return h('button', {'onClick': () => set(count + 1)}, '$count');
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(counter));

      final afterMount = host.addListenerCount;
      expect(afterMount, 1);

      root.act(() => setCount(1));
      root.act(() => setCount(2));

      expect(host.addListenerCount, afterMount, reason: 'no re-binding');
      expect(host.removeListenerCount, 0);
      expect(textOf(find(host.root, 'button')!), '2');
    });

    test('the trampoline always calls the newest handler', () {
      // The listener object is stable, so it must not close over a stale
      // handler: clicking twice has to increment twice.
      VNode counter(Props props) {
        final (count, setCount) = useState(0);
        return h('button', {'onClick': () => setCount(count + 1)}, '$count');
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(counter));
      final button = find(host.root, 'button')!;

      root.act(() => button.dispatch('click'));
      root.act(() => button.dispatch('click'));
      expect(textOf(button), '2');
    });

    test('a handler replaced by null stops firing', () {
      var clicks = 0;
      late StateSetter<bool> setEnabled;
      VNode widget(Props props) {
        final (enabled, set) = useState(true);
        setEnabled = set;
        return h('button', {'onClick': enabled ? () => clicks++ : null}, 'go');
      }

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(widget));
      final button = find(host.root, 'button')!;

      root.act(() => button.dispatch('click'));
      expect(clicks, 1);

      root.act(() => setEnabled(false));
      root.act(() => button.dispatch('click'));
      expect(clicks, 1, reason: 'the old handler must have been unbound');
      expect(host.removeListenerCount, 1);
    });

    test('listeners are removed on unmount', () {
      VNode widget(Props props) => h('button', {'onClick': () {}}, 'go');

      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(use(widget));
      expect(host.addListenerCount, 1);

      root.unmount();
      expect(host.removeListenerCount, 1);
    });
  });

  // -------------------------------------------------------------------------
  group('a provider change is scoped to what reads it', () {
    test('a subtree that never calls useContext keeps its bailouts', () {
      final theme = createContext<String>('light', name: 'Theme');
      var readerRenders = 0;
      var strangerRenders = 0;

      VNode reader(Props props) {
        readerRenders++;
        return h('p', {'class': 'reader'}, useContext(theme));
      }

      // Reached through an identical vnode, exactly like the reader — the only
      // difference is that it does not read the context.
      VNode stranger(Props props) {
        strangerRenders++;
        return h('p', {'class': 'stranger'}, 'x');
      }

      final subtree = h('div', null, [use(reader), use(stranger)]);

      VNode app(Props props) {
        final (value, setValue) = useState('light');
        return h('section', {'onClick': (Object _) => setValue('dark')},
            [theme.provider(value: value, children: subtree)]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      expect(readerRenders, 1);
      expect(strangerRenders, 1);

      root.act(() => host.root.byTag('section').click());

      expect(host.root.byClass('reader').textContent, 'dark',
          reason: 'the consumer must still see the new value');
      expect(readerRenders, 2);
      expect(strangerRenders, 1,
          reason: 'nothing it renders depends on the context that changed');
    });

    test('a consumer nested below a non-consumer is still reached', () {
      final theme = createContext<String>('light', name: 'Theme');

      VNode deep(Props props) => h('p', {'class': 'deep'}, useContext(theme));
      VNode middle(Props props) => h('div', null, [use(deep)]);
      final subtree = use(middle);

      VNode app(Props props) {
        final (value, setValue) = useState('light');
        return h('section', {'onClick': (Object _) => setValue('dark')},
            [theme.provider(value: value, children: subtree)]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      root.act(() => host.root.byTag('section').click());

      expect(host.root.byClass('deep').textContent, 'dark',
          reason: 'the middle component reads nothing, but its child does');
    });

    test('two contexts do not interfere', () {
      final a = createContext<String>('a0', name: 'A');
      final b = createContext<String>('b0', name: 'B');
      var bReaderRenders = 0;

      VNode readsB(Props props) {
        bReaderRenders++;
        return h('p', {'class': 'b'}, useContext(b));
      }

      final subtree = use(readsB);

      VNode app(Props props) {
        final (aValue, setA) = useState('a0');
        return h('section', {'onClick': (Object _) => setA('a1')}, [
          a.provider(
            value: aValue,
            children: b.provider(value: 'b0', children: subtree),
          )
        ]);
      }

      final host = TestHost();
      final root = createRoot(host, host.root)..render(use(app));
      expect(bReaderRenders, 1);

      root.act(() => host.root.byTag('section').click());
      expect(bReaderRenders, 1, reason: 'only A changed, and it reads B');
    });
  });

}
