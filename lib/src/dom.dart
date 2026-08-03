/// The browser client renderer: a [HostAdapter] over the real DOM, plus
/// [runApp] / [hydrateApp] entrypoints.
///
/// This is the only part of reactx that depends on `package:web`, so it must be
/// imported from a web entrypoint (compiled with dart2js / DDC), never from
/// server or VM code. Everything it does routes through the same reconciler the
/// headless tests exercise, so its behavior is the behavior already covered by
/// the VM test suite — this file only translates host operations to the DOM.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'host.dart';
import 'reconciler.dart';
import 'vdom.dart';

/// A [HostAdapter] backed by the browser DOM.
final class DomHostAdapter implements HostAdapter {
  /// Maps a reconciler listener to the JS callback actually registered, so
  /// [removeEventListener] can pass the same reference.
  final Map<void Function(Object), web.EventListener> _listeners =
      Map.identity();

  @override
  Object createElement(String tag) => web.document.createElement(tag);

  @override
  Object createText(String text) => web.document.createTextNode(text);

  @override
  void setText(Object node, String text) => (node as web.Text).data = text;

  @override
  void setAttribute(Object node, String name, Object? value) {
    final el = node as web.Element;
    // Honor the HostAdapter contract: a null value removes the attribute.
    if (value == null) {
      el.removeAttribute(name);
      return;
    }
    el.setAttribute(name, value == true ? '' : '$value');
    // Form controls read from properties, not attributes, after user input.
    if (name == 'value' || name == 'checked' || name == 'selected') {
      (el as JSObject).setProperty(name.toJS, value.jsify());
    }
  }

  @override
  void removeAttribute(Object node, String name) =>
      (node as web.Element).removeAttribute(name);

  @override
  void addEventListener(
      Object node, String type, void Function(Object event) handler) {
    void run(web.Event e) => handler(e);
    final js = run.toJS;
    _listeners[handler] = js;
    (node as web.EventTarget).addEventListener(type, js);
  }

  @override
  void removeEventListener(
      Object node, String type, void Function(Object event) handler) {
    final js = _listeners.remove(handler);
    if (js != null) (node as web.EventTarget).removeEventListener(type, js);
  }

  @override
  void insertBefore(Object parent, Object child, Object? reference) {
    (parent as web.Node).insertBefore(child as web.Node, reference as web.Node?);
  }

  @override
  void removeChild(Object parent, Object child) =>
      (parent as web.Node).removeChild(child as web.Node);

  @override
  Object? parentNode(Object node) => (node as web.Node).parentNode;

  @override
  void setInnerHtml(Object node, String html) =>
      (node as web.Element).innerHTML = html.toJS;

  @override
  List<Object> childNodes(Object node) {
    final list = (node as web.Node).childNodes;
    return [for (var i = 0; i < list.length; i++) list.item(i)!];
  }

  @override
  bool isText(Object node) => (node as web.Node).nodeType == web.Node.TEXT_NODE;

  @override
  Object? nextSibling(Object node) => (node as web.Node).nextSibling;
}

/// Mounts [app] into the element matching [selector] (default `#root`),
/// creating fresh DOM. Returns the [Root] so you can later re-render or unmount.
Root runApp(VNode app, {String selector = '#root'}) {
  final container = _require(selector);
  final root = createRoot(DomHostAdapter(), container);
  root.render(app);
  return root;
}

/// Hydrates server-rendered markup inside the element matching [selector],
/// adopting the existing DOM instead of recreating it. Pair with
/// `renderToString` / `renderToDocument` on the server.
Root hydrateApp(VNode app, {String selector = '#root'}) {
  final container = _require(selector);
  final root = createRoot(DomHostAdapter(), container);
  root.hydrate(app);
  return root;
}

web.Element _require(String selector) {
  final el = web.document.querySelector(selector);
  if (el == null) {
    throw StateError('reactx: no element matches selector "$selector"');
  }
  return el;
}
