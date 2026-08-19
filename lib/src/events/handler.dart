/// The shape of a DOM event handler, shared by the browser and stub
/// implementations of the event helpers.
library;

/// What an `on…` prop receives: the native event, opaque to platform-neutral
/// code.
///
/// Handlers are declared as taking an [Object] because the real type
/// (`web.Event`) cannot be named from code that also runs on the server. Read
/// values out of it with `valueOf`, `checkedOf`, `keyOf` — never by casting to
/// `dynamic`, which silently breaks under dart2js.
typedef EventHandler = void Function(Object event);
