/// Tests for the example calculator: the pure state machine on its own, and
/// the mounted component driven through `TestHost` — no browser involved.
library;

import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

import '../example/calculator/calculator.dartx.dart';

/// Runs a sequence of keys (as `KeyboardEvent.key` strings) through the reducer.
CalcState run(String keys) {
  var state = CalcState.initial;
  for (final key in keys.split(' ')) {
    final action = actionForKey(key);
    expect(action, isNotNull, reason: 'unmapped key "$key"');
    state = calcReducer(state, action!);
  }
  return state;
}

/// Collects every `<button>` in a [TestHost] tree, in document order.
List<TestNode> buttons(TestNode node) => [
      if (node.tag == 'button') node,
      for (final child in node.children) ...buttons(child),
    ];

TestNode? findClass(TestNode node, String className) {
  final classes = node.attributes['class'] as String?;
  if (classes != null && classes.split(' ').contains(className)) return node;
  for (final child in node.children) {
    final found = findClass(child, className);
    if (found != null) return found;
  }
  return null;
}

String textOf(TestNode node) =>
    node.children.map((c) => c.text ?? textOf(c)).join();

void main() {
  group('state machine', () {
    test('types a multi-digit number', () {
      expect(run('1 2 3').display, '123');
    });

    test('adds', () => expect(run('1 2 0 + 3 0 =').display, '150'));
    test('subtracts', () => expect(run('9 - 4 =').display, '5'));
    test('multiplies', () => expect(run('6 * 7 =').display, '42'));
    test('divides', () => expect(run('8 / 2 =').display, '4'));

    test('chains left to right, evaluating as it goes', () {
      // 2 + 3 shows 5 as soon as * is pressed, then 5 * 4 = 20.
      final chained = run('2 + 3 *');
      expect(chained.display, '5');
      expect(calcReducer(run('2 + 3 * 4'), const Equals()).display, '20');
    });

    test('a second operator swaps the pending one', () {
      expect(run('5 + - 3 =').display, '2');
    });

    test('keeps a single decimal point', () {
      expect(run('1 . 5 . 5').display, '1.55');
    });

    test('a leading dot starts at zero', () => expect(run('. 5').display, '0.5'));

    test('formats fractions without trailing zeros', () {
      expect(run('1 / 8 =').display, '0.125');
    });

    test('starts a fresh operand after a result', () {
      expect(run('2 + 2 = 7').display, '7');
    });

    test('negates and un-negates', () {
      var state = calcReducer(run('4 2'), const Negate());
      expect(state.display, '-42');
      expect(calcReducer(state, const Negate()).display, '42');
    });

    test('percent divides by a hundred', () {
      expect(calcReducer(run('5 0'), const Percent()).display, '0.5');
    });

    test('backspace deletes the last character', () {
      expect(run('1 2 3 Backspace').display, '12');
      expect(run('7 Backspace').display, '0');
    });

    test('division by zero errors, and AC recovers', () {
      final errored = run('5 / 0 =');
      expect(errored.display, 'Error');
      expect(errored.error, isTrue);
      // Digits are ignored until cleared... except that they start over.
      expect(calcReducer(errored, const Clear()).display, '0');
    });

    test('ignores keys it does not handle', () {
      expect(actionForKey('a'), isNull);
      expect(actionForKey('F5'), isNull);
    });
  });

  group('component', () {
    test('server-renders the initial display', () {
      final html = renderToString(const CalculatorProps());
      expect(html, contains('class="value"'));
      expect(html, contains('>0</div>'));
      expect(html, contains('>AC</button>'));
    });

    test('clicking keys computes a result', () {
      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(const CalculatorProps());

      void press(String label) => root.act(() =>
          buttons(host.root).firstWhere((b) => textOf(b) == label).dispatch('click'));

      press('7');
      press('×');
      press('6');
      press('=');

      expect(textOf(findClass(host.root, 'value')!), '42');
      root.unmount();
    });

    test('shows the pending operation on the tape', () {
      final host = TestHost();
      final root = createRoot(host, host.root);
      root.render(const CalculatorProps());

      root.act(() => buttons(host.root)
          .firstWhere((b) => textOf(b) == '9')
          .dispatch('click'));
      root.act(() => buttons(host.root)
          .firstWhere((b) => textOf(b) == '+')
          .dispatch('click'));

      expect(textOf(findClass(host.root, 'tape')!), '9 +');
      root.unmount();
    });
  });
}
