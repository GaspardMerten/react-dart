/// Reading DOM events from code that also runs on the server.
///
/// Import this from a **shared component file** — the one the server renders
/// and the client hydrates. The conditional export below resolves to real
/// `package:web` calls in the browser and to inert stubs on the VM, so a single
/// component body works in both places and you never write a platform shim:
///
/// ```dart
/// import 'package:reactx/events.dart';
///
/// <input value={draft} onInput={onValue(setDraft)} />
/// <button onClick={on(() => setOpen(true))}>Open</button>
/// ```
///
/// Every helper takes the `Object` an `on…` prop receives. Do not reach into
/// that object yourself with `dynamic`: `web.Event` is a js_interop extension
/// type whose members are erased, so `(event as dynamic).target` throws at
/// runtime under dart2js. These helpers exist so that trap is the framework's
/// problem, not yours.
library;

export 'src/events/events_stub.dart'
    if (dart.library.js_interop) 'src/events/events_web.dart';
export 'src/events/handler.dart' show EventHandler;
