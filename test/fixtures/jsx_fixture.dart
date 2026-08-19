/// A fixture for the `jsx(r'...')` string-template precompiler.
///
/// The examples are written in dartx, whose markup is compiled outright, so the
/// legacy runtime-template path needs a file of its own to keep exercising the
/// build_runner precompiler end to end. `dart run build_runner build` turns this
/// into `jsx_fixture.reactx.g.dart`.
library;

import 'package:reactx/reactx.dart';

/// A counter written with the runtime template syntax.
VNode fixtureCounter(Props props) {
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
