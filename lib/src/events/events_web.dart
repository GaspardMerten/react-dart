/// Browser implementations of the event helpers.
///
/// Every one of these uses real `package:web` types. That is not a style
/// preference: `web.Event` is a js_interop extension type whose members are
/// erased at runtime, so `(event as dynamic).target` compiles to a lookup the
/// underlying JS object does not have and throws under dart2js. Getting this
/// wrong is the single easiest way to break a reactx app, which is exactly why
/// these helpers live in the framework instead of in every app.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'handler.dart';

/// The value of the element that raised [event] — `<input>`, `<textarea>` or
/// `<select>`. Returns `''` for anything else.
String valueOf(Object event) {
  final target = (event as web.Event).target;
  if (target == null) return '';
  if (target.isA<web.HTMLInputElement>()) {
    return (target as web.HTMLInputElement).value;
  }
  if (target.isA<web.HTMLTextAreaElement>()) {
    return (target as web.HTMLTextAreaElement).value;
  }
  if (target.isA<web.HTMLSelectElement>()) {
    return (target as web.HTMLSelectElement).value;
  }
  return '';
}

/// Whether [event] is a plain left-click that the page should handle itself.
///
/// False for a middle- or right-click, and for any click holding Ctrl, Cmd,
/// Shift or Alt — all of which mean "the browser should do its thing": open in
/// a new tab, save the target, add to a selection. A client-side router that
/// calls `preventDefault` on those takes away behaviour the user asked for and
/// that a plain `<a href>` would have given them.
bool isPlainClick(Object event) {
  final e = event as web.Event;
  if (!e.isA<web.MouseEvent>()) return true;
  final m = e as web.MouseEvent;
  return m.button == 0 &&
      !m.ctrlKey &&
      !m.metaKey &&
      !m.shiftKey &&
      !m.altKey;
}

/// Whether the checkbox or radio that raised [event] is checked.
bool checkedOf(Object event) {
  final target = (event as web.Event).target;
  if (target == null || !target.isA<web.HTMLInputElement>()) return false;
  return (target as web.HTMLInputElement).checked;
}

/// The `key` of a keyboard [event] (`'a'`, `'Enter'`, `'Escape'`, …).
String keyOf(Object event) {
  final e = event as web.Event;
  return e.isA<web.KeyboardEvent>() ? (e as web.KeyboardEvent).key : '';
}

/// The `id` attribute of the element that raised [event].
String targetIdOf(Object event) {
  final target = (event as web.Event).target;
  if (target == null || !target.isA<web.Element>()) return '';
  return (target as web.Element).id;
}

/// Suppresses the browser's default action (form submission, link navigation).
void preventDefault(Object event) => (event as web.Event).preventDefault();

/// Stops the event bubbling to ancestors.
void stopPropagation(Object event) => (event as web.Event).stopPropagation();

/// Adapts a `String` callback into an [EventHandler]: `onInput={onValue(setText)}`.
EventHandler onValue(void Function(String value) fn) =>
    (event) => fn(valueOf(event));

/// Adapts a `bool` callback into an [EventHandler]: `onChange={onChecked(setOn)}`.
EventHandler onChecked(void Function(bool checked) fn) =>
    (event) => fn(checkedOf(event));

/// Adapts a key callback into an [EventHandler]: `onKeyDown={onKey(handle)}`.
EventHandler onKey(void Function(String key) fn) =>
    (event) => fn(keyOf(event));

/// Adapts a handler that ignores its event: `onClick={on(() => setOpen(true))}`.
EventHandler on(void Function() fn) => (_) => fn();

/// Listens for keystrokes on the whole document until the returned function is
/// called — the shape `useEffect` wants:
///
/// ```dart
/// useEffect(() => listenKeys((key) => dispatch(key)), const []);
/// ```
///
/// With [ignoreModifiers] (the default), keystrokes held with Ctrl/Cmd/Alt are
/// skipped so browser and OS shortcuts keep working.
void Function() listenKeys(
  void Function(String key) onKey, {
  bool ignoreModifiers = true,
}) {
  void handle(web.Event event) {
    final e = event as web.KeyboardEvent;
    if (ignoreModifiers && (e.ctrlKey || e.metaKey || e.altKey)) return;
    onKey(e.key);
  }

  final listener = handle.toJS;
  web.document.addEventListener('keydown', listener);
  return () => web.document.removeEventListener('keydown', listener);
}
