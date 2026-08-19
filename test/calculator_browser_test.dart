@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:reactx/dom.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import '../example/calculator/calculator.dartx.dart';

/// Drives the example calculator in a real browser (`dart test -p chrome`).
///
/// The VM suite (`test/calculator_test.dart`) already covers the arithmetic and
/// the component through `TestHost`; this covers what only a browser can show:
/// hydration of the server markup, real click events, and the document-level
/// keyboard listener registered by `useEffect`.
///
///   CHROME_EXECUTABLE=/path/to/chrome dart test -p chrome test/calculator_browser_test.dart

web.HTMLElement _mount() {
  final host = web.document.createElement('div') as web.HTMLElement;
  web.document.body!.append(host);
  return host;
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// Clicks the keypad button whose label is [label].
void _press(web.HTMLElement host, String label) {
  final keys = host.querySelectorAll('button');
  for (var i = 0; i < keys.length; i++) {
    final key = keys.item(i)! as web.HTMLElement;
    if (key.textContent == label) {
      key.click();
      return;
    }
  }
  fail('no key labelled "$label"');
}

/// Sends a `keydown` to the document, as a user typing would.
void _type(String key) => web.document.dispatchEvent(
    web.KeyboardEvent('keydown', web.KeyboardEventInit(key: key, bubbles: true)));

String _display(web.HTMLElement host) =>
    host.querySelector('.value')!.textContent ?? '';

void main() {
  test('hydrates the server markup without recreating it', () async {
    final host = _mount();
    host.innerHTML = renderToString(const CalculatorProps()).toJS;
    final serverScreen = host.querySelector('.value')!
      ..setAttribute('data-src', 'server');

    createRoot(DomHostAdapter(), host).hydrate(const CalculatorProps());

    expect(identical(host.querySelector('.value'), serverScreen), isTrue,
        reason: 'hydration must adopt the server node, not replace it');
    expect(_display(host), '0');

    _press(host, '9');
    await _tick();
    expect(_display(host), '9');
  });

  test('clicking through a calculation updates the display and tape', () async {
    final host = _mount();
    createRoot(DomHostAdapter(), host).render(const CalculatorProps());

    _press(host, '1');
    _press(host, '2');
    await _tick();
    expect(_display(host), '12');

    _press(host, '÷');
    await _tick();
    expect(host.querySelector('.tape')!.textContent, '12 ÷');

    _press(host, '4');
    _press(host, '=');
    await _tick();
    expect(_display(host), '3');
    expect(host.querySelector('.tape')!.textContent!.trim(), isEmpty);
  });

  test('the keyboard drives the same state', () async {
    final host = _mount();
    final root = createRoot(DomHostAdapter(), host)..render(const CalculatorProps());
    await _tick(); // effects (and the keydown listener) run after commit

    for (final key in ['7', '*', '6', 'Enter']) {
      _type(key);
    }
    await _tick();
    expect(_display(host), '42');

    _type('Escape');
    await _tick();
    expect(_display(host), '0');

    // Unmounting runs the effect cleanup, so later keystrokes go nowhere.
    root.unmount();
    _type('5');
    await _tick();
    expect(host.querySelector('.value'), isNull);
  });

  test('division by zero shows an error until cleared', () async {
    final host = _mount();
    createRoot(DomHostAdapter(), host).render(const CalculatorProps());

    for (final label in ['5', '÷', '0', '=']) {
      _press(host, label);
    }
    await _tick();
    expect(_display(host), 'Error');
    expect(host.querySelector('.value')!.className, contains('is-error'));

    _press(host, 'AC');
    await _tick();
    expect(_display(host), '0');
  });
}
