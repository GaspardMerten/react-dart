@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:reactx/dom.dart';
import 'package:reactx/events.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// Runs the real client renderer in a browser (via `dart test -p chrome`).
///
/// This is the committed counterpart to the manual browser check: it compiles
/// to JS and drives the actual DOM, covering the parts the headless VM suite
/// can only approximate — event dispatch, focus, and hydration adoption.
///
/// Enable a Chrome/Chromium binary with, e.g.:
///   CHROME_EXECUTABLE=/path/to/chrome dart test -p chrome test/browser_test.dart

web.HTMLElement _mount() {
  final host = web.document.createElement('div') as web.HTMLElement;
  web.document.body!.append(host);
  return host;
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

VNode counter(Props props) {
  final (count, setCount) = useState(0);
  return div(null, [
    span(null, '$count'),
    button({'onClick': () => setCount((c) => c + 1)}, '+'),
  ]);
}

void main() {
  test('runApp mounts fresh DOM and click updates state', () async {
    final host = _mount();
    createRoot(DomHostAdapter(), host).render(use(counter));

    expect(host.querySelector('span')!.textContent, '0');
    (host.querySelector('button')! as web.HTMLElement).click();
    await _tick(); // real updates flush on a microtask

    expect(host.querySelector('span')!.textContent, '1');
  });

  test('hydrate adopts server markup and makes it interactive', () async {
    final host = _mount();

    // Pretend this came from the server.
    host.innerHTML = renderToString(use(counter)).toJS;
    final serverSpan = host.querySelector('span')!..setAttribute('data-src', 'server');

    createRoot(DomHostAdapter(), host).hydrate(use(counter));

    // Same physical node, not recreated.
    expect(host.querySelector('span')!.getAttribute('data-src'), 'server');
    expect(identical(host.querySelector('span'), serverSpan), isTrue);

    (host.querySelector('button')! as web.HTMLElement).click();
    await _tick();
    expect(host.querySelector('span')!.textContent, '1');
  });

  test('jsx templates render and event handlers fire in the DOM', () async {
    final host = _mount();

    VNode widget(Props props) {
      final (text, setText) = useState('');
      return jsx(r'''
        <div>
          <p>${0}</p>
          <button onClick=${1}>set</button>
        </div>
      ''', [text.isEmpty ? 'empty' : text, () => setText('clicked')]);
    }

    createRoot(DomHostAdapter(), host).render(use(widget));
    expect(host.querySelector('p')!.textContent, 'empty');

    (host.querySelector('button')! as web.HTMLElement).click();
    await _tick();
    expect(host.querySelector('p')!.textContent, 'clicked');
  });

  test('controlled input keeps focus across re-renders', () async {
    final host = _mount();

    VNode field(Props props) {
      final (value, setValue) = useState('');
      return input({
        'value': value,
        'onInput': (Object e) {
          final el = (e as web.Event).target as web.HTMLInputElement?;
          setValue(el?.value ?? '');
        },
      });
    }

    createRoot(DomHostAdapter(), host).render(use(field));
    final el = host.querySelector('input')! as web.HTMLInputElement;
    el.focus();
    el.value = 'hi';
    el.dispatchEvent(web.Event('input'));
    await _tick();

    expect(identical(web.document.activeElement, el), isTrue,
        reason: 're-render must not steal focus from the input');
    expect(el.value, 'hi');
  });

  group('event helpers', () {
    // These read through js_interop extension types, so only a real browser can
    // prove they work — on the VM the same names resolve to inert stubs.
    test('onValue reads the value of an input, textarea and select', () async {
      final seen = <String>[];
      VNode form(Props props) => el('form', null, [
            input({'onInput': onValue(seen.add)}),
            el('textarea', {'onInput': onValue(seen.add)}),
            el('select', {'onChange': onValue(seen.add)},
                [el('option', {'value': 'b'}, 'b')]),
          ]);

      final host = _mount();
      createRoot(DomHostAdapter(), host).render(use(form));

      (host.querySelector('input')! as web.HTMLInputElement).value = 'from-input';
      host.querySelector('input')!.dispatchEvent(web.Event('input'));
      (host.querySelector('textarea')! as web.HTMLTextAreaElement).value = 'from-area';
      host.querySelector('textarea')!.dispatchEvent(web.Event('input'));
      host.querySelector('select')!.dispatchEvent(web.Event('change'));
      await _tick();

      expect(seen, ['from-input', 'from-area', 'b']);
    });

    test('onChecked reads a checkbox', () async {
      bool? seen;
      VNode box(Props props) => input({
            'type': 'checkbox',
            'onChange': onChecked((v) => seen = v),
          });

      final host = _mount();
      createRoot(DomHostAdapter(), host).render(use(box));
      final el = host.querySelector('input')! as web.HTMLInputElement;
      el.checked = true;
      el.dispatchEvent(web.Event('change'));
      await _tick();

      expect(seen, isTrue);
    });

    test('keyOf reads a keyboard event, and non-key events yield \'\'', () async {
      final keys = <String>[];
      VNode field(Props props) => input({'onKeyDown': onKey(keys.add)});

      final host = _mount();
      createRoot(DomHostAdapter(), host).render(use(field));
      final el = host.querySelector('input')!;
      el.dispatchEvent(web.KeyboardEvent('keydown', web.KeyboardEventInit(key: 'Enter')));
      el.dispatchEvent(web.Event('keydown'));
      await _tick();

      expect(keys, ['Enter', '']);
    });

    test('listenKeys subscribes to the document and unsubscribes', () async {
      final keys = <String>[];
      final stop = listenKeys(keys.add);
      web.document.dispatchEvent(
          web.KeyboardEvent('keydown', web.KeyboardEventInit(key: 'a')));
      // Modifier chords are left to the browser.
      web.document.dispatchEvent(web.KeyboardEvent(
          'keydown', web.KeyboardEventInit(key: 'r', ctrlKey: true)));
      stop();
      web.document.dispatchEvent(
          web.KeyboardEvent('keydown', web.KeyboardEventInit(key: 'b')));
      await _tick();

      expect(keys, ['a']);
    });
  });
}
