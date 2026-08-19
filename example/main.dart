/// Browser client entrypoint. Compile with:
///
/// ```
/// dart run build_runner build                                # app.dartx -> Dart
/// dart compile js -O4 example/main.dart -o example/main.dart.js
/// ```
///
/// It hydrates the server-rendered markup in `#root`, making it interactive
/// without recreating the DOM.
library;

import 'package:reactx/dom.dart';

import 'app.dartx.dart';

void main() => hydrateApp(App);
