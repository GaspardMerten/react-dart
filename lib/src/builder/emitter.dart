/// Emits Dart source from a parsed jsx template AST. Used by the build_runner
/// precompiler to turn `jsx(r'...')` into direct `h(...)` construction, so no
/// template parsing happens at runtime.
library;

import '../jsx.dart';

/// Emits a Dart expression of type [JsxBuilder] — i.e.
/// `(List<Object?> args) => <vnode expression>` — equivalent to what the
/// runtime interpreter would produce for the same [nodes].
String emitTemplate(List<TemplateNode> nodes) =>
    '(List<Object?> args) => ${_emitTop(nodes)}';

String _emitTop(List<TemplateNode> nodes) {
  if (nodes.length == 1) {
    final n = nodes.single;
    if (n is TemplateElement) return _emitElement(n);
    if (n is TemplateText) return 'TextNode(${_str(n.text)})';
    if (n is TemplateSlot) {
      return 'FragmentNode(normalizeChildren(<Object?>[args[${n.index}]]))';
    }
  }
  return 'FragmentNode(normalizeChildren(<Object?>[${nodes.map(_emitChild).join(', ')}]))';
}

String _emitChild(TemplateNode n) => switch (n) {
      TemplateText t => 'TextNode(${_str(t.text)})',
      TemplateSlot s => 'args[${s.index}]',
      TemplateElement e => _emitElement(e),
    };

String _emitElement(TemplateElement e) {
  final children =
      '<Object?>[${e.children.map(_emitChild).join(', ')}]';
  if (e.tagOrSlot == null) {
    return 'FragmentNode(normalizeChildren($children))';
  }
  final props = '<String, Object?>{'
      '${e.attrs.map((a) => '${_str(a.name)}: ${_emitAttr(a.value)}').join(', ')}}';
  final tag = e.tagOrSlot is int
      ? '(args[${e.tagOrSlot}] as FunctionComponent)'
      : _str(e.tagOrSlot as String);
  return 'h($tag, $props, $children)';
}

String _emitAttr(AttrValue v) => switch (v) {
      AttrStatic(value: final val) =>
        val is bool ? val.toString() : _str(val as String),
      AttrSlot(index: final idx) => 'args[$idx]',
      AttrConcat(parts: final parts) => parts
          .map((p) => p is int ? "(args[$p]?.toString() ?? '')" : _str(p as String))
          .join(' + '),
    };

/// Emits a Dart single-quoted string literal for [s].
String _str(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return "'$escaped'";
}
