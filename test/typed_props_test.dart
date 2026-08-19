/// Typed props: the generated props class, and what the reconciler does with it.
///
/// Two halves, tested separately because they fail separately. The generator is
/// a pure function from a component's signature to a class, so it is checked by
/// reading the Dart it produces. The runtime half is checked by mounting
/// hand-written props classes — exactly what the generator emits — and driving
/// them.
library;

// Components are PascalCase so they read as elements, as everywhere else.
// ignore_for_file: non_constant_identifier_names

import 'package:reactx/dartx.dart';
import 'package:reactx/reactx.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

String generate(String source) {
  final result = transpileDartx(source, banner: false);
  if (!result.ok) throw StateError(result.errors.first.toString());
  return result.code!;
}

String? errorFor(String source) {
  final result = transpileDartx(source, banner: false);
  return result.ok ? null : result.errors.first.message;
}

// ---------------------------------------------------------------------------
// Components, written the way the generator would have written them.
// ---------------------------------------------------------------------------

Component Badge({required String label, int count = 0}) =>
    h('span', {'class': 'badge'}, '$label $count');

final class BadgeProps extends ComponentProps {
  const BadgeProps({required this.label, this.count = 0, super.key});
  final String label;
  final int count;
  @override
  String get name => 'Badge';
  @override
  VNode build() => Badge(label: label, count: count);
  @override
  List<Object?> get fields => [label, count];
}

/// Counts its own renders, so a bailout is observable from outside.
int badgeRenders = 0;

Component MemoBadge({required String label}) {
  badgeRenders++;
  return h('span', {'class': 'memo'}, label);
}

final class MemoBadgeProps extends ComponentProps {
  const MemoBadgeProps({required this.label, super.key});
  final String label;
  @override
  String get name => 'MemoBadge';
  @override
  VNode build() => MemoBadge(label: label);
  @override
  List<Object?> get fields => [label];
  @override
  bool get memoized => true;
}

Component Stepper() {
  final (n, setN) = useState(0);
  return h('button', {'onClick': (Object _) => setN(n + 1)}, '$n');
}

final class StepperProps extends ComponentProps {
  const StepperProps({super.key});
  @override
  String get name => 'Stepper';
  @override
  VNode build() => Stepper();
}

Component Boom() => throw StateError('boom');

final class BoomProps extends ComponentProps {
  const BoomProps({super.key});
  @override
  String get name => 'Boom';
  @override
  VNode build() => Boom();
}

