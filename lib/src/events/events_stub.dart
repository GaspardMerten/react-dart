/// VM/server implementations of the event helpers.
///
/// Events only happen in a browser, so on the server every one of these is
/// unreachable — but they must exist and type-check, because the component file
/// that calls them is the *same* file the server renders. That is the whole
/// point of the conditional export in `package:reactx/events.dart`: application
/// code imports one library and never writes a platform shim of its own.
library;

import 'handler.dart';

/// The value of the element that raised [event]. Always `''` on the server.
String valueOf(Object event) => '';

/// Whether the checkbox/radio that raised [event] is checked. Always `false`
/// on the server.
bool checkedOf(Object event) => false;

/// See the browser implementation. There is no mouse on the server, so nothing
/// a component does with this can differ between the two first renders.
bool isPlainClick(Object event) => true;

/// The `key` of a keyboard [event]. Always `''` on the server.
String keyOf(Object event) => '';

/// The `id` attribute of the element that raised [event]. Always `''` on the
/// server.
String targetIdOf(Object event) => '';

/// Suppresses the browser's default action. A no-op on the server.
void preventDefault(Object event) {}

/// Stops the event bubbling. A no-op on the server.
void stopPropagation(Object event) {}

/// Adapts a `String` callback into an [EventHandler]: `onInput={onValue(setText)}`.
EventHandler onValue(void Function(String value) fn) => (_) {};

/// Adapts a `bool` callback into an [EventHandler]: `onChange={onChecked(setOn)}`.
EventHandler onChecked(void Function(bool checked) fn) => (_) {};

/// Adapts a key callback into an [EventHandler]: `onKeyDown={onKey(handle)}`.
EventHandler onKey(void Function(String key) fn) => (_) {};

/// Adapts a handler that ignores its event: `onClick={on(() => setOpen(true))}`.
EventHandler on(void Function() fn) => (_) => fn();

/// Listens for keystrokes on the whole document until the returned function is
/// called. Subscribes to nothing on the server and hands back a no-op, so a
/// `useEffect` that installs it is safe to run anywhere.
void Function() listenKeys(
  void Function(String key) onKey, {
  bool ignoreModifiers = true,
}) =>
    () {};
