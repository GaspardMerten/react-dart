/// The shared component tree for the example app.
///
/// The exact same code renders on the server (`server.dart` -> HTML) and on the
/// client (`main.dart` -> hydrated, interactive DOM). That is the whole pitch:
/// write components once, get SSR + a live client, all in pure Dart.
library;

import 'package:reactx/reactx.dart';

// Read event.target.value with the right implementation per platform: real
// `package:web` types on the client, a never-called stub on the server.
import 'event_target_value_stub.dart'
    if (dart.library.js_interop) 'event_target_value_web.dart';

/// Root component.
VNode app(Props props) => div({'class': 'app'}, [
      h1(null, 'reactx demo'),
      p(null, 'React, reimplemented in Dart — server-rendered, then hydrated.'),
      use(counter),
      use(todos),
    ]);

/// A classic counter, written with the jsx template syntax.
VNode counter(Props props) {
  final (count, setCount) = useState(0);
  return jsx(r'''
    <section class="counter">
      <h2>Counter</h2>
      <p>Value: <strong>${0}</strong></p>
      <button onClick=${1}>-</button>
      <button onClick=${2}>+</button>
    </section>
  ''', [
    count,
    () => setCount((c) => c - 1),
    () => setCount((c) => c + 1),
  ]);
}

/// A controlled-input todo list. Shows keyed list reconciliation.
VNode todos(Props props) {
  final (items, setItems) = useState<List<String>>(const ['Learn reactx']);
  final (draft, setDraft) = useState('');

  void add() {
    if (draft.trim().isEmpty) return;
    setItems([...items, draft.trim()]);
    setDraft('');
  }

  final rows = [
    for (final (i, item) in items.indexed) li({'key': i}, item),
  ];

  return jsx(r'''
    <section class="todos">
      <h2>Todos (${0})</h2>
      <ul>${1}</ul>
      <input value="${2}" onInput=${3} placeholder="Add a todo" />
      <button onClick=${4}>Add</button>
    </section>
  ''', [
    items.length,
    rows,
    draft,
    (Object e) => setDraft(eventTargetValue(e)),
    add,
  ]);
}
