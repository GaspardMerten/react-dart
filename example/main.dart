/// Browser client entrypoint. Compile with:
///
/// ```
/// dart compile js example/main.dart -o example/main.dart.js
/// ```
///
/// It hydrates the server-rendered markup in `#root`, making it interactive
/// without recreating the DOM.
library;

import 'package:reactx/dom.dart';

import 'app.dart';
import 'app.reactx.g.dart';

void main() {
  registerAppTemplates();
  hydrateApp(use(app));
}
