@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:reactx/dom.dart';
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
}
