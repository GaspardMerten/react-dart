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
import 'hot_reload.dart';
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

  /// What the server actually wrote on this element.
  ///
  /// Only attributes: properties and listeners are not recoverable from the
  /// DOM, and the server never sets them anyway. That is enough for hydration's
  /// purpose, which is noticing an attribute the client no longer wants.
  @override
  Props attributesOf(Object node) {
    final el = node as web.Element;
    final attrs = el.attributes;
    final props = <String, Object?>{};
    for (var i = 0; i < attrs.length; i++) {
      final attr = attrs.item(i);
      if (attr != null) props[attr.name] = attr.value;
    }
    return props;
  }

  @override
  void removeAttribute(Object node, String name) {
    final el = node as web.Element;
    el.removeAttribute(name);
    // Form controls read from properties once the user has touched them, so
    // dropping the attribute is not enough: without this, state can never
    // un-check a box the user checked.
    if (name == 'checked' || name == 'selected') {
      (el as JSObject).setProperty(name.toJS, false.toJS);
    } else if (name == 'value') {
      (el as JSObject).setProperty('value'.toJS, ''.toJS);
    }
  }

  @override
  String? tagOf(Object node) => (node as web.Element).tagName.toLowerCase();

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
///
/// [app] is a [VNode] or a [FunctionComponent]: `runApp(App)` for the common
/// case, `runApp(use(App, props))` when the root takes props.
Root runApp(Object app, {String selector = '#root'}) {
  final reused = _reuse(selector, app);
  if (reused != null) return reused;
  final root = createRoot(DomHostAdapter(), _require(selector));
  _roots[selector] = root;
  root.render(asVNode(app));
  return root;
}

/// Hydrates server-rendered markup inside the element matching [selector],
/// adopting the existing DOM instead of recreating it. Pair with
/// `renderToString` / `renderToDocument` on the server.
///
/// [app] is a [VNode] or a [FunctionComponent], as with [runApp].
Root hydrateApp(Object app, {String selector = '#root'}) {
  final reused = _reuse(selector, app);
  if (reused != null) return reused;
  final root = createRoot(DomHostAdapter(), _require(selector));
  _roots[selector] = root;
  root.hydrate(asVNode(app));
  return root;
}

/// Roots created by [runApp] / [hydrateApp], so a hot reload can find the live
/// tree.
final Map<String, Root> _roots = {};

/// Re-runs every mounted component against the code the reload just installed,
/// keeping the tree and all of its state. Returns how many roots it touched, so
/// the dev client can fall back to a restart when there is nothing mounted yet.
///
/// This is the hot-reload entry point, and it is deliberately *not* "call
/// `main()` again": re-entering the entrypoint would re-run everything else it
/// does — timers, listeners, one-time setup — once per save. Flutter's
/// `reassemble()` draws the same line, and for the same reason.
int reassembleApps() {
  for (final root in _roots.values) {
    root.reassemble();
  }
  return _roots.length;
}

/// Re-renders an existing root when `main()` is re-entered anyway — a manual
/// call, or a reload that fell back to it.
///
/// The second pass always *renders* even when the first one hydrated: by then
/// the DOM is a live reactx tree, not server markup waiting to be adopted.
Root? _reuse(String selector, Object app) {
  if (!hotReloadEnabled) return null;
  final root = _roots[selector];
  if (root == null) return null;
  root.render(asVNode(app));
  return root;
}

web.Element _require(String selector) {
  final el = web.document.querySelector(selector);
  if (el == null) {
    throw StateError('reactx: no element matches selector "$selector"');
  }
  return el;
}
