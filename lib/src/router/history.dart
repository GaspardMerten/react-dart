/// The four things the router needs from its host, in whichever form the
/// current platform can provide them.
///
/// The browser gets `window.location` and the History API; the VM gets inert
/// stubs, because on the server the path is not ambient — it arrives with the
/// request and is passed to the tree as a prop. Same trick as
/// `package:reactx/events.dart`: one import, two implementations, no `dynamic`.
library;

export 'history_stub.dart' if (dart.library.js_interop) 'history_web.dart';
