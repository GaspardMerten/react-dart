/// Server-side rendering: turn a [VNode] tree into an HTML string.
///
/// This is pure Dart with no browser dependency, which is the whole point —
/// unlike a canvas/Flutter approach, a reactx tree renders straight to HTML on
/// the server. Components run under a read-only [Dispatcher]: `useState` /
/// `useReducer` yield their initial values, `useMemo` computes, `useContext`
/// reads providers, and effects are skipped (exactly as React does on the
/// server).
library;

import 'context.dart';
import 'diagnostics.dart';
import 'escape.dart';
import 'hooks.dart';
import 'store.dart';
import 'vdom.dart';

/// Renders [node] to an HTML string.
///
/// [node] is a [VNode] or a [FunctionComponent], so both `renderToString(App)`
/// and `renderToString(use(App, props))` work.
String renderToString(Object node) {
  final r = _SsrRenderer();
  final prev = Dispatcher.current;
  Dispatcher.current = r;
  try {
    r._render(asVNode(node));
  } finally {
    Dispatcher.current = prev;
  }
  return r._buf.toString();
}

/// Convenience: renders [node] as the `<body>` of a full HTML document.
///
/// [head] is raw HTML inserted into `<head>`. [bootstrapScript], when given, is
/// added as a `<script defer src="...">` (not a module — dart2js output assigns
/// to the global scope) so the client can hydrate.
String renderToDocument(
  Object node, {
  String title = 'reactx app',
  String head = '',
  String rootId = 'root',
  String? bootstrapScript,
  String lang = 'en',
}) {
  final body = renderToString(node);
  // dart2js output is a classic script (it assigns to the global scope), so it
  // must NOT be loaded as type="module". `defer` runs it after parse.
  final script = bootstrapScript == null
      ? ''
      : '<script defer src="${_escapeAttr(bootstrapScript)}"></script>';
  return '<!doctype html>\n'
      '<html lang="${_escapeAttr(lang)}">\n'
      '<head>\n'
      '<meta charset="utf-8">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>${_escapeText(title)}</title>\n'
      '$head\n'
      '</head>\n'
      '<body>\n'
      '<div id="${_escapeAttr(rootId)}">$body</div>\n'
      '$script\n'
      '</body>\n'
      '</html>\n';
}

class _SsrRenderer implements Dispatcher {
  final StringBuffer _buf = StringBuffer();
  final List<(Context<Object?>, Object?)> _providers = [];

  /// Store state for this render only. Two requests rendered concurrently in
  /// one isolate therefore cannot see each other's data — the reason stores are
  /// not global.
  final Map<Object, Object?> _stores = {};

  Object? _stateOf(Store<Object?, Object?> store) =>
      _stores.putIfAbsent(store, () => store.initialState);

  void _render(VNode node) {
    switch (node) {
      case TextNode t:
        _buf.write(_escapeText(t.text));
      case ElementNode e:
        _writeElement(e);
      case FragmentNode f:
        for (final c in f.children) {
          _render(c);
        }
      case ProviderNode p:
        _providers.add((p.context, p.value));
        for (final c in p.children) {
          _render(c);
        }
        _providers.removeLast();
      case ComponentNode c:
        _render(c.component(c.props));
      case ComponentProps p:
        _render(p.build());
    }
  }

  void _writeElement(ElementNode e) {
    // Tag and attribute names are written into the markup *unquoted*, so unlike
    // values they cannot be made safe by escaping — a name carrying a space and
    // an `=` would simply become a second attribute. Both can come from a props
    // map, and a props map can be built from data, so both are checked.
    if (!isSafeMarkupName(e.tag)) {
      assert(warn('ssr: "${e.tag}" is not a usable tag name, so the element '
          'and everything inside it was dropped. A tag built from data has to '
          'be checked against a list you control.'));
      return;
    }

    _buf.write('<${e.tag}');
    e.props.forEach((name, value) {
      if (name == 'key' ||
          name == 'children' ||
          name == 'ref' ||
          name == 'dangerouslySetInnerHTML') {
        return;
      }
      if (name.startsWith('on') && value is Function) {
        return; // event handlers aren't serialized to HTML
      }
      final attr = _attrName(name);
      // Dropped rather than escaped: there is no spelling of an unsafe name
      // that means what the caller wanted, so emitting nothing is the only
      // honest option. In dev it says so.
      if (!isSafeMarkupName(attr)) {
        assert(warn('ssr: "$name" is not a usable attribute name, so it was '
            'dropped. Attribute names are written into the tag unquoted, so '
            'one built from data can inject another attribute.'));
        return;
      }
      Object? v = value;
      if (name == 'style' && v is Map) v = _styleToString(v);
      if (v == null || v == false) return;
      if (v == true) {
        _buf.write(' $attr');
      } else {
        _buf.write(' $attr="${_escapeAttr('$v')}"');
      }
    });

    if (_voidElements.contains(e.tag)) {
      _buf.write('>');
      return;
    }
    _buf.write('>');

    // Support raw HTML injection, matching React's escape hatch.
    final raw = e.props['dangerouslySetInnerHTML'];
    if (raw is Map && raw['__html'] != null) {
      _buf.write(raw['__html'].toString());
    } else {
      for (final c in e.children) {
        _render(c);
      }
    }
    _buf.write('</${e.tag}>');
  }

  // ---- read-only hook implementations ----

  @override
  (T, StateSetter<T>) useState<T>(T Function() init) => (init(), (_) {});

  @override
  (S, void Function(A)) useReducer<S, A>(
    S Function(S, A) reducer,
    S Function() init,
  ) =>
      (init(), (_) {});

  @override
  void useEffect(EffectCallback effect, List<Object?>? deps, {required bool layout}) {}

  @override
  T useMemo<T>(T Function() create, List<Object?>? deps) => create();

  @override
  Ref<T> useRef<T>(T initial) => Ref<T>(initial);

  @override
  T useContext<T>(Context<T> context) {
    for (var i = _providers.length - 1; i >= 0; i--) {
      final (ctx, value) = _providers[i];
      if (identical(ctx, context)) return value as T;
    }
    return context.defaultValue;
  }

  // Stores behave like every other piece of state on the server: you get the
  // initial value, and writing is a no-op. The state is per-renderer, so it is
  // per-request.

  @override
  (S, void Function(A)) useStore<S, A>(Store<S, A> store) =>
      (_stateOf(store as Store<Object?, Object?>) as S, (_) {});

  @override
  T useSelect<S, A, T>(Store<S, A> store, T Function(S state) select) =>
      select(_stateOf(store as Store<Object?, Object?>) as S);

  @override
  void Function(A) useDispatch<S, A>(Store<S, A> store) => (_) {};
}

// ---------------------------------------------------------------------------
// Serialization helpers.
// ---------------------------------------------------------------------------

const Set<String> _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

String _attrName(String name) => switch (name) {
      'className' => 'class',
      'htmlFor' => 'for',
      _ => name,
    };

String _styleToString(Map<Object?, Object?> style) {
  final b = StringBuffer();
  style.forEach((k, v) {
    if (v == null) return;
    b.write('${_kebab('$k')}: $v; ');
  });
  return b.toString().trimRight();
}

String _kebab(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');

String _escapeText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
