/// reactx browser client. Import this from a **web** entrypoint to mount or
/// hydrate a reactx tree into the real DOM.
///
/// ```dart
/// import 'package:reactx/dom.dart';
///
/// void main() => runApp(use(App));
/// ```
///
/// Re-exports the platform-neutral API from `package:reactx/reactx.dart`, so a
/// web entrypoint only needs this one import.
library;

export 'reactx.dart';
export 'src/dom.dart' show DomHostAdapter, runApp, hydrateApp, reassembleApps;