void main() {
  // -------------------------------------------------------------------------
  group('the generated class', () {
    test('turns the parameter list into constructor arguments', () {
      final code = generate('''
Component StatCard({required int value, String label = ''}) => <div />;
''');

      expect(code, contains('final class StatCardProps extends ComponentProps'));
      expect(code,
          contains("const StatCardProps({required this.value, this.label = ''"));
      expect(code, contains('final int value;'));
      expect(code, contains('final String label;'));
      expect(code, contains('VNode build() => StatCard(value: value, '
          'label: label);'));
    });

    test('every component accepts a key without declaring one', () {
      expect(generate('Component Row() => <li />;'),
          contains('const RowProps({super.key});'));
    });

    test('the name is carried for diagnostics', () {
      expect(generate('Component Row() => <li />;'),
          contains("String get name => 'Row';"));
    });

    test('fields are the arguments, in order, and never the key', () {
      final code = generate(
          'Component Row({required int a, required int b}) => <li />;');
      expect(code, contains('List<Object?> get fields => [a, b];'));
      expect(code, isNot(contains('fields => [a, b, key]')));
    });

    test('memo is opt-in and shows up as a flag', () {
      expect(generate('Component Row({required int a}) => <li />;'),
          isNot(contains('memoized')));
      expect(
          generate('@memoized\n'
              'Component Row({required int a}) => <li />;'),
          contains('bool get memoized => true;'));
    });

    test('an empty collection default is made const, so the constructor is',
        () {
      final code = generate('''
Component Layout({List<VNode> children = const [], Props extra = const {}}) =>
    <main />;
''');
      expect(code, contains('const LayoutProps('));
      expect(code, contains('this.children = const []'));
    });

    test('a default that might not be const costs the constructor its const',
        () {
      final code = generate('''
Component Row({Duration wait = someTopLevelDuration}) => <li />;
''');
      expect(code, contains('RowProps({this.wait = someTopLevelDuration'));
      expect(code, isNot(contains('const RowProps(')));
    });

    test('a function that returns VNode is the untyped form, left alone', () {
      expect(generate('VNode Plain(Props props) => <li />;'),
          isNot(contains('PlainProps')));
      expect(generate('VNode Helper({required int a}) => <li />;'),
          isNot(contains('HelperProps')));
    });
  });

  // -------------------------------------------------------------------------
  group('what the generator refuses', () {
    test('a positional parameter, which has no attribute name', () {
      expect(errorFor('Component Row(int a) => <li />;'),
          contains('named parameters only'));
    });

    test('a parameter called key, which would fight the element identity', () {
      expect(errorFor('Component Row({int? key}) => <li />;'),
          contains('reserved'));
    });

    test('a lowercase name, which markup would read as an HTML tag', () {
      expect(errorFor('Component row({required int a}) => <li />;'),
          contains('capitalised'));
    });

    test('type parameters, which markup has nowhere to write', () {
      expect(errorFor('Component Row<T>({required T a}) => <li />;'),
          contains('type parameters'));
    });

    test('a parameter named after a member the class itself declares', () {
      // Each of these would become `final X name;` beside `String get name`.
      for (final reserved in ['name', 'build', 'fields', 'memoized']) {
        expect(errorFor('Component Row({required int $reserved}) => <li />;'),
            contains('reserved'),
            reason: reserved);
      }
    });

    test('a props class that is already declared in the file', () {
      expect(
          errorFor('class RowProps {}\nComponent Row({required int a}) '
              '=> <li />;'),
          contains('already declared'));
    });
  });

  // -------------------------------------------------------------------------
  group('the generated code compiles', () {
    test('a nullable function-typed parameter keeps its ?', () {
      final code = generate('Component Row({void onTap()?}) => <li />;');
      expect(code, contains('final void Function()? onTap;'),
          reason: 'without the ?, the optional field can never be left unset');
    });

    test('a required function-typed parameter does not gain one', () {
      expect(generate('Component Row({required void onTap()}) => <li />;'),
          contains('final void Function() onTap;'));
    });

    test('a diagnostic points at the line the declaration is on', () {
      final result = transpileDartx('''
final a = <div>
  <span>x</span>
</div>;
Component Bad(int p) => <li />;
''', banner: false);

      expect(result.ok, isFalse);
      // The declaration is on the 4th line of the literal above (the leading
      // newline is not a line). Byte offsets shift during transpilation; line
      // numbers do not, which is the whole reason the map is built from the
      // transpiled code.
      expect(result.errors.single.line, 4);
    });
  });

  // -------------------------------------------------------------------------
  group('rendering', () {
    test('a props class renders as the component it names', () {
      expect(renderToString(const BadgeProps(label: 'Left', count: 3)),
          '<span class="badge">Left 3</span>');
    });

    test('a default fills in for an argument nobody passed', () {
      expect(renderToString(const BadgeProps(label: 'Left')),
          contains('Left 0'));
    });

    test('it is a VNode, so it goes anywhere a VNode goes', () {
      expect(
        renderToString(h('div', null, const [
          BadgeProps(label: 'a'),
          BadgeProps(label: 'b'),
        ])),
        '<div><span class="badge">a 0</span><span class="badge">b 0</span></div>',
      );
    });

    test('hooks work, and state belongs to the fiber', () {
      final app = mountApp(const StepperProps());
      expect(app.tree.byTag('button').textContent, '0');

      app.act(() => app.tree.byTag('button').click());
      expect(app.tree.byTag('button').textContent, '1');
    });

    test('state survives a re-render with new arguments', () {
      var label = 'a';
      VNode Parent(Props props) {
        final (_, setTick) = useState(0);
        return h('div', {
          'onClick': (Object _) {
            label = 'b';
            setTick(1);
          }
        }, [
          const StepperProps(),
          BadgeProps(label: label),
        ]);
      }

      final app = mountApp(use(Parent));
      app.act(() => app.tree.byTag('button').click());
      expect(app.tree.byTag('button').textContent, '1');

      // The identity that matters is the props *type*, not the instance, so
      // the stepper keeps its count while the badge next to it changes.
      app.act(() => app.tree.byTag('div').click());
      expect(app.tree.byTag('button').textContent, '1');
      expect(app.tree.byClass('badge').textContent, 'b 0');
    });

    test('a different component in the same slot remounts', () {
      var showStepper = true;
      VNode Parent(Props props) {
        final (_, setTick) = useState(0);
        return h('div', {
          'onClick': (Object _) {
            showStepper = !showStepper;
            setTick(1);
          }
        }, [
          if (showStepper) const StepperProps() else const BadgeProps(label: 'x')
        ]);
      }

      final app = mountApp(use(Parent));
      app.act(() => app.tree.byTag('button').click());
      expect(app.tree.byTag('button').textContent, '1');

      app.act(() => app.tree.byTag('div').click());
      expect(app.tree.maybeByTag('button'), isNull);
      expect(app.tree.byClass('badge').textContent, 'x 0');
    });
  });

  // -------------------------------------------------------------------------
  group('memo', () {
    test('equal arguments skip the render', () {
      badgeRenders = 0;
      var label = 'a';

      VNode Parent(Props props) {
        final (tick, setTick) = useState(0);
        return h('div', {'onClick': (Object _) => setTick(tick + 1)},
            [MemoBadgeProps(label: label)]);
      }

      final app = mountApp(use(Parent));
      expect(badgeRenders, 1);

      // The parent re-renders; the arguments are unchanged, so the child does
      // not.
      app.act(() => app.tree.byTag('div').click());
      expect(badgeRenders, 1);

      label = 'b';
      app.act(() => app.tree.byTag('div').click());
      expect(badgeRenders, 2);
      expect(app.tree.byClass('memo').textContent, 'b');
    });

    test('without the flag, every parent render reaches the child', () {
      var renders = 0;
      VNode Counted({required String label}) {
        renders++;
        return h('span', null, label);
      }

      // Built fresh each render, on purpose: hoisting the node would bail out
      // on identity alone, which is a different mechanism than memo.
      VNode Parent(Props props) {
        final (tick, setTick) = useState(0);
        return h('div', {'onClick': (Object _) => setTick(tick + 1)},
            [_CountedProps(Counted)]);
      }

      final app = mountApp(use(Parent));
      expect(renders, 1);
      app.act(() => app.tree.byTag('div').click());
      expect(renders, 2);
    });
  });

  // -------------------------------------------------------------------------
  group('diagnostics', () {
    test('a component that throws is named by the error it prints', () {
      expect(
        () => mountApp(const BoomProps()),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('boom'))),
      );
    });
  });
}

/// A props class with no memo flag, built around a closure so the test can
/// count renders. Not something the generator emits — the generator's output is
/// covered above — but it exercises the same runtime path.
final class _CountedProps extends ComponentProps {
  const _CountedProps(this.render);
  final VNode Function({required String label}) render;

  @override
  String get name => 'Counted';

  @override
  VNode build() => render(label: 'x');
}
