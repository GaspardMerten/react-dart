/// Tests for the dev-mode guardrails.
///
/// Each of these covers a failure that used to be silent: the tree kept
/// rendering and went wrong somewhere else entirely. Everything here runs
/// behind `assert`, so it is on under `dart test` and gone from a release
/// build.
library;

import 'package:reactx/reactx.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

/// Captures everything the framework warns about while [body] runs.
List<String> warnings(void Function() body) {
  final captured = <String>[];
  final previous = reactxWarning;
  reactxWarning = captured.add;
  try {
    body();
  } finally {
    reactxWarning = previous;
  }
  return captured;
}

void main() {
  group('rules of hooks', () {
    test('a hook behind a condition is reported, not silently misread', () {
      late StateSetter<bool> setFlag;
      VNode bad(Props props) {
        final (flag, set) = useState(false);
        setFlag = set;
        // The second render takes a different path through the hooks.
        if (flag) useMemo(() => 1, const []);
        final (name, _) = useState('nate');
        return h('p', null, '$name$flag');
      }

      final app = mountApp(bad);
      expect(
        () => app.act(() => setFlag(true)),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains('useMemo'), contains('useState')))),
      );
    });

    test('calling fewer hooks than last time is reported', () {
      late StateSetter<bool> setLess;
      VNode bad(Props props) {
        final (less, set) = useState(false);
        setLess = set;
        if (!less) useMemo(() => 1, const []);
        return h('p', null, '$less');
      }

      final app = mountApp(bad);
      expect(
        () => app.act(() => setLess(true)),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('hooks'))),
      );
    });

    test('the same hooks every render is fine', () {
      late StateSetter<int> bump;
      VNode good(Props props) {
        final (n, set) = useState(0);
        bump = set;
        final doubled = useMemo(() => n * 2, [n]);
        return h('p', null, '$doubled');
      }

      final app = mountApp(good);
      app.act(() => bump(21));
      expect(app.tree.byTag('p').textContent, '42');
    });
  });

  group('keys', () {
    test('duplicate sibling keys are reported', () {
      VNode app(Props props) => h('ul', null, [
            h('li', {'key': 'a'}, 'one'),
            h('li', {'key': 'a'}, 'two'),
          ]);

      final logged = warnings(() => mountApp(app));
      expect(logged.join('\n'), contains('duplicate key "a"'));
    });

    test('distinct keys say nothing', () {
      VNode app(Props props) => h('ul', null, [
            h('li', {'key': 'a'}, 'one'),
            h('li', {'key': 'b'}, 'two'),
          ]);

      expect(warnings(() => mountApp(app)), isEmpty);
    });
  });

  group('hydration', () {
    /// Builds `<div><span>hi</span></div>` as pre-existing "server" markup.
    TestNode serverTree(TestHost host, String tag) {
      final div = TestNode.element('div');
      host.insertBefore(host.root, div, null);
      final inner = TestNode.element(tag)..children.add(TestNode.text('hi'));
      host.insertBefore(div, inner, null);
      return div;
    }

    test('a tag mismatch is reported and the stray node is dropped', () {
      VNode app(Props props) => h('div', null, [h('span', null, 'hi')]);

      final host = TestHost();
      serverTree(host, 'b'); // server wrote <b>, the tree wants <span>
      final root = createRoot(host, host.root);

      final logged = warnings(() => root.hydrate(use(app)));

      expect(logged.join('\n'), contains('hydration mismatch'));
      expect(host.root.children.first.toHtml(), '<div><span>hi</span></div>',
          reason: 'the mismatched node must be replaced, not left behind');
    });

    test('matching markup hydrates silently', () {
      VNode app(Props props) => h('div', null, [h('span', null, 'hi')]);

      final host = TestHost();
      final div = serverTree(host, 'span');
      final root = createRoot(host, host.root);

      final logged = warnings(() => root.hydrate(use(app)));

      expect(logged, isEmpty);
      expect(identical(host.root.children.first, div), isTrue,
          reason: 'the server node is adopted, not recreated');
    });
  });

  group('render errors', () {
    test('a throwing component names itself and its ancestors', () {
      VNode boom(Props props) => throw StateError('kaboom');
      VNode middle(Props props) => use(boom);
      VNode app(Props props) => h('div', null, [use(middle)]);

      late List<String> logged;
      expect(
        () => logged = warnings(() => mountApp(app)),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'kaboom')),
      );
      // The original error is rethrown untouched; the context is a warning.
      logged = warnings(() {
        try {
          mountApp(app);
        } on StateError {
          // expected
        }
      });
      expect(logged.join('\n'), contains('threw during render'));
    });
  });
}
