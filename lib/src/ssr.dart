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
import 'hooks.dart';
import 'vdom.dart';

/// Renders [node] to an HTML string.
String renderToString(VNode node) {
  final r = _SsrRenderer();
  final prev = Dispatcher.current;
  Dispatcher.current = r;
  try {
    r._render(node);
  } finally {
    Dispatcher.current = prev;
  }
  return r._buf.toString();
}

/// Convenience: renders [node] as the `<body>` of a full HTML document.
///
/// [head] is raw HTML inserted into `<head>`. [bootstrapScript], when given, is
/// added as a `<script type="module" src="...">` so the client can hydrate.
String renderToDocument(
  VNode node, {
  String title = 'reactx app',
  String head = '',
  String rootId = 'root',
  String? bootstrapScript,
  String lang = 'en',
}) {
  final body = renderToString(node);
  final script = bootstrapScript == null
      ? ''
      : '<script type="module" src="${_escapeAttr(bootstrapScript)}"></script>';
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
    }
  }

  void _writeElement(ElementNode e) {
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
