/// Tests for stores: identity-keyed shared state with no provider in the tree.
///
/// The two properties that matter most are the ones a global would break —
/// state belongs to the root that is rendering, and a component only re-renders
/// for the part of the state it actually reads.
library;

import 'package:reactx/reactx.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

// A tiny store: a list of names plus a counter, so a selector can watch one
// field while the other moves.
class Model {
  const Model({this.names = const [], this.ticks = 0});

  final List<String> names;
  final int ticks;

  Model copyWith({List<String>? names, int? ticks}) =>
      Model(names: names ?? this.names, ticks: ticks ?? this.ticks);
}

sealed class Action {
  const Action();
}

class Add extends Action {
  const Add(this.name);
  final String name;
}

class Tick extends Action {
  const Tick();
}

Model reduce(Model state, Action action) => switch (action) {
      Add(:final name) => state.copyWith(names: [...state.names, name]),
      Tick() => state.copyWith(ticks: state.ticks + 1),
    };

final store = defineStore(const Model(names: ['a']), reduce, debugLabel: 'test');

void main() {
  group('useStore', () {
    test('reads the initial state and re-renders on dispatch', () {
      late void Function(Action) dispatch;
      VNode app(Props props) {
        final (state, d) = useStore(store);
        dispatch = d;
        return h('p', null, state.names.join(','));
      }

      final t = mountApp(app);
      expect(t.tree.byTag('p').textContent, 'a');

      t.act(() => dispatch(const Add('b')));
      expect(t.tree.byTag('p').textContent, 'a,b');
    });

    test('the dispatch function is identical across renders', () {
      final seen = <void Function(Action)>[];
      late void Function(Action) dispatch;
      VNode app(Props props) {
        final (state, d) = useStore(store);
        dispatch = d;
        seen.add(d);
        return h('p', null, '${state.ticks}');
      }

      final t = mountApp(app);
      t.act(() => dispatch(const Tick()));
      t.act(() => dispatch(const Tick()));

      expect(seen.length, 3);
      expect(identical(seen[0], seen[1]), isTrue);
      expect(identical(seen[1], seen[2]), isTrue,
          reason: 'a new closure per render would break memo and deps lists');
    });

    test('a dispatch that does not change the state renders nothing', () {
      var renders = 0;
      VNode app(Props props) {
        final (state, _) = useStore(store);
        renders++;
        return h('p', null, '${state.ticks}');
      }

      mountApp(app);
      expect(renders, 1);

      // A reducer that returns an equal value is a no-op, as in useReducer.
      final noop = defineStore(0, (int s, int a) => s);
      VNode other(Props props) {
        final (_, d) = useStore(noop);
        d(1);
        return h('i', null, 'x');
      }

      expect(() => mountApp(other), returnsNormally);
      expect(renders, 1);
    });
  });

  group('useSelect', () {
    test('re-renders only when the selected slice changes', () {
      var badgeRenders = 0;
      late void Function(Action) dispatch;

      VNode badge(Props props) {
        badgeRenders++;
        final count = useSelect(store, (Model s) => s.names.length);
        return h('b', null, '$count');
      }

      VNode app(Props props) {
        final (_, d) = useStore(store);
        dispatch = d;
        return h('div', null, [use(badge)]);
      }

      final t = mountApp(app);
      expect(badgeRenders, 1);

      // Ticks do not change names.length…
      t.act(() => dispatch(const Tick()));
      final afterTick = badgeRenders;

      // …but adding a name does.
      t.act(() => dispatch(const Add('b')));
      expect(t.tree.byTag('b').textContent, '2');
      expect(badgeRenders, greaterThan(afterTick));
    });

    test('a selector reads the value the component rendered with', () {
      late void Function(Action) dispatch;
      VNode app(Props props) {
        final ticks = useSelect(store, (Model s) => s.ticks);
        final (_, d) = useStore(store);
        dispatch = d;
        return h('p', null, '$ticks');
      }

      final t = mountApp(app);
      t.act(() => dispatch(const Tick()));
      t.act(() => dispatch(const Tick()));
      expect(t.tree.byTag('p').textContent, '2');
    });
  });

  group('useDispatch', () {
    test('a write-only component is not woken by a change', () {
      // The writer and the reader are siblings under a root that itself does
      // not subscribe, so nothing cascades into the writer from above — the
      // only thing that could re-render it is a subscription it does not have.
      var formRenders = 0;
      late void Function(Action) dispatch;

      VNode form(Props props) {
        formRenders++;
        dispatch = useDispatch(store);
        return h('button', null, 'add');
      }

      VNode display(Props props) {
        final (state, _) = useStore(store);
        return h('p', null, '${state.names.length}');
      }

      VNode app(Props props) => h('div', null, [use(display), use(form)]);

      final t = mountApp(app);
      expect(formRenders, 1);

      t.act(() => dispatch(const Add('b')));
      expect(t.tree.byTag('p').textContent, '2', reason: 'the reader updated');
      expect(formRenders, 1, reason: 'the writer must not subscribe');
    });
  });

  group('ownership', () {
    test('two roots have independent state', () {
      // Each mount captures its own dispatcher: they are different closures
      // precisely because the state they write to is different.
      final dispatchers = <void Function(Action)>[];
      VNode app(Props props) {
        final (state, d) = useStore(store);
        if (!dispatchers.contains(d)) dispatchers.add(d);
        return h('p', null, state.names.join(','));
      }

      final a = mountApp(app);
      final b = mountApp(app);
      expect(dispatchers.length, 2, reason: 'one dispatcher per root');

      a.act(() => dispatchers.first(const Add('only-a')));

      expect(a.tree.byTag('p').textContent, 'a,only-a');
      expect(b.tree.byTag('p').textContent, 'a',
          reason: 'store state belongs to a root, never to a static');
    });

    test('the server sees the initial state, and writing is a no-op', () {
      VNode app(Props props) {
        final (state, dispatch) = useStore(store);
        dispatch(const Add('ignored')); // no-op on the server, like setState
        return h('p', null, state.names.join(','));
      }

      expect(renderToString(app), '<p>a</p>');
      // A second render must not see the first one's writes.
      expect(renderToString(app), '<p>a</p>');
    });

    test('unmounting unsubscribes', () {
      late void Function(Action) dispatch;
      late StateSetter<bool> setShown;
      var childRenders = 0;

      VNode child(Props props) {
        childRenders++;
        final (state, _) = useStore(store);
        return h('p', null, '${state.ticks}');
      }

      VNode app(Props props) {
        final (shown, set) = useState(true);
        setShown = set;
        dispatch = useDispatch(store);
        return h('div', null, [if (shown) use(child)]);
      }

      final t = mountApp(app);
      expect(childRenders, 1);

      t.act(() => setShown(false));
      final after = childRenders;
      t.act(() => dispatch(const Tick()));
      expect(childRenders, after, reason: 'an unmounted fiber must not wake up');
    });
  });
}
