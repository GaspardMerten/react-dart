/// The [HostAdapter]: the seam between the reconciler and a concrete output.
///
/// The reconciler never touches the DOM directly. It speaks only to a
/// [HostAdapter], whose "nodes" are opaque `Object`s. This is what lets the
/// exact same reconciliation, hooks, and effect machinery run against:
///   * the real browser DOM (`DomHostAdapter`, in `lib/dom.dart`), and
///   * an in-memory tree (`TestHost` below) for fast, headless VM tests.
library;

/// Abstract host operations. All nodes are opaque [Object]s created by the
/// adapter itself.
abstract class HostAdapter {
  /// Creates a host element for [tag].
  Object createElement(String tag);

  /// Creates a host text node.
  Object createText(String text);

  /// Updates the text content of a text node.
  void setText(Object node, String text);

  /// Sets an attribute/property. A `null` [value] removes it.
  void setAttribute(Object node, String name, Object? value);

  /// Removes an attribute/property.
  void removeAttribute(Object node, String name);

  /// Attaches an event listener. [type] is the DOM event name (e.g. `click`).
  void addEventListener(Object node, String type, void Function(Object event) handler);

  /// Detaches a previously-added listener.
  void removeEventListener(Object node, String type, void Function(Object event) handler);

  /// Inserts [child] into [parent] before [reference]; appends when
  /// [reference] is `null`.
  void insertBefore(Object parent, Object child, Object? reference);

  /// Removes [child] from [parent].
  void removeChild(Object parent, Object child);

  /// The current parent of [node], or `null` if it is detached. Used by the
  /// reconciler to remove a node without tracking its parent separately.
  Object? parentNode(Object node);

  /// Replaces the children of [node] with raw, unescaped HTML. Backs
  /// `dangerouslySetInnerHTML`.
  void setInnerHtml(Object node, String html);

  /// The existing child nodes of [node], in order. Used during hydration to
  /// adopt server-rendered markup instead of recreating it.
  List<Object> childNodes(Object node);

  /// Whether [node] is a text node (vs. an element). Used during hydration.
  bool isText(Object node);

  /// The node immediately after [node] under the same parent, or `null`. Used
  /// by placement to avoid moving nodes that are already in position (which in
  /// the DOM would needlessly blur a focused element).
  Object? nextSibling(Object node);
}

// ---------------------------------------------------------------------------
// In-memory host, used for tests and as an example implementation.
// ---------------------------------------------------------------------------

/// A node in the [TestHost] tree. Either an element (has [tag]) or text.
final class TestNode {
  final String? tag;
  String? text;

  /// When set, [toHtml] emits this verbatim instead of [children].
  String? rawHtml;
  final Map<String, Object?> attributes = {};
  final Map<String, void Function(Object event)> listeners = {};
  final List<TestNode> children = [];
  TestNode? parent;

  TestNode.element(this.tag);
  TestNode.text(this.text) : tag = null;

  bool get isText => tag == null;

  /// Serializes this subtree to HTML — handy for asserting reconciler output.
  String toHtml() {
    final b = StringBuffer();
    _write(b);
    return b.toString();
  }

  void _write(StringBuffer b) {
    if (isText) {
      b.write(_escapeText(text ?? ''));
      return;
    }
    b.write('<$tag');
    final keys = attributes.keys.toList()..sort();
    for (final k in keys) {
      final v = attributes[k];
      if (v == null || v == false) continue;
      if (v == true) {
        b.write(' $k');
      } else {
        b.write(' $k="${_escapeAttr('$v')}"');
      }
    }
    if (_voidElements.contains(tag)) {
      b.write('>');
      return;
    }
    b.write('>');
    if (rawHtml != null) {
      b.write(rawHtml);
    } else {
      for (final c in children) {
        c._write(b);
      }
    }
    b.write('</$tag>');
  }

  /// Simulates dispatching a DOM event named [type] at this node.
  void dispatch(String type, [Object? event]) {
    listeners[type]?.call(event ?? _FakeEvent(type, this));
  }

  @override
  String toString() => isText ? 'text("$text")' : '<$tag>';
}

class _FakeEvent {
  final String type;
  final TestNode target;
  _FakeEvent(this.type, this.target);
  @override
  String toString() => 'Event($type)';
}

/// An in-memory [HostAdapter]. Its nodes are [TestNode]s.
final class TestHost implements HostAdapter {
  /// The synthetic root container you mount into.
  final TestNode root = TestNode.element('#root');

  /// Number of [insertBefore] calls — lets tests assert that stable nodes are
  /// not needlessly moved.
  int insertBeforeCount = 0;

  @override
  Object createElement(String tag) => TestNode.element(tag);

  @override
  Object createText(String text) => TestNode.text(text);

  @override
  void setText(Object node, String text) => (node as TestNode).text = text;

  @override
  void setAttribute(Object node, String name, Object? value) {
    if (value == null) {
      (node as TestNode).attributes.remove(name);
    } else {
      (node as TestNode).attributes[name] = value;
    }
  }

  @override
  void removeAttribute(Object node, String name) =>
      (node as TestNode).attributes.remove(name);

  @override
  void addEventListener(
      Object node, String type, void Function(Object event) handler) {
    (node as TestNode).listeners[type] = handler;
  }

  @override
  void removeEventListener(
      Object node, String type, void Function(Object event) handler) {
    (node as TestNode).listeners.remove(type);
  }

  @override
  void insertBefore(Object parent, Object child, Object? reference) {
    insertBeforeCount++;
    final p = parent as TestNode;
    final c = child as TestNode;
    c.parent?.children.remove(c);
    c.parent = p;
    if (reference == null) {
      p.children.add(c);
    } else {
      final idx = p.children.indexOf(reference as TestNode);
      p.children.insert(idx < 0 ? p.children.length : idx, c);
    }
  }

  @override
  void removeChild(Object parent, Object child) {
    final p = parent as TestNode;
    final c = child as TestNode;
    p.children.remove(c);
    c.parent = null;
  }

  @override
  Object? parentNode(Object node) => (node as TestNode).parent;

  @override
  void setInnerHtml(Object node, String html) {
    final n = node as TestNode;
    n.children.clear();
    n.rawHtml = html;
  }

  @override
  List<Object> childNodes(Object node) => List<Object>.from((node as TestNode).children);

  @override
  bool isText(Object node) => (node as TestNode).isText;

  @override
  Object? nextSibling(Object node) {
    final n = node as TestNode;
    final siblings = n.parent?.children;
    if (siblings == null) return null;
    final idx = siblings.indexOf(n);
    return (idx < 0 || idx + 1 >= siblings.length) ? null : siblings[idx + 1];
  }
}

const Set<String> _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

String _escapeText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
